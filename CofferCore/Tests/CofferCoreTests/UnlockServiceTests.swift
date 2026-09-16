import XCTest
import LocalAuthentication
@testable import CofferCore

final class UnlockServiceTests: XCTestCase {
    var dir: URL!
    var fileStore: VaultFileStore!
    var vaultStore: VaultStore!
    var dekStore: FakeDEKStore!
    var prompt: FakePrompt!
    var service: UnlockService!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coffer-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: dir)
        vaultStore = VaultStore(fileStore: fileStore)
        dekStore = FakeDEKStore()
        prompt = FakePrompt()
        service = UnlockService(vaultStore: vaultStore, dekStore: dekStore, prompt: prompt)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testCreateVaultStoresDEKInKeychainAndUnlocks() throws {
        XCTAssertEqual(service.probe(), .firstRun)
        XCTAssertTrue(try service.createVault(masterPassword: "pw-123456"))
        XCTAssertTrue(service.isUnlocked)
        XCTAssertEqual(service.document?.entries.count, 0)
        XCTAssertNotNil(dekStore.peek(), "建库后 DEK 必须写入 Keychain")
    }

    func testBiometryUnlockFlow() async throws {
        try service.createVault(masterPassword: "pw-123456")
        service.lock()
        XCTAssertFalse(service.isUnlocked)

        prompt.nextContext = LAContext()   // 模拟指纹通过
        let r = await service.unlockWithBiometrics()
        XCTAssertEqual(r, .unlocked)
        XCTAssertTrue(service.isUnlocked)
    }

    func testBiometryCancelledStaysLocked() async throws {
        try service.createVault(masterPassword: "pw-123456")
        service.lock()
        prompt.nextContext = nil           // 模拟用户取消
        let r = await service.unlockWithBiometrics()
        XCTAssertEqual(r, .cancelled)
        XCTAssertFalse(service.isUnlocked)
    }

    func testKeychainEmptyFallsBackToMasterPassword() async throws {
        try service.createVault(masterPassword: "pw-123456")
        service.lock()
        dekStore.stored = nil              // Keychain 条目丢失
        let r = await service.unlockWithBiometrics()
        XCTAssertEqual(r, .needMasterPassword)
        XCTAssertEqual(service.unlockWithMasterPassword("pw-123456"), .unlocked)
    }

    func testWrongMasterPassword() throws {
        try service.createVault(masterPassword: "pw-123456")
        service.lock()
        XCTAssertEqual(service.unlockWithMasterPassword("nope"), .wrongPassword)
        XCTAssertFalse(service.isUnlocked)
    }

    func testLockClearsEverything() throws {
        try service.createVault(masterPassword: "pw-123456")
        service.lock()
        XCTAssertFalse(service.isUnlocked)
        XCTAssertNil(service.document)
    }

    func testPersistWritesEntries() throws {
        try service.createVault(masterPassword: "pw-123456")
        var doc = service.document!
        let now = Date()
        doc.entries.append(Entry(
            id: UUID(),
            type: .login,
            title: "Test",
            subtitle: "",
            groupID: nil,
            tags: [],
            isFavorite: false,
            permissionNote: "",
            customFields: [],
            createdAt: now,
            updatedAt: now,
            payload: .login(LoginPayload(username: "user", password: "pass", urls: []))
        ))
        service.document = doc
        try service.persist()
        service.lock()
        XCTAssertEqual(service.unlockWithMasterPassword("pw-123456"), .unlocked)
        XCTAssertEqual(service.document?.entries.count, 1)
    }

    func testChangeMasterPasswordViaService() throws {
        try service.createVault(masterPassword: "old")
        try service.setMasterPassword("new")
        service.lock()
        XCTAssertEqual(service.unlockWithMasterPassword("old"), .wrongPassword)
        XCTAssertEqual(service.unlockWithMasterPassword("new"), .unlocked)
    }

    func testRestoreFromLatestBackup() throws {
        // Create vault and add an entry
        try service.createVault(masterPassword: "pw-123456")
        let now = Date()
        var doc = service.document!
        doc.entries.append(Entry(
            id: UUID(),
            type: .login,
            title: "Original",
            subtitle: "",
            groupID: nil,
            tags: [],
            isFavorite: false,
            permissionNote: "",
            customFields: [],
            createdAt: now,
            updatedAt: now,
            payload: .login(LoginPayload(username: "user1", password: "pass1", urls: []))
        ))
        service.document = doc
        try service.persist()

        // Add another entry (this will create a backup of the previous state)
        doc.entries.append(Entry(
            id: UUID(),
            type: .login,
            title: "Second",
            subtitle: "",
            groupID: nil,
            tags: [],
            isFavorite: false,
            permissionNote: "",
            customFields: [],
            createdAt: now,
            updatedAt: now,
            payload: .login(LoginPayload(username: "user2", password: "pass2", urls: []))
        ))
        service.document = doc
        try service.persist()

        // Verify we have 2 entries
        XCTAssertEqual(service.document?.entries.count, 2)

        // Restore from backup (should restore state with 1 entry)
        XCTAssertTrue(service.restoreFromLatestBackup())

        // Unlock and verify we're back to 1 entry
        service.lock()
        XCTAssertEqual(service.unlockWithMasterPassword("pw-123456"), .unlocked)
        XCTAssertEqual(service.document?.entries.count, 1)
        XCTAssertEqual(service.document?.entries.first?.title, "Original")
    }

    func testDiscardVaultAndBackups() throws {
        // Create vault
        try service.createVault(masterPassword: "pw-123456")
        XCTAssertTrue(service.isUnlocked)
        XCTAssertNotNil(dekStore.stored)

        // Discard everything
        service.discardVaultAndBackups()

        // Verify state is cleared
        XCTAssertFalse(service.isUnlocked)
        XCTAssertNil(service.document)
        XCTAssertNil(service.envelope)
        XCTAssertNil(dekStore.stored)

        // Verify probe shows firstRun
        XCTAssertEqual(service.probe(), .firstRun)
    }
}

final class FakePrompt: BiometryPrompting {
    var nextContext: LAContext?
    func authenticatedContext(reason: String) async -> LAContext? { nextContext }
}
