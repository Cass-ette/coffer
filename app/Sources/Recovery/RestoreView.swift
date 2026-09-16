import SwiftUI

@MainActor
struct RestoreView: View {
    let hasBackup: Bool
    @EnvironmentObject var app: AppState
    @State private var showingDiscardConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Vault Corrupted")
                .font(.largeTitle)

            Text("Your vault file is corrupted and cannot be opened.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if hasBackup {
                Button("Restore from Backup") {
                    restoreFromBackup()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Discard and Create New Vault") {
                showingDiscardConfirmation = true
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .alert("Discard Vault?", isPresented: $showingDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                discardVault()
            }
        } message: {
            Text("This will permanently delete your corrupted vault. This cannot be undone.")
        }
    }

    private func restoreFromBackup() {
        // Implementation will use app.unlock to restore
        errorMessage = "Restore not yet implemented"
    }

    private func discardVault() {
        app.phase = .firstRun
    }
}
