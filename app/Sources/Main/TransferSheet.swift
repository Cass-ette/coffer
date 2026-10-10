import SwiftUI
import CofferCore

@MainActor
struct TransferSheet: View {
    let entryID: UUID
    let address: String
    let initialBalances: TronBalances?
    @EnvironmentObject private var unlock: UnlockService
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var amount = ""
    @State private var balances: TronBalances?
    @State private var balanceError: String?
    @State private var stage: Stage = .input
    @State private var operation: Task<Void, Never>?
    @State private var balanceTask: Task<Void, Never>?
    @State private var showingNavigationConfirmation = false
    @State private var returningToInput = false

    private struct Draft {
        let to: String
        let amountSun: Int64
        let quote: TronTransferQuote
    }

    private enum Stage {
        case input, quoting
        case confirming(Draft), authing(Draft)
        case broadcasting
        case done(TransferReceipt), uncertain(TransferReceipt)
        case failed(String)
    }

    private var target: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amountSun: Int64? { TronGridClient.parseSun(amount) }
    private var validAddress: Bool { TronWalletService().validateAddress(target) }
    private var validAmount: Bool { (amountSun ?? 0) > 0 }
    private var isQuoting: Bool { if case .quoting = stage { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("转出 USDT · Tron 主网").font(.title2.bold())
            switch stage {
            case .input, .quoting:
                inputForm
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                inputForm
            case .confirming(let draft):
                confirmation(draft)
            case .authing(let draft):
                WalletAuthenticationSheet(
                    reason: "授权转出 \(TronGridClient.formatUSDT(draft.amountSun)) USDT",
                    onAuthorized: { send(draft) },
                    onCancel: { stage = .confirming(draft) })
                    .frame(maxWidth: .infinity)
            case .broadcasting:
                ProgressView("正在构建、签名并广播交易…")
                Text("请等待节点响应。若网络中断，请先查询交易哈希再决定下一步。")
                    .font(.callout).foregroundStyle(.secondary)
            case .done(let receipt):
                receiptView(receipt, uncertain: false)
            case .uncertain(let receipt):
                receiptView(receipt, uncertain: true)
            }
        }
        .padding(28)
        .frame(width: 570, alignment: .leading)
        .interactiveDismissDisabled()
        .onAppear(perform: loadBalances)
        .onDisappear {
            operation?.cancel()
            balanceTask?.cancel()
        }
        .onChange(of: unlock.isUnlocked) { _, unlocked in
            if !unlocked {
                operation?.cancel()
                balanceTask?.cancel()
                dismiss()
            }
        }
        .confirmationDialog(returningToInput ? "返回修改转账信息？" : "放弃本次转账？",
                            isPresented: $showingNavigationConfirmation, titleVisibility: .visible) {
            Button(returningToInput ? "返回修改" : "放弃转账", role: .destructive) {
                operation?.cancel()
                if returningToInput { stage = .input } else { dismiss() }
            }
            Button("继续核对", role: .cancel) { }
        } message: {
            Text(returningToInput ? "修改后需要重新估价并完成认证。" : "当前输入不会保存。尚未签名或广播。")
        }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            balanceView
            Text("转出地址：\(address)")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            TextField("对方的 Tron 地址（T 开头）", text: $recipient)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            if !target.isEmpty {
                Label(validAddress ? "地址格式与校验位有效，请核对收款人" : "地址无效：请填写 T 开头的 Tron 地址",
                      systemImage: validAddress ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(validAddress ? .green : .red)
            }
            HStack {
                TextField("金额（最多 6 位小数）", text: $amount).textFieldStyle(.roundedBorder)
                Text("USDT")
            }
            if !amount.isEmpty && !validAmount {
                Text("请输入大于零的金额，最多六位小数。")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("主网转账不可撤销。请核对网络和地址，并保留 TRX 支付手续费。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { navigateBack(editing: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                if isQuoting { ProgressView().controlSize(.small) }
                Button(isQuoting ? "正在估价…" : "下一步", action: prepareQuote)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validAddress || !validAmount || isQuoting)
            }
        }
        .disabled(isQuoting)
    }

