import SwiftUI

@MainActor
struct FirstRunView: View {
    @EnvironmentObject var app: AppState
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Coffer")
                .font(.largeTitle)
            Text("Create your master password")
                .font(.headline)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            SecureField("Confirm Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button("Create Vault") {
                createVault()
            }
            .disabled(!isValid)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    private var isValid: Bool {
        password.count >= 8 && password == confirmPassword
    }

    private func createVault() {
        do {
            try app.unlock.createVault(masterPassword: password)
            app.phase = .unlocked
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
