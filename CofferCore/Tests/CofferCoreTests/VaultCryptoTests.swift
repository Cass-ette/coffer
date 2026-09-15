import XCTest
import CryptoKit
@testable import CofferCore

final class VaultCryptoTests: XCTestCase {
    // PBKDF2-HMAC-SHA256 公开测试向量
    func testPBKDF2KnownVectors() {
        XCTAssertEqual(
            VaultCrypto.pbkdf2(password: "password", salt: Data("salt".utf8), iterations: 1, length: 32).hexString,
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(
            VaultCrypto.pbkdf2(password: "password", salt: Data("salt".utf8), iterations: 2, length: 32).hexString,
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(
            VaultCrypto.pbkdf2(password: "password", salt: Data("salt".utf8), iterations: 4096, length: 32).hexString,
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(
            VaultCrypto.pbkdf2(password: "passwordPASSWORDpassword",
                               salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8),
                               iterations: 4096, length: 40).hexString,
            "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
    }

    func testDefaultIterationCost() {
        // 默认参数必须达到 spec 的 600k（只跑一次，约 0.3~0.5s）
        let start = Date()
        _ = VaultCrypto.pbkdf2(password: "x", salt: VaultCrypto.randomData(16))
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.05, "600k 迭代应当有可感知耗时")
        XCTAssertEqual(VaultCrypto.pbkdf2Iterations, 600_000)
    }

    func testDEKWrapUnwrapRoundtrip() throws {
        let dek = VaultCrypto.generateDEK()
        let salt = VaultCrypto.randomData(16)
        let kek = VaultCrypto.pbkdf2(password: "master-pw", salt: salt, iterations: 1000)
        let wrapped = try VaultCrypto.wrap(dek, with: kek)
        let back = try VaultCrypto.unwrap(wrapped, with: kek)
        XCTAssertEqual(back.withUnsafeBytes { Data($0) }, dek.withUnsafeBytes { Data($0) })
    }

    func testUnwrapWrongPasswordFails() throws {
        let dek = VaultCrypto.generateDEK()
        let salt = VaultCrypto.randomData(16)
        let wrapped = try VaultCrypto.wrap(dek, with: VaultCrypto.pbkdf2(password: "right", salt: salt, iterations: 1000))
        XCTAssertThrowsError(try VaultCrypto.unwrap(
            wrapped, with: VaultCrypto.pbkdf2(password: "wrong", salt: salt, iterations: 1000)))
    }

    func testEncryptDecryptRoundtripAndTamper() throws {
        let dek = VaultCrypto.generateDEK()
        let plaintext = Data("秘密内容 🤫".utf8)
        let sealed = try VaultCrypto.encrypt(plaintext, with: dek)
        XCTAssertEqual(try VaultCrypto.decrypt(sealed, with: dek), plaintext)
        var tampered = sealed
        tampered[tampered.count - 3] ^= 0xFF
        XCTAssertThrowsError(try VaultCrypto.decrypt(tampered, with: dek))
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
