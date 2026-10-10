import SwiftUI
import LocalAuthentication
import CofferCore

/// A fresh authentication for every secret reveal or signature.
struct WalletAuthenticationSheet: View {
    let reason: String
    let onAuthorized: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var unlock: UnlockService
    @State private var context: LAContext?
    @State private var needsMasterPassword = false
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reason).font(.title3.bold())
            if needsMasterPassword {
                Text("系统认证不可用，请再次输入 Coffer 主密码。")
                    .foregroundStyle(.secondary)
                SecureField("主密码", text: $password).onSubmit(verifyPassword)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            } else {
                ProgressView("请完成 Touch ID 或系统认证")
            }
            HStack {
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction)
                if needsMasterPassword {
                    Button("验证", action: verifyPassword)
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onAppear(perform: authenticate)
        .onDisappear {
            finished = true
            context?.invalidate()
            context = nil
            password = ""
        }
        .onChange(of: unlock.isUnlocked) { _, unlocked in
            if !unlocked { cancel() }
        }
    }

    private func authenticate() {
        guard context == nil, !finished, unlock.isUnlocked else { return }
        let auth = LAContext()
        auth.touchIDAuthenticationAllowableReuseDuration = 0
        context = auth
        var availabilityError: NSError?
        guard auth.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            needsMasterPassword = true
            return
        }
        // Completion-handler API matches Coffer's working macOS authentication flow.
        auth.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            Task { @MainActor in
                guard !finished, unlock.isUnlocked else { return }
                if success {
                    finished = true
                    onAuthorized()
                } else if let error = error as? LAError,
                          [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                    cancel()
                } else {
                    needsMasterPassword = true
                }
            }
        }
    }

    private func verifyPassword() {
        guard !finished, unlock.isUnlocked else { return }
        let result = unlock.unlockWithMasterPassword(password)
        password = ""
        if result == .unlocked {
            finished = true
            onAuthorized()
        } else {
            errorMessage = "主密码不正确，请重试"
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        context?.invalidate()
        password = ""
        onCancel()
    }
}
