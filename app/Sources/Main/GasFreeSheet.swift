import SwiftUI
import CofferCore

@MainActor
struct GasFreeSheet: View {
    let entryID: UUID
    let owner: String
    @EnvironmentObject private var unlock: UnlockService
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GasFreeSnapshot?
    @State private var quote: GasFreeQuote?
    @State private var record: GasFreeRecord?
    @State private var configured = false
    @State private var storageOK = false
    @State private var busy = false
    @State private var authenticating = false
    @State private var showingReceive = false
    @State private var recipient = ""
    @State private var amount = ""
    @State private var recoveryTrace = ""
    @State private var message: String?
    @State private var operation: Task<Void, Never>?

    private var canSign: Bool {
        guard let entry = unlock.document?.entries.first(where: { $0.id == entryID }),
              case .wallet(let wallet) = entry.payload else { return false }
        return wallet.address == owner && wallet.secretKind != .watchOnly
    }
    private var pending: Bool { record != nil && record?.settled != true }
    private var target: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func money(_ amount: Int64) -> String { TronGridClient.formatUSDT(amount) + " USDT" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("官方 GasFree 钱包").font(.title2.bold())
                    Spacer()
                    Button("关闭") { dismiss() }.disabled(busy || authenticating).keyboardShortcut(.cancelAction)
                }
                Text("Tron 主网 · 用 USDT 支付手续费，无需在此地址准备 TRX。")
                    .foregroundStyle(.secondary)
                if authenticating, let quote {
                    WalletAuthenticationSheet(reason: "授权 GasFree 转出 \(money(quote.value))，手续费上限 \(money(quote.maxFee))",
                        onAuthorized: { send(quote) }, onCancel: { authenticating = false })
                } else {
                    Text("这是由当前钱包控制的独立地址。普通钱包里的 USDT 不在此余额内；从普通地址转入仍需支付该次链上费用。")
                        .font(.callout).foregroundStyle(.secondary)
                    if !configured {
                        Text("尚未启用。先到设置申请、填写并验证 GasFree API Key 和 API Secret，再使用收款与转账。")
                        HStack {
                            CofferSettingsButton("打开设置")
                            Button("已配置，重新检查", action: refreshWallet).disabled(busy)
                        }
                        Link("官方说明", destination: URL(string: "https://gasfree.io/")!)
                    }
                    if let snapshot {
                        accountView(snapshot)
                    }
                    if let record { recordView(record) }
                    if let quote {
                        confirmation(quote)
                    } else if configured && !pending && storageOK && snapshot != nil {
                        inputView
                    }
                    if !canSign {
                        Text("仅地址钱包只可查看，导入控制此地址的凭证后才能转出。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView("正在核对 GasFree…") }
                    if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }.padding(26)
        }
        .frame(width: 620, height: 730)
        .interactiveDismissDisabled()
        .onAppear(perform: refreshWallet)
        .onDisappear { operation?.cancel() }
        .onChange(of: unlock.isUnlocked) { unlocked in
            if !unlocked { operation?.cancel(); authenticating = false; showingReceive = false; dismiss() }
        }
        .sheet(isPresented: $showingReceive) {
            if let snapshot {
                WalletReceiveSheet(address: snapshot.address, title: "GasFree 独立钱包收款",
                                   instruction: "仅接收 Tron 主网 USDT。首次转出需另留激活费与服务费。")
            }
        }
    }

