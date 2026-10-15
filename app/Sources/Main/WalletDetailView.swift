import SwiftUI
import CoreImage.CIFilterBuiltins
import CofferCore

@MainActor
private final class WalletBalanceCache {
    static let shared = WalletBalanceCache()
    var values: [String: CachedTronBalances] = [:]
}

struct WalletDetailSection: View {
    let entryID: UUID
    let address: String
    let secretKind: WalletPayload.SecretKind
    @EnvironmentObject private var unlock: UnlockService
    @ObservedObject private var settings = AppSettings.shared
    @State private var cached: CachedTronBalances?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var showingReceive = false
    @State private var showingSecret = false
    @State private var showingTransfer = false
    @State private var showingGasFree = false
    @State private var revealedSecret: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Tron 主网 · USDT", systemImage: "network").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            if settings.trongridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("当前使用匿名查询额度，易触发限流。")
                        .font(.caption).foregroundStyle(.secondary)
                    CofferSettingsButton("配置 API key").buttonStyle(.link)
                }
            }
            if let cached {
                Text("\(TronGridClient.formatUSDT(cached.balances.usdtSun)) USDT")
                    .font(.system(.title, design: .rounded).bold()).monospacedDigit()
                Text("\(TronGridClient.formatUSDT(cached.balances.trxBalance)) TRX · 手续费余额")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text("上次更新：\(cached.updatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(loading ? "正在查询余额…" : "余额不可用，点按刷新重试")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(cached == nil ? errorMessage : "刷新失败，目前显示缓存余额。\(errorMessage)")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("刷新", systemImage: "arrow.clockwise") { refresh() }.disabled(loading)
                Button("收款", systemImage: "qrcode") { showingReceive = true }
                Button("转账", systemImage: "arrow.up.right") {
                    refreshTask?.cancel()
                    loading = false
                    showingTransfer = true
                }
                    .disabled(secretKind == .watchOnly)
            }
            if secretKind == .watchOnly {
                Text("此钱包未存助记词/私钥，仅可收款与查余额")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button(secretKind == .mnemonic ? "查看助记词…" : "查看私钥…") {
                    revealedSecret = nil
                    showingSecret = true
                }.buttonStyle(.link)
            }
            Divider()
            Button("GasFree · 用 USDT 付手续费") {
                refreshTask?.cancel(); loading = false; showingGasFree = true
            }
            Text("独立收款地址与余额，可查看激活费、服务费后选择使用。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onAppear(perform: loadCachedBalance)
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            revealedSecret = nil
            showingSecret = false
        }
        .onChange(of: unlock.isUnlocked) { unlocked in
            if !unlocked {
                revealedSecret = nil
                showingSecret = false
                showingReceive = false
                showingTransfer = false
                showingGasFree = false
                refreshTask?.cancel()
            }
        }
        .sheet(isPresented: $showingReceive) {
            WalletReceiveSheet(address: address)
        }
        .sheet(isPresented: $showingTransfer, onDismiss: {
            if unlock.isUnlocked { refresh() }
        }) {
            TransferSheet(entryID: entryID, address: address, initialBalances: cached?.balances)
        }
        .sheet(isPresented: $showingGasFree) { GasFreeSheet(entryID: entryID, owner: address) }
        .sheet(isPresented: $showingSecret, onDismiss: { revealedSecret = nil }) {
            if let revealedSecret {
                VStack(alignment: .leading, spacing: 18) {
                    Text(secretKind == .mnemonic ? "钱包助记词" : "钱包私钥").font(.title2.bold())
                    Text("⚠️ 此凭证控制钱包全部资产。抄纸备份，禁止拍照、截图或存入云端。")
                        .foregroundStyle(.orange)
                    Text(revealedSecret)
                        .font(.system(.title3, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("关闭") {
                            self.revealedSecret = nil
                            showingSecret = false
                        }.keyboardShortcut(.cancelAction)
                    }
                }.padding(28).frame(width: 520)
            } else {
                WalletAuthenticationSheet(reason: secretKind == .mnemonic ? "查看钱包助记词" : "查看钱包私钥",
                                          onAuthorized: revealSecret,
                                          onCancel: { showingSecret = false })
            }
        }
    }

    private func revealSecret() {
        guard unlock.isUnlocked,
              let entry = unlock.document?.entries.first(where: { $0.id == entryID }),
              case .wallet(let payload) = entry.payload,
              payload.address == address, payload.secretKind != .watchOnly,
              let secret = payload.secret, !secret.isEmpty else {
            showingSecret = false
            errorMessage = "此钱包没有可查看的凭证"
            return
        }
        revealedSecret = secret
    }

    private func loadCachedBalance() {
        cached = WalletBalanceCache.shared.values[address]
        if cached?.isFresh(maxAge: TimeInterval(settings.balanceCacheSeconds)) != true { refresh() }
    }

    private func refresh() {
        refreshTask?.cancel()
        loading = true
        let target = address
        let apiKey = settings.trongridApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshTask = Task { @MainActor in
            do {
                let balances = try await TronGridClient(http: URLSessionHTTP(), apiKey: apiKey).balances(address: target)
                try Task.checkCancellation()
                let value = CachedTronBalances(balances: balances, updatedAt: Date())
                WalletBalanceCache.shared.values[target] = value
                cached = value
                errorMessage = nil
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                loading = false
            }
        }
    }
}

struct WalletReceiveSheet: View {
    let address: String
    var title = "Tron 主网收款"
    var instruction = "仅接收 Tron 网络的 TRX / TRC-20 USDT。"
    @Environment(\.dismiss) private var dismiss
    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.title2.bold())
            if let qrImage {
                Image(nsImage: qrImage).interpolation(.none).resizable()
                    .frame(width: 220, height: 220)
                    .padding(16).background(.white)
                    .accessibilityLabel("Tron 收款地址二维码")
            }
            Text(address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(instruction)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("复制地址") { ClipboardManager.shared.copy(address, autoClearSeconds: 45) }
            }
        }.padding(28).frame(width: 500)
    }
}
