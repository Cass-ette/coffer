import SwiftUI
import CofferCore

struct GasFreeSettingsSection: View {
    @EnvironmentObject private var unlock: UnlockService
    @State private var key = ""
    @State private var secret = ""
    @State private var saved = false
    @State private var busy = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Section("官方 GasFree · USDT 付手续费") {
            Text(saved ? "已保存本机凭证，可到钱包详情打开 GasFree。" : "未启用：需申请单独的 GasFree API Key 和 API Secret。")
                .font(.caption).foregroundStyle(.secondary)
            Text("这是独立收款地址。首次转出可能收激活费，每次另收服务费，均用 USDT 支付。当前普通钱包余额不会自动转入。")
                .font(.caption).foregroundStyle(.secondary)
            Link("申请 GasFree API 凭证", destination: URL(string: "https://developer.gasfree.io/")!)
            SecureField(saved ? "新 API Key（留空保留现有）" : "GasFree API Key", text: $key)
                .disabled(busy)
            SecureField(saved ? "新 API Secret（留空保留现有）" : "GasFree API Secret", text: $secret)
                .disabled(busy)
            Text("使用主网凭证，申请可能需审核。验证通过后保存到此 Mac 的钥匙串，不随保险库备份同步。无需提供钱包私钥。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(key.isEmpty && secret.isEmpty ? "验证已保存凭证" : "验证并保存", action: verify)
                    .disabled(busy || (key.isEmpty && secret.isEmpty && !saved) || (key.isEmpty != secret.isEmpty))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if saved {
                    Button("移除 API 凭证", role: .destructive) {
                        do { try GasFreeCredentialStore().delete(); saved = false; message = "已移除 API 凭证，钱包地址和资金不变。" }
                        catch { message = error.localizedDescription }
                    }.disabled(busy)
                }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .disabled(!unlock.isUnlocked)
        .onAppear(perform: loadStatus)
        .onChange(of: unlock.isUnlocked) { _, unlocked in
            operation?.cancel(); busy = false; key = ""; secret = ""; message = nil
            if unlocked { loadStatus() }
        }
        .onDisappear { operation?.cancel(); key = ""; secret = "" }
    }

    private func loadStatus() {
        guard unlock.isUnlocked else { return }
        do { saved = try GasFreeCredentialStore().load() != nil }
        catch { message = error.localizedDescription }
    }
    private func verify() {
        guard unlock.isUnlocked, !busy else { return }
        busy = true; message = nil
        let enteredKey = key, enteredSecret = secret
        operation = Task { @MainActor in
            do {
                let store = GasFreeCredentialStore()
                let credentials: GasFreeCredentials
                if enteredKey.isEmpty && enteredSecret.isEmpty {
                    guard let existing = try store.load() else { throw GasFreeError.credentials }
                    credentials = existing
                } else { credentials = try GasFreeCredentials(key: enteredKey, secret: enteredSecret) }
                try await GasFreeClient(credentials: credentials).verifyCredentials()
                try Task.checkCancellation()
                guard unlock.isUnlocked else { return }
                try store.save(credentials)
                saved = true; key = ""; secret = ""
                message = "验证通过：主网服务已接受凭证。请到钱包详情 → GasFree 查看余额和实时费用。"
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
