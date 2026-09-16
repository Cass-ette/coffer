import SwiftUI
import CofferCore

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case firstRun
        case corrupted(hasBackup: Bool)
        case locked
        case unlocked
    }

    @Published var phase: Phase
    let unlock: UnlockService

    init() {
        let vaultDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc.cassette.coffer")

        let fileStore = VaultFileStore(directory: vaultDir)
        let vaultStore = VaultStore(fileStore: fileStore)
        let dekStore = SystemDEKStore()
        let prompt = TouchIDPrompt()

        self.unlock = UnlockService(vaultStore: vaultStore, dekStore: dekStore, prompt: prompt)

        let probe = vaultStore.probe()
        switch probe {
        case .firstRun:
            self.phase = .firstRun
        case .available:
            unlock.loadEnvelope()
            self.phase = .locked
        case .corrupted(let hasBackup):
            unlock.loadEnvelope()
            self.phase = .corrupted(hasBackup: hasBackup)
        }
    }

    func didLock() {
        unlock.lock()
        phase = .locked
    }
}
