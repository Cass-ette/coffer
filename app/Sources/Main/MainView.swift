import SwiftUI

@MainActor
struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Vault Unlocked")
                .font(.largeTitle)

            Text("Your vault is now unlocked and ready to use.")
                .foregroundColor(.secondary)

            Button("Lock Vault") {
                app.didLock()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }
}
