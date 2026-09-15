import XCTest
import CryptoKit
@testable import CofferCore

final class VaultStoreTests: XCTestCase {
    var dir: URL!
    var fileStore: VaultFileStore!
    var store: VaultStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coffer-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: dir)
        store = VaultStore(fileStore: fileStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testProbeFirstRunWhenNothingExists() {
        XCTAssertEqual(store.probe(), .firstRun)
    }

    func testEmptyDocumentHasFourPresetGroups() {
        let doc = VaultDocument.empty()
        XCTAssertEqual(doc.groups.count, 4)
        XCTAssertEqual(doc.groups.map(\.name), ["内网系统", "校内服务", "开发密钥", "个人"])
        XCTAssertTrue(doc.entries.isEmpty)
    }

    func testCreateThenProbeAvailable() throws {
        _ = try store.createFirstVault(masterPassword: "pw-123456")
        XCTAssertEqual(store.probe(), .available)
    }

    func testUnlockWithCorrectAndWrongPassword() throws {
        let created = try store.createFirstVault(masterPassword: "pw-123456")
        XCTAssertEqual(created.entries.count, 0)
        let env = try fileStore.readEnvelope()
        let dek = try store.dek(from: env, masterPassword: "pw-123456")
        XCTAssertNoThrow(try store.document(from: env, dek: dek))
        XCTAssertThrowsError(try store.dek(from: env, masterPassword: "wrong"))
    }

    func testSaveRoundtripPreservesEntriesAndKeepsWrappedDEK() throws {
        _ = try store.createFirstVault(masterPassword: "pw-123456")
        let env0 = try fileStore.readEnvelope()
        let dek = try store.dek(from: env0, masterPassword: "pw-123456")
        var doc = try store.document(from: env0, dek: dek)
        var e = Entry.fixture(type: .login)
        e.payload = .login(LoginPayload(username: "u", password: "p", urls: ["https://x.test"]))
        doc.entries.append(e)

        let env1 = try store.save(doc, dek: dek, previous: env0)
        XCTAssertEqual(env1.wrappedDEK, env0.wrappedDEK, "改密码之外的保存不得重包装 DEK")

        let dekAfter = try store.dek(from: env1, masterPassword: "pw-123456")
        let docBack = try store.document(from: env1, dek: dekAfter)
        XCTAssertEqual(docBack.entries.first?.title, e.title)
        XCTAssertEqual(docBack.groups.map(\.name), doc.groups.map(\.name))
    }

    func testCorruptedVaultProbeReportsBackup() throws {
        _ = try store.createFirstVault(masterPassword: "pw-123456")
        let env = try fileStore.readEnvelope()
        let dek = try store.dek(from: env, masterPassword: "pw-123456")
        _ = try store.save(VaultDocument.empty(), dek: dek, previous: env) // 产生 bak1
        try Data("junk".utf8).write(to: fileStore.vaultURL)
        XCTAssertEqual(store.probe(), .corrupted(hasBackup: true))
    }

    func testChangeMasterPassword() throws {
        _ = try store.createFirstVault(masterPassword: "old-pw")
        let env0 = try fileStore.readEnvelope()
        let dek = try store.dek(from: env0, masterPassword: "old-pw")
        var doc = try store.document(from: env0, dek: dek)
        doc.entries.append(Entry.fixture(type: .login))
        let env1 = try store.save(doc, dek: dek, previous: env0)

        let env2 = try store.changeMasterPassword("new-pw", dek: dek, previous: env1)
        XCTAssertEqual(env2.ciphertext, env1.ciphertext, "改密码不重加密文档")
        XCTAssertNotEqual(env2.wrappedDEK, env1.wrappedDEK)
        XCTAssertNotEqual(env2.kdf.salt, env1.kdf.salt)
        XCTAssertThrowsError(try store.dek(from: env2, masterPassword: "old-pw"))
        let docBack = try store.document(from: env2, dek: store.dek(from: env2, masterPassword: "new-pw"))
        XCTAssertEqual(docBack.entries.count, 1)
    }
}
