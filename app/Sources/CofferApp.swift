import SwiftUI

@main
struct CofferApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.unlock)
        }
        Settings {
            SettingsView()
        }
    }
}

private struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        switch app.phase {
        case .firstRun:
            FirstRunView()
        case .corrupted(let hasBackup):
            RestoreView(hasBackup: hasBackup)
        case .locked:
            LockScreenView()
        case .unlocked:
            MainView()
        }
    }
}
