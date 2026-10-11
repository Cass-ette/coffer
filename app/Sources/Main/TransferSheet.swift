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
    @State private var selectedMode: FeeMode = .direct
    @State private var journal = TronTransferJournal()
    @State private var storageError: String?
    @State private var statusMessage: String?
    @State private var checking = false
    @State private var progressText = "正在构建、签名并广播交易…"

    private struct Draft {
        let to: String
        let amountSun: Int64
        let quote: TronTransferQuote
        let rental: TronRentalPlan?
        let rentalMessage: String?
    }
    private enum FeeMode: String, CaseIterable, Identifiable {
        case direct, rental
        var id: String { rawValue }
        var title: String { self == .direct ? "直接用 TRX" : "按次租能量" }
    }
    private enum Stage {
        case input, quoting, confirming(Draft), authing(Draft), broadcasting
        case done(TransferReceipt), uncertain(TransferReceipt), rentalPending
        case failed(String)
    }
    private var target: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amountSun: Int64? { TronGridClient.parseSun(amount) }
    private var validAddress: Bool { TronWalletService().validateAddress(target) }
    private var validAmount: Bool { (amountSun ?? 0) > 0 }
    private var isQuoting: Bool { if case .quoting = stage { return true }; return false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("转出 USDT · Tron 主网").font(.title2.bold())
                switch stage {
                case .input, .quoting: inputForm
                case .failed(let message):
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                    inputForm
                case .confirming(let draft): confirmation(draft)
                case .authing(let draft):
                    WalletAuthenticationSheet(
                        reason: selectedMode == .rental
                            ? "授权租能量并转出 \(TronGridClient.formatUSDT(draft.amountSun)) USDT"
                            : "授权转出 \(TronGridClient.formatUSDT(draft.amountSun)) USDT",
                        onAuthorized: { send(draft) }, onCancel: { stage = .confirming(draft) })
                        .frame(maxWidth: .infinity)
                case .broadcasting:
                    ProgressView(progressText)
                    Text("请等待响应。付款或广播超时后会保留哈希，先核对结果再继续。")
                        .font(.callout).foregroundStyle(.secondary)
                case .done(let receipt): receiptView(receipt, uncertain: false)
                case .uncertain(let receipt): receiptView(receipt, uncertain: true)
                case .rentalPending: rentalPendingView
                }
                if let statusMessage {
                    Text(statusMessage).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }.padding(28)
        }
        .frame(width: 610, height: 720)
        .interactiveDismissDisabled()
        .onAppear(perform: loadBalances)
        .onDisappear { operation?.cancel(); balanceTask?.cancel() }
        .onChange(of: unlock.isUnlocked) { _, unlocked in
            if !unlocked { operation?.cancel(); balanceTask?.cancel(); dismiss() }
        }
        .confirmationDialog(returningToInput ? "返回修改转账信息？" : "放弃本次输入？",
                            isPresented: $showingNavigationConfirmation, titleVisibility: .visible) {
            Button(returningToInput ? "返回修改" : "放弃输入", role: .destructive) {
                operation?.cancel()
                if returningToInput { stage = .input } else { dismiss() }
            }
            Button("继续核对", role: .cancel) {}
        } message: {
            Text("修改后需重新估价和认证。已提交付款的记录会保留。")
        }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            balanceView
            if let storageError {
                Text(storageError).foregroundStyle(.red)
                Button("重新读取转账记录") { loadJournal() }
            }
            if let rental = journal.rental, !rental.ready {
                Text("上一笔租能量付款待确认，已暂停新付款。")
                    .foregroundStyle(.orange)
                Link("核对租赁付款", destination: TransferReceipt(txHash: rental.paymentHash).tronscanURL)
                Button("查询付款与资源") { checkPendingRental() }.disabled(checking)
            } else if let rental = journal.rental, journal.transfer == nil {
                Text("此前租赁付款：租金 \(TronGridClient.formatUSDT(rental.paidRentSun)) TRX。下一步按现有资源重新估价。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let transfer = journal.transfer {
                if transfer.receipt == nil {
                    Text("上一笔 USDT 转账待确认，已暂停新转账。")
                        .foregroundStyle(.orange)
                    Link("核对 USDT 转账", destination: TransferReceipt(txHash: transfer.hash).tronscanURL)
                    Button("查询链上结果") { refreshExecutionReceipt(transfer.hash) }.disabled(checking)
                } else {
                    Button("查看上一笔实际费用") { stage = .done(TransferReceipt(txHash: transfer.hash)) }
                }
            }
            Text("转出地址：\(address)")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            TextField("对方的 Tron 地址（T 开头）", text: $recipient)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .disabled(isQuoting)
            if !target.isEmpty {
                Label(validAddress ? "地址校验通过，请核对收款人" : "地址无效：请填写 T 开头的 Tron 地址",
                      systemImage: validAddress ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(validAddress ? .green : .red)
            }
            HStack {
                TextField("金额（最多 6 位小数）", text: $amount).textFieldStyle(.roundedBorder).disabled(isQuoting)
                Text("USDT")
            }
            if !amount.isEmpty && !validAmount {
                Text("请输入大于零的金额，最多六位小数。")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("主网转账不可撤销。请核对网络、收款人及费用。")
                .font(.caption).foregroundStyle(.secondary)
            if isQuoting {
                Text("正在查询报价；遇到临时限流会等待后重试一次，可取消。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { navigateBack(editing: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                if isQuoting || checking { ProgressView().controlSize(.small) }
                Button(isQuoting ? "正在估价…" : "下一步", action: prepareQuote)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validAddress || !validAmount || isQuoting || checking
                              || journal.blocksNewPayment || storageError != nil)
            }
        }
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
        let fee = draft.quote.fee
        let rental = draft.rental
        let expected = selectedMode == .rental ? rental?.totalSun ?? fee.feeSun : fee.feeSun
        let maximum = selectedMode == .rental ? rental?.maximumTotalSun ?? fee.maximumFeeSun : fee.maximumFeeSun
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(TronGridClient.formatUSDT(draft.amountSun)) USDT")
                .font(.system(.title, design: .rounded).bold()).monospacedDigit()
            Text(draft.to).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Divider()
            Label("此页仅展示报价；继续并完成独立认证后，才会发起新的交易。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            balanceView
            Text("本次能量：需 \(fee.energy) · 已有 \(fee.energyAvailable) · 缺口 \(fee.energyBurned)")
                .font(.callout).monospacedDigit()
            HStack {
                Text("直接用 TRX")
                Spacer()
                Text("预计 \(TronGridClient.formatUSDT(fee.feeSun)) TRX")
            }
            if let rental {
                HStack {
                    Text("TronSave 租能量")
                    Spacer()
                    Text("预计 \(TronGridClient.formatUSDT(rental.totalSun)) TRX")
                }
                if rental.savingsSun > 0 {
                    Text("租赁预计节省 \(TronGridClient.formatUSDT(rental.savingsSun)) TRX")
                        .font(.caption).foregroundStyle(.green)
                }
                Picker("支付方式", selection: $selectedMode) {
                    ForEach(FeeMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            } else if let message = draft.rentalMessage {
                if fee.energyBurned > 0 {
                    Label("\(message) 当前仅有直接付费方案，请核对预计支出后再决定。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            if selectedMode == .rental, let rental {
                Text("租金 \(TronGridClient.formatUSDT(rental.quote.rentSun)) TRX，\(rental.quote.energy) 能量 / 1 小时")
                Text("单价 \(NSDecimalNumber(decimal: rental.quote.unitPrice).stringValue) SUN/能量；付款网络费 \(TronGridClient.formatUSDT(rental.paymentFeeSun)) TRX，转账网络费 \(TronGridClient.formatUSDT(rental.transferFeeSun)) TRX")
                    .font(.callout)
                Text("共两笔交易；先付固定租金，资源到账再转 USDT。未用完不承诺退款；报价约 90 秒有效。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("能量扣费 \(TronGridClient.formatUSDT(fee.energyFeeSun)) TRX · 带宽扣费 \(TronGridClient.formatUSDT(fee.bandwidthFeeSun)) TRX")
                    .font(.callout)
            }
            Text("本次预计支出：\(TronGridClient.formatUSDT(expected)) TRX")
                .font(.headline).monospacedDigit()
            Text("按当前费率与资源计算，最高约 \(TronGridClient.formatUSDT(maximum)) TRX；不预扣，最终看链上实际费用。")
                .font(.caption).foregroundStyle(.secondary)
            Text("预留 20% 能量执行余量；资源减少或实际执行变化可能增加扣费，链上失败也可能收费。")
                .font(.caption).foregroundStyle(.secondary)
            if let prior = journal.rental, journal.transfer == nil {
                Text("此前已付租金 \(TronGridClient.formatUSDT(prior.paidRentSun)) TRX，以上是接下来这笔的费用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("转账后预计：\(TronGridClient.formatUSDT(draft.quote.balances.usdtSun - draft.amountSun)) USDT / \(TronGridClient.formatUSDT(draft.quote.balances.trxBalance - expected)) TRX")
                .font(.callout).monospacedDigit()
            if draft.quote.balances.trxBalance < maximum {
                Text("TRX 不足以覆盖当前方案的执行上限，请补充 TRX 或改选方案。")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("返回修改") { navigateBack(editing: true) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("刷新报价") { prepareQuote() }
                Button(selectedMode == .rental ? "继续：租能量" : "继续：直接付费") {
                    stage = .authing(draft)
                }.keyboardShortcut(.defaultAction)
                    .disabled(draft.quote.balances.trxBalance < maximum || storageError != nil)
            }
        }
    }

    private var rentalPendingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("租赁付款与资源待确认").font(.headline).foregroundStyle(.orange)
            if let rental = journal.rental {
                Text("租金：\(TronGridClient.formatUSDT(rental.rentSun)) TRX · 1 小时")
                if let order = rental.orderID { Text("TronSave 订单：\(order)").textSelection(.enabled) }
                Link("在 Tronscan 核对付款", destination: TransferReceipt(txHash: rental.paymentHash).tronscanURL)
                Text(rental.paymentHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if rental.receipt?.succeeded == true {
                    Button("按当前资源重新估价") {
                        do {
                            var value = journal; value.rental?.ready = true; try saveJournal(value)
                            stage = .input
                            if validAddress, validAmount { prepareQuote() }
                        } catch { statusMessage = error.localizedDescription }
                    }.disabled(checking)
                }
            }
            Text("确认付款成功且能量到账后重新估价。关闭窗口会保留记录，不会重复购买。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(checking ? "正在查询…" : "检查付款与资源") { checkPendingRental() }.disabled(checking)
                Spacer()
                Button("暂时关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func receiptView(_ receipt: TransferReceipt, uncertain: Bool) -> some View {
        let result = journal.transfer?.receipt
        return VStack(alignment: .leading, spacing: 16) {
            Label(result.map { $0.succeeded ? "链上转账成功" : "链上执行失败" }
                  ?? (uncertain ? "广播状态待确认" : "节点已受理，等待链上结果"),
                  systemImage: result.map { $0.succeeded ? "checkmark.circle" : "xmark.circle" } ?? "clock")
                .font(.headline).foregroundStyle(result.map { $0.succeeded ? Color.green : .red } ?? .orange)
            if let result {
                Text("实际网络费：\(TronGridClient.formatUSDT(result.feeSun)) TRX")
                Text("能量 \(result.energyConsumed)，能量费 \(TronGridClient.formatUSDT(result.energyFeeSun)) TRX，带宽费 \(TronGridClient.formatUSDT(result.bandwidthFeeSun)) TRX")
                    .font(.callout)
                if !result.succeeded { Text("执行结果：\(result.result)。USDT 未成功转出，网络费用仍以回执为准。") }
            } else {
                Text("节点可能已经收到交易。请先核对下方哈希，勿立即重复转账。")
            }
            if let rental = journal.rental {
                Text("固定租金：\(TronGridClient.formatUSDT(rental.paidRentSun)) TRX")
                if let payment = rental.receipt {
                    Text("租赁付款实际网络费：\(TronGridClient.formatUSDT(payment.feeSun)) TRX")
                } else {
                    Text("租赁付款的实际网络费待查询确认").foregroundStyle(.secondary)
                }
                Link("查看租赁付款", destination: TransferReceipt(txHash: rental.paymentHash).tronscanURL)
            }
            if let total = journal.actualTotalSun {
                Text("实际合计支出：\(TronGridClient.formatUSDT(total)) TRX")
                    .font(.headline).monospacedDigit()
            }
            Text(receipt.txHash).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("复制哈希") { ClipboardManager.shared.copy(receipt.txHash, autoClearSeconds: 45) }
                Link("在 Tronscan 查看", destination: receipt.tronscanURL)
                Button(checking ? "正在查询…" : "查询实际费用") { refreshExecutionReceipt(receipt.txHash) }.disabled(checking)
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
    private func journalStore() throws -> TronTransferJournalStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc.cassette.coffer/wallet-transactions", isDirectory: true)
        return try TronTransferJournalStore(directory: directory, address: address)
    }
    private func saveJournal(_ value: TronTransferJournal) throws {
        do { try journalStore().save(value, replacing: journal); journal = value; storageError = nil }
        catch { storageError = "转账记录保存失败，已暂停新付款：\(error.localizedDescription)"; throw error }
    }
    private func loadJournal() {
        do {
            journal = try journalStore().load()
            // Older development builds stored only a hash. Keep them blocked for explicit chain review.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "coffer.wallet.pendingRental.\(address)") != nil
                || defaults.object(forKey: "coffer.wallet.pendingTransfer.\(address)") != nil {
                storageError = "检测到旧版待确认交易记录，请先核对上一笔链上交易，再迁移记录。"
                return
            }
            storageError = nil
            if let transfer = journal.transfer, transfer.receipt == nil {
                stage = .uncertain(TransferReceipt(txHash: transfer.hash))
            } else if journal.rental != nil && journal.rental?.ready != true {
                stage = .rentalPending
            }
        } catch { storageError = error.localizedDescription }
    }
    private func loadBalances() {
        balances = initialBalances
        loadJournal()
        // The detail screen already queried this balance. The quote always refreshes it before confirmation.
        guard initialBalances == nil else { return }
        let apiKey = AppSettings.shared.trongridApiKey
        balanceTask = Task { @MainActor in
            do {
                let value = try await TronGridClient(http: URLSessionHTTP(), apiKey: apiKey).balances(address: address)
                try Task.checkCancellation()
                balances = value; balanceError = nil
            } catch {
                guard !Task.isCancelled else { return }
                balanceError = error.localizedDescription
            }
        }
    }
    private func prepareQuote() {
        guard unlock.isUnlocked, validAddress, let sun = amountSun, sun > 0,
              !journal.blocksNewPayment, storageError == nil else { return }
        let destination = target
        balanceTask?.cancel()
        stage = .quoting
        statusMessage = nil
        operation = Task { @MainActor in
            do {
                let quote = try await service().quote(from: address, to: destination, usdtSun: sun, requireFeeBalance: false)
                try Task.checkCancellation()
                guard unlock.isUnlocked else { return }
                balances = quote.balances; balanceError = nil
                var rental: TronRentalPlan?
                var message: String?
                if journal.rental != nil && journal.transfer == nil {
                    message = "已有租赁付款，先使用现有资源重新估价，避免重复购买。"
                } else if quote.fee.energyBurned == 0 {
                    message = "现有能量足够，无需租赁。"
                } else {
                    do {
                        let energyQuote = try await TronSaveClient().quote(address: address, energy: quote.fee.energyBurned)
                        rental = try TronRentalPlan(quote: energyQuote, directFee: quote.fee)
                    } catch {
                        message = "TronSave 租赁报价暂不可用（\(error.localizedDescription)），可刷新报价。"
                    }
                }
                try Task.checkCancellation()
                selectedMode = rental.map {
                    $0.totalSun < quote.fee.feeSun && quote.balances.trxBalance >= $0.maximumTotalSun ? .rental : .direct
                } ?? .direct
                stage = .confirming(Draft(to: destination, amountSun: sun, quote: quote, rental: rental, rentalMessage: message))
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(error.localizedDescription)
            }
        }
    }
    private func signingKey() throws -> Data {
        try Task.checkCancellation()
        guard unlock.isUnlocked,
              let entry = unlock.document?.entries.first(where: { $0.id == entryID }),
              case .wallet(let payload) = entry.payload, payload.address == address,
              let secret = payload.secret else { throw TronWalletError.badPrivateKey }
        let wallet = TronWalletService()
        switch payload.secretKind {
        case .mnemonic: return try wallet.privateKeyData(fromMnemonic: secret)
        case .privateKey: return try wallet.privateKeyData(fromPrivateKey: secret)
        case .watchOnly: throw TronWalletError.badPrivateKey
        }
    }
    private func send(_ draft: Draft) {
        guard unlock.isUnlocked, case .authing = stage, !journal.blocksNewPayment, storageError == nil else { return }
        let mode = selectedMode
        stage = .broadcasting
        statusMessage = nil
        operation = Task { @MainActor in
            do {
                if journal.transfer?.receipt != nil { try saveJournal(TronTransferJournal()) }
                if mode == .rental, let rental = draft.rental {
                    progressText = "正在核对报价并购买本次能量…"
                    let before = try await service().quote(from: address, to: draft.to, usdtSun: draft.amountSun,
                                                           requireFeeBalance: false, refreshFeeParameters: true)
                    let verified = try TronRentalPlan(quote: rental.quote, directFee: before.fee)
                    guard rental.quote.isFresh(), before.fee.energyBurned == rental.quote.energy,
                          verified.totalSun <= rental.totalSun, verified.maximumTotalSun <= rental.maximumTotalSun,
                          before.balances.trxBalance >= verified.maximumTotalSun else { throw RentalError.expired }
                    let payment = try await service().signRentalPayment(from: address, amountSun: rental.quote.rentSun,
                                                                        signingKey: signingKey)
                    guard rental.quote.isFresh(), unlock.isUnlocked else { throw RentalError.expired }
                    var value = journal
                    value.rental = TronRentalRecord(paymentHash: payment.txHash, expiration: payment.expiration,
                                                     energyTarget: before.fee.energy, rentSun: rental.quote.rentSun)
                    try saveJournal(value)
                    let orderID: String
                    do { orderID = try await TronSaveClient().buy(quote: rental.quote, payment: payment) }
                    catch RentalError.expired {
                        value.rental = nil; try saveJournal(value); throw RentalError.expired
                    }
                    catch { stage = .rentalPending; statusMessage = error.localizedDescription; return }
                    value.rental?.orderID = orderID
                    try saveJournal(value)
                    progressText = "租赁付款已提交，正在等待付款确认与能量到账…"
                    var ready = false
                    for _ in 0..<10 {
                        try await Task.sleep(for: .seconds(2))
                        if try await resolveRental() { ready = true; break }
                    }
                    guard ready else { stage = .rentalPending; return }
                }
                progressText = "正在复核费用并转出 USDT…"
                let latest = try await service().quote(from: address, to: draft.to, usdtSun: draft.amountSun,
                                                      requireFeeBalance: false, refreshFeeParameters: true)
                let agreedExpected = mode == .rental ? draft.rental?.transferFeeSun ?? 0 : draft.quote.fee.feeSun
                let agreedMaximum = mode == .rental
                    ? (draft.rental!.maximumTotalSun - draft.rental!.quote.rentSun - draft.rental!.paymentFeeSun)
                    : draft.quote.fee.maximumFeeSun
                guard latest.fee.feeSun <= agreedExpected, latest.fee.maximumFeeSun <= agreedMaximum else {
                    selectedMode = .direct
                    stage = .confirming(Draft(to: draft.to, amountSun: draft.amountSun, quote: latest, rental: nil,
                                              rentalMessage: "费用或可用资源发生变化，请核对后重新确认。"))
                    return
                }
                guard latest.balances.trxBalance >= latest.fee.maximumFeeSun else {
                    throw TransferValidationError.insufficientTRXForFee(neededSun: latest.fee.maximumFeeSun,
                                                                       haveSun: latest.balances.trxBalance)
                }
                let receipt = try await service().sendUSDT(
                    from: address, to: draft.to, usdtSun: draft.amountSun, feeLimitSun: latest.fee.feeLimitSun,
                    bandwidthLimit: latest.fee.bandwidthRequired, willBroadcast: { hash, expiration in
                        guard unlock.isUnlocked else { throw CancellationError() }
                        var value = journal
                        value.transfer = TronTransferRecord(hash: hash, expiration: expiration)
                        try saveJournal(value)
                    }, signingKey: signingKey)
                stage = .done(receipt)
                pollExecutionReceipt(receipt.txHash)
            } catch BroadcastError.uncertain(let hash) {
                stage = .uncertain(TransferReceipt(txHash: hash))
                statusMessage = "广播结果待确认，已保留交易记录。"
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = error.localizedDescription
                if let transfer = journal.transfer, transfer.receipt == nil {
                    stage = .uncertain(TransferReceipt(txHash: transfer.hash))
                } else if journal.rental != nil && journal.rental?.ready != true {
                    stage = .rentalPending
                } else { stage = .failed(error.localizedDescription) }
            }
        }
    }
    private func resolveRental() async throws -> Bool {
        guard let rental = journal.rental else { return false }
        guard let payment = try await service().executionReceipt(hash: rental.paymentHash) else {
            if try await service().isExpiredUnconfirmed(hash: rental.paymentHash, expiration: rental.expiration) {
                var value = journal; value.rental = nil; try saveJournal(value)
                throw RentalError.expired
            }
            return false
        }
        var value = journal
        value.rental?.receipt = payment
        if !payment.succeeded {
            value.rental?.ready = true; try saveJournal(value)
            throw BroadcastError.rejected("租赁付款执行失败，实际网络费 \(TronGridClient.formatUSDT(payment.feeSun)) TRX")
        }
        try saveJournal(value)
        let resources = try await service().resources(address: address)
        value.rental?.ready = resources.energy >= rental.energyTarget
        try saveJournal(value)
        return value.rental?.ready == true
    }
    private func checkPendingRental() {
        guard !checking else { return }
        checking = true; statusMessage = nil
        operation = Task { @MainActor in
            defer { checking = false }
            do {
                if try await resolveRental() {
                    stage = .input
                    if validAddress, validAmount { prepareQuote() }
                } else {
                    stage = .rentalPending
                    statusMessage = journal.rental?.receipt == nil
                        ? "付款尚无链上回执，请稍后查询。" : "付款成功，能量尚不足，请稍后查询或联系 TronSave 核对订单。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = error.localizedDescription
                stage = journal.rental == nil || journal.rental?.ready == true ? .input : .rentalPending
            }
        }
    }
    private func fetchExecutionReceipt(_ hash: String) async throws -> Bool {
        var value = journal
        if let rental = value.rental, rental.receipt == nil {
            value.rental?.receipt = try await service().executionReceipt(hash: rental.paymentHash)
        }
        if let result = try await service().executionReceipt(hash: hash) {
            guard value.transfer?.hash == hash else { throw TronGridError.badResponse }
            value.transfer?.receipt = result
            try saveJournal(value)
            stage = .done(TransferReceipt(txHash: hash))
            return true
        }
        try saveJournal(value)
        return false
    }
    private func pollExecutionReceipt(_ hash: String) {
        checking = true
        operation = Task { @MainActor in
            defer { checking = false }
            for _ in 0..<8 {
                do {
                    try Task.checkCancellation()
                    if try await fetchExecutionReceipt(hash) { statusMessage = nil; return }
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    guard !Task.isCancelled else { return }
                    statusMessage = "回执查询失败，可点查询实际费用重试：\(error.localizedDescription)"
                    return
                }
            }
            statusMessage = "链上回执仍待确认，可稍后查询。"
        }
    }
    private func refreshExecutionReceipt(_ hash: String) {
        guard !checking else { return }
        checking = true; statusMessage = nil
        operation = Task { @MainActor in
            defer { checking = false }
            do {
                if try await fetchExecutionReceipt(hash) { return }
                if let transfer = journal.transfer,
                   try await service().isExpiredUnconfirmed(hash: hash, expiration: transfer.expiration) {
                    var value = journal; value.transfer = nil; try saveJournal(value)
                    stage = .input
                    statusMessage = "交易已过期且完整节点和固化链均查无记录；可重新估价。"
                } else { statusMessage = "尚无链上回执，请稍后再查，勿重复发送。" }
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = "查询失败：\(error.localizedDescription)"
            }
        }
    }
}
