import SwiftUI

@MainActor
struct LockScreenView: View {
    @EnvironmentObject var app: AppState
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Coffer is Locked")
                .font(.largeTitle)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit {
                    unlock()
                }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button("Unlock") {
                unlock()
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    private func unlock() {
        do {
            try app.unlock.unlockWithMasterPassword(password)
            app.phase = .unlocked
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = "Incorrect password"
            password = ""
        }
    }
}
