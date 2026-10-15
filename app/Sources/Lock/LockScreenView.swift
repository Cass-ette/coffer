import SwiftUI
import LocalAuthentication
import CofferCore

@MainActor
struct LockScreenView: View {
    enum UnlockMode {
        case biometrics
        case password
    }

    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: UnlockMode = .biometrics
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var biometricsAvailable = false
    @State private var isAuthenticating = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Coffer is Locked")
                .font(.largeTitle)

            if mode == .biometrics && biometricsAvailable {
                biometricsView
            } else {
                passwordView
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
        .disabled(isAuthenticating)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            biometricsAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            guard biometricsAvailable, mode == .biometrics,
                  app.shouldPromptForUnlockOnLaunch else { return }
            unlockWithBiometrics()
        }
        .alert("Unlock Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var biometricsView: some View {
        VStack(spacing: 16) {
            Button {
                unlockWithBiometrics()
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Use Master Password") {
                app.shouldPromptForUnlockOnLaunch = false
                mode = .password
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

    private var passwordView: some View {
        VStack(spacing: 16) {
            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit {
                    unlockWithPassword()
                }

            if let errorMessage, !showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button("Unlock") {
                unlockWithPassword()
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)

            if biometricsAvailable {
                Button("Back to Touch ID") {
                    mode = .biometrics
                    password = ""
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }

    private func unlockWithBiometrics() {
        guard !isAuthenticating, app.phase == .locked else { return }
        // Consume before presenting: the system prompt can change scenePhase.
        app.shouldPromptForUnlockOnLaunch = false
        isAuthenticating = true
        unlock.unlockWithBiometricsSync { [weak app] result in
            Task { @MainActor in
                self.isAuthenticating = false
                switch result {
                case .unlocked:
                    app?.phase = .unlocked
                case .cancelled, .needMasterPassword:
                    self.mode = .password
                case .failed(let msg):
                    self.errorMessage = msg
                    self.showError = true
                case .wrongPassword:
                    break
                }
            }
        }
    }

    private func unlockWithPassword() {
        guard !isAuthenticating, app.phase == .locked else { return }
        app.shouldPromptForUnlockOnLaunch = false
        let result = unlock.unlockWithMasterPassword(password)
        switch result {
        case .unlocked:
            app.phase = .unlocked
            password = ""
            errorMessage = nil
        case .wrongPassword:
            errorMessage = "Incorrect password"
            password = ""
        case .failed(let msg):
            errorMessage = msg
            password = ""
        case .cancelled, .needMasterPassword:
            break
        }
    }
}