    private var balanceView: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let balances {
                Text("余额：\(TronGridClient.formatUSDT(balances.usdtSun)) USDT")
                Text("手续费余额：\(TronGridClient.formatUSDT(balances.trxBalance)) TRX")
                    .foregroundStyle(.secondary)
            } else {
                Text(balanceError ?? "正在查询 USDT / TRX 余额…").foregroundStyle(.secondary)
            }
            if balances != nil, let balanceError {
                Text("\(balanceError)；下一步会重新查询余额。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.monospacedDigit()
    }

    private func confirmation(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(TronGridClient.formatUSDT(draft.amountSun)) USDT")
                .font(.system(.title, design: .rounded).bold()).monospacedDigit()
            Label("\(draft.to.prefix(6))…\(draft.to.suffix(6)) · 地址校验通过", systemImage: "checkmark.seal")
            Text(draft.to).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Divider()
            balanceView
            Text("预计手续费 ≈ \(TronGridClient.formatUSDT(draft.quote.fee.feeSun)) TRX")
                .monospacedDigit()
            Text("包含能量与带宽估算；费用上限按本次估价设置。资源价格或执行消耗变化可能导致交易失败并消耗手续费。")
                .font(.caption).foregroundStyle(.secondary)
            Text("转账后余额：\(TronGridClient.formatUSDT(draft.quote.balances.usdtSun - draft.amountSun)) USDT")
                .monospacedDigit()
            HStack {
                Button("返回修改") { navigateBack(editing: true) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认转账") { stage = .authing(draft) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func receiptView(_ receipt: TransferReceipt, uncertain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(uncertain ? "广播状态未知" : "节点已受理", systemImage: uncertain ? "questionmark.circle" : "checkmark.circle")
                .font(.headline).foregroundStyle(uncertain ? .orange : .green)
            Text(uncertain
                 ? "节点可能已经收到交易。请先查询下方哈希，勿立即重复转账。"
                 : "受理不代表转账成功，以链上执行结果为准。")
            Text(receipt.txHash).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("复制哈希") { ClipboardManager.shared.copy(receipt.txHash, autoClearSeconds: 45) }
                Link("在 Tronscan 查看", destination: receipt.tronscanURL)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func navigateBack(editing: Bool) {
        if !editing && recipient.isEmpty && amount.isEmpty { dismiss(); return }
        returningToInput = editing
        showingNavigationConfirmation = true
    }

    private func service() -> TronTransferService {
        TronTransferService(http: URLSessionHTTP(), apiKey: AppSettings.shared.trongridApiKey)
    }

    private func loadBalances() {
        balances = initialBalances
        let apiKey = AppSettings.shared.trongridApiKey
        balanceTask = Task { @MainActor in
            do {
                let value = try await TronGridClient(http: URLSessionHTTP(), apiKey: apiKey).balances(address: address)
                try Task.checkCancellation()
                balances = value
                balanceError = nil
            } catch {
                guard !Task.isCancelled else { return }
                balanceError = error.localizedDescription
            }
        }
    }

    private func prepareQuote() {
        guard unlock.isUnlocked, validAddress, let sun = amountSun, sun > 0 else { return }
        let destination = target
        balanceTask?.cancel()
        stage = .quoting
        operation = Task { @MainActor in
            do {
                let quote = try await service().quote(from: address, to: destination, usdtSun: sun)
                try Task.checkCancellation()
                guard unlock.isUnlocked else { return }
                balances = quote.balances
                balanceError = nil
                stage = .confirming(Draft(to: destination, amountSun: sun, quote: quote))
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func send(_ draft: Draft) {
        guard unlock.isUnlocked, case .authing = stage else { return }
        stage = .broadcasting
        operation = Task { @MainActor in
            do {
                let receipt = try await service().sendUSDT(
                    from: address, to: draft.to, usdtSun: draft.amountSun,
                    feeLimitSun: draft.quote.fee.feeSun, signingKey: {
                        try Task.checkCancellation()
                        guard unlock.isUnlocked,
                              let entry = unlock.document?.entries.first(where: { $0.id == entryID }),
                              case .wallet(let payload) = entry.payload,
                              payload.address == address,
                              let secret = payload.secret else { throw TronWalletError.badPrivateKey }
                        let wallet = TronWalletService()
                        switch payload.secretKind {
                        case .mnemonic: return try wallet.privateKeyData(fromMnemonic: secret)
                        case .privateKey: return try wallet.privateKeyData(fromPrivateKey: secret)
                        case .watchOnly: throw TronWalletError.badPrivateKey
                        }
                    })
                stage = .done(receipt)
            } catch BroadcastError.uncertain(let hash) {
                stage = .uncertain(TransferReceipt(txHash: hash))
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
