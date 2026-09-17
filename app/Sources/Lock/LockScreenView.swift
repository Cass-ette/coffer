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
    @State private var mode: UnlockMode = .biometrics
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var biometricsAvailable = false

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
        .task {
            biometricsAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
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
        // Call unlock synchronously (like KeyShelf does)
        // The biometric prompt happens immediately, completion handler processes result
        unlock.unlockWithBiometricsSync { [weak app] result in
            Task { @MainActor in
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