    private func accountView(_ account: GasFreeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(money(account.balance)).font(.title.bold()).monospacedDigit()
            Text("可用 \(money(account.available)) · 冻结 \(money(account.frozen))")
                .font(.caption).foregroundStyle(.secondary)
            Text(account.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("刷新余额与费用", action: refreshWallet).disabled(busy || quote != nil)
                Button("收款二维码") { showingReceive = true }.disabled(busy || !configured)
                Link("Tronscan", destination: URL(string: "https://tronscan.org/#/address/\(account.address)")!)
            }
            Text(account.active ? "已激活，转账服务费：\(money(account.transferFee))"
                 : "首次激活费：\(money(account.activationFee))；另收转账服务费：\(money(account.transferFee))")
                .font(.callout)
            Text("当前服务商：\(account.provider.name)。以上为本次查询报价，转出前会重新核对。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从 GasFree 钱包转出").font(.headline)
            TextField("收款人的 Tron 地址（T 开头）", text: $recipient)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            TextField("对方收到的 USDT 金额（最多 6 位小数）", text: $amount).textFieldStyle(.roundedBorder)
            Button("查看费用", action: prepareQuote)
                .disabled(!canSign || !TronWalletService().validateAddress(target) || (TronGridClient.parseSun(amount) ?? 0) <= 0)
        }.disabled(busy)
    }

    private func confirmation(_ draft: GasFreeQuote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核对本次转账").font(.headline)
            Text("从：\(draft.snapshot.address)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("到：\(draft.receiver)").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            CofferLabeledContent("对方收到", value: money(draft.value))
            CofferLabeledContent("首次激活费", value: money(draft.snapshot.activationFee))
            CofferLabeledContent("转账服务费", value: money(draft.snapshot.transferFee))
            CofferLabeledContent("手续费上限", value: money(draft.maxFee))
            CofferLabeledContent("最多总扣款", value: money(draft.total)).font(.body.bold())
            Text("费用另加，不从对方收款金额中扣除。报价有效 90 秒；费用或账户状态变化时需重新确认。实际支出以固化链回执为准。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回修改") { quote = nil }
                Spacer()
                Button("认证并转账") { authenticating = true }
                    .buttonStyle(.borderedProminent).disabled(!canSign || pending || !storageOK)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).disabled(busy)
    }

    private func recordView(_ item: GasFreeRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let receipt = item.receipt {
                Text(receipt.succeeded ? "转账已在固化链确认" : "交易在链上执行失败").font(.headline)
                Text("实际转出：\(money(receipt.amount))；实际手续费：\(money(receipt.totalFee))")
                Text("实际总扣款：\(money(receipt.totalCost))").bold()
                if !item.settled {
                    Text("等待授权有效期结束后可再转账，请稍后点查询。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if item.state == "EXPIRED_UNUSED", item.settled {
                Text("授权已过期，固化链确认未执行").font(.headline)
                Text("本笔授权未扣 USDT，可重新查看费用并确认转账。")
            } else {
                Text("上一笔转账待确认").font(.headline)
                Text("金额 \(money(item.permit.value))，手续费上限 \(money(item.permit.maxFee))。请先查询结果，暂不提交下一笔。")
            }
            Text("收款人：\(item.permit.receiver)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let trace = item.traceID {
                Text("GasFree 查询编号：\(trace)").font(.caption).textSelection(.enabled)
            } else if !item.settled {
                Text("未收到服务商查询编号。可先查询：授权过期后会核对固化链是否执行；若已使用，联系 GasFree 支持并提供以下请求编号，拿到 traceId 后恢复回执。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("请求编号：\(item.requestID)").font(.caption).textSelection(.enabled)
                TextField("服务商提供的 traceId（不是交易哈希）", text: $recoveryTrace).textFieldStyle(.roundedBorder)
                Link("GasFree 官方文档与支持", destination: URL(string: "https://docs.gasfree.io/")!)
            }
            if let hash = item.transactionHash {
                Link("在 Tronscan 核对链上交易", destination: TransferReceipt(txHash: hash).tronscanURL)
            }
            if !item.settled {
                Button("查询上一笔转账", action: refreshRecord)
                    .disabled(busy || !configured)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func store() throws -> GasFreeJournalStore {
        try GasFreeJournalStore(directory: VaultFileStore.defaultDirectory().appendingPathComponent("gasfree-transfers"), owner: owner)
    }
    private func service() throws -> GasFreeService {
        guard let credentials = try GasFreeCredentialStore().load() else { throw GasFreeError.credentials }
        return GasFreeService(client: GasFreeClient(credentials: credentials), tronGridKey: AppSettings.shared.trongridApiKey)
    }
    private func loadRecord() {
        do { record = try store().load().records.last; storageOK = true }
        catch { storageOK = false; message = error.localizedDescription }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, unlock.isUnlocked else { return }
        busy = true; message = nil
        operation = Task { @MainActor in
            do { try await action() }
            catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                loadRecord()
            }
            busy = false
        }
    }
    private func refreshWallet() {
        guard !busy else { return }
        loadRecord()
        run {
            configured = try GasFreeCredentialStore().load() != nil
            guard configured else { snapshot = nil; return }
            let refreshed = try await service().snapshot(owner: owner)
            try Task.checkCancellation()
            snapshot = refreshed
        }
    }
    private func prepareQuote() {
        guard canSign, storageOK, !pending, let value = TronGridClient.parseSun(amount), value > 0 else { return }
        let receiver = target
        run {
            let result = try await service().quote(owner: owner, receiver: receiver, value: value)
            try Task.checkCancellation()
            snapshot = result.snapshot; quote = result
        }
    }
    private func signingKey() throws -> Data {
        try Task.checkCancellation()
        guard unlock.isUnlocked,
              let entry = unlock.document?.entries.first(where: { $0.id == entryID }),
              case .wallet(let wallet) = entry.payload, wallet.address == owner,
              let secret = wallet.secret else { throw TronWalletError.badPrivateKey }
        switch wallet.secretKind {
        case .mnemonic: return try TronWalletService().privateKeyData(fromMnemonic: secret)
        case .privateKey: return try TronWalletService().privateKeyData(fromPrivateKey: secret)
        case .watchOnly: throw TronWalletError.badPrivateKey
        }
    }
    private func send(_ draft: GasFreeQuote) {
        guard authenticating, canSign, storageOK, !pending else { return }
        authenticating = false; quote = nil
        run {
            record = try await service().submit(draft, store: store(), signingKey: signingKey)
            amount = ""
            message = "GasFree 已受理授权，尚不代表链上完成。请稍后查询结果。"
        }
    }
    private func refreshRecord() {
        run {
            let trace = recoveryTrace.trimmingCharacters(in: .whitespacesAndNewlines)
            record = try await service().refresh(store: store(), recoveredTraceID: trace.isEmpty ? nil : trace)
            recoveryTrace = ""
        }
    }
}
