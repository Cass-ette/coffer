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
    let settings = AppSettings.shared
    private(set) var hotkeyRegistered = false

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

        HotkeyCenter.shared.handler = { [weak self] in
            guard let self else { return }
            QuickPanelController.shared.toggle(app: self)
        }
        hotkeyRegistered = HotkeyCenter.shared.register(
            keyCode: settings.hotkey.keyCode,
            modifiers: settings.hotkey.modifiers)
    }

    func didLock() {
        unlock.lock()
        phase = .locked
    }

    func upsert(_ entry: Entry) throws {
        guard var doc = unlock.document else { return }
        if let i = doc.entries.firstIndex(where: { $0.id == entry.id }) {
            doc.entries[i] = entry
        } else {
            doc.entries.append(entry)
        }
        unlock.document = doc
        try unlock.persist()
    }

    func delete(_ id: UUID) throws {
        guard var doc = unlock.document else { return }
        doc.entries.removeAll { $0.id == id }
        unlock.document = doc
        try unlock.persist()
    }
}
