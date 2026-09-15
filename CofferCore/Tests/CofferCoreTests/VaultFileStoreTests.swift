import XCTest
@testable import CofferCore

final class VaultFileStoreTests: XCTestCase {
    var dir: URL!
    var store: VaultFileStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coffer-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = VaultFileStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func envelope(updatedAt: Date = Date()) -> VaultFileEnvelope {
        VaultFileEnvelope(
            kdf: .init(algo: "PBKDF2-SHA256", iterations: 1000, salt: Data([1, 2, 3])),
            wrappedDEK: Data([9, 9]),
            ciphertext: Data([7, 7, 7]),
            updatedAt: updatedAt
        )
    }

    func testFirstWriteCreatesVaultFile() throws {
        try store.write(envelope())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("vault.vault").path))
        XCTAssertNil(store.latestBackup())  // 第一次写入尚无备份
    }

    func testRotationKeepsExactlyThreeBackups() throws {
        // 用可区分的时间戳钉死轮换顺序：写 6 次后 vault=t6, bak1=t5, bak2=t4, bak3=t3
        let times = (1...6).map { Date(timeIntervalSince1970: Double($0)) }
        for t in times { try store.write(envelope(updatedAt: t)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["vault.bak1", "vault.bak2", "vault.bak3", "vault.vault"])
        XCTAssertEqual(try store.readEnvelope().updatedAt, times[5])
        XCTAssertEqual(try store.readBackup(1)?.updatedAt, times[4])
        XCTAssertEqual(try store.readBackup(2)?.updatedAt, times[3])
        XCTAssertEqual(try store.readBackup(3)?.updatedAt, times[2])
    }

    func testRestoreFromBackup() throws {
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        try store.write(envelope(updatedAt: t1))
        try store.write(envelope(updatedAt: t2))
        // 用 bak1(t1) 覆盖 vault：被覆盖的 t2 轮换进新 bak1，好副本仍在 bak 链上
        try store.restoreFromBackup(1)
        XCTAssertEqual(try store.readEnvelope().updatedAt, t1)
        XCTAssertEqual(store.latestBackup()?.updatedAt, t2)
    }

    func testLatestBackupIsMostRecent() throws {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        try store.write(envelope(updatedAt: t0))
        try store.write(envelope(updatedAt: t1))
        XCTAssertEqual(store.latestBackup()?.updatedAt, t0)
        XCTAssertEqual(try store.readEnvelope().updatedAt, t1)
    }

    func testCorruptedVaultDetectedButBackupIntact() throws {
        try store.write(envelope(updatedAt: Date(timeIntervalSince1970: 1)))
        try store.write(envelope(updatedAt: Date(timeIntervalSince1970: 2))) // bak1 = t1
        try Data("garbage not json".utf8).write(to: store.vaultURL)
        XCTAssertThrowsError(try store.readEnvelope())
        XCTAssertEqual(store.latestBackup()?.updatedAt, Date(timeIntervalSince1970: 1))
    }
}
