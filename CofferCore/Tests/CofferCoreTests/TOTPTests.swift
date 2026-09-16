import XCTest
@testable import CofferCore

final class TOTPTests: XCTestCase {
    // RFC 6238 Appendix B，SHA1，secret = ASCII "12345678901234567890"
    private let secret = Data("12345678901234567890".utf8)

    private func config(digits: Int = 8, period: Int = 30) -> TOTPConfig {
        TOTPConfig(secret: secret, algorithm: .SHA1, digits: digits, period: period)
    }

    func testRFC6238Vectors() {
        // (unix 时间, 8 位期望码)
        let vectors: [(Int, String)] = [
            (59, "94287082"),
            (1111111109, "07081804"),
            (1111111111, "14050471"),
            (1234567890, "89005924"),
            (2000000000, "69279037"),
            (20000000000, "65353130"),
        ]
        for (unix, expected) in vectors {
            let gen = TOTPGenerator(config: config())
            XCTAssertEqual(gen.code(at: Date(timeIntervalSince1970: Double(unix))), expected,
                           "T=\(unix)")
        }
    }

    func testSixDigitTruncation() {
        let gen = TOTPGenerator(config: config(digits: 6))
        XCTAssertEqual(gen.code(at: Date(timeIntervalSince1970: 59)), "287082")
    }

    func testRemainingSeconds() {
        let gen = TOTPGenerator(config: config())
        XCTAssertEqual(gen.remainingSeconds(at: Date(timeIntervalSince1970: 59)), 1)
        XCTAssertEqual(gen.remainingSeconds(at: Date(timeIntervalSince1970: 60)), 30)
    }

    func testBase32Decode() throws {
        // "JBSWY3DPEHPK3PXP" = "Hello!" + DEADBEEF（10 字节，标准测试串）
        let helloDeadBeef = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try Base32.decode("JBSWY3DPEHPK3PXP"), helloDeadBeef)
        XCTAssertEqual(try Base32.decode("jbsw y3dp-ehpk 3pxp=="), helloDeadBeef,
                       "忽略大小写/空格/连字符/padding")
        XCTAssertThrowsError(try Base32.decode("1O0A"))  // 非法字符
    }

    func testOTPAuthParsing() throws {
        // Use 32-char secret that meets 16-byte minimum
        let validSecret = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        let cfg = try OTPAuthParser.parse(
            "otpauth://totp/Example:alice%40example.com?secret=\(validSecret)&issuer=Example&algorithm=SHA256&digits=6&period=30")
        XCTAssertEqual(cfg.algorithm, .SHA256)
        XCTAssertEqual(cfg.digits, 6)
        XCTAssertEqual(cfg.period, 30)
        XCTAssertGreaterThanOrEqual(cfg.secret.count, 16)
    }

    func testOTPAuthDefaultsAndRejection() throws {
        // Use a 32-char base32 string that decodes to ≥16 bytes (32 * 5 / 8 = 20 bytes)
        let validSecret = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        let cfg = try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)")
        XCTAssertEqual(cfg.algorithm, .SHA1)
        XCTAssertEqual(cfg.digits, 6)
        XCTAssertEqual(cfg.period, 30)
        XCTAssertThrowsError(try OTPAuthParser.parse("https://example.com"))          // 非 otpauth
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret="))     // 缺 secret
    }

    // MARK: - Validation Tests (Critical crash prevention)

    func testOTPAuthRejectsInvalidDigits() throws {
        // Use 32-char secret to pass secret length check
        let validSecret = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        // digits ≥ 10 causes UInt32 overflow crash
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)&digits=10")) { error in
            guard case TOTPError.invalidDigits(let d) = error else {
                XCTFail("Expected invalidDigits, got \(error)")
                return
            }
            XCTAssertEqual(d, 10)
        }
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)&digits=0"))
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)&digits=-5"))
    }

    func testOTPAuthRejectsInvalidPeriod() throws {
        // Use 32-char secret to pass secret length check
        let validSecret = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        // period = 0 causes division by zero crash
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)&period=0")) { error in
            guard case TOTPError.invalidPeriod(let p) = error else {
                XCTFail("Expected invalidPeriod, got \(error)")
                return
            }
            XCTAssertEqual(p, 0)
        }
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)&period=-30"))
    }

    func testOTPAuthRejectsEmptySecret() throws {
        // Empty secret after base32 decode
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=====")) { error in
            XCTAssertEqual(error as? TOTPError, .missingSecret)
        }
    }

    func testOTPAuthWarnsShortSecret() throws {
        // RFC 4226 recommends ≥128 bits (16 bytes), "AA" decodes to 1 byte
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret=AA")) { error in
            guard case TOTPError.secretTooShort(let len) = error else {
                XCTFail("Expected secretTooShort, got \(error)")
                return
            }
            XCTAssertLessThan(len, 16)
        }
        // 16 bytes should be accepted
        let validSecret = String(repeating: "A", count: 26)  // 26 base32 chars ≈ 16 bytes
        XCTAssertNoThrow(try OTPAuthParser.parse("otpauth://totp/x?secret=\(validSecret)"))
    }

    // MARK: - SHA256/SHA512 coverage

    func testSHA256Algorithm() throws {
        // RFC 6238 Appendix B has SHA256 vectors
        let secret = Data("12345678901234567890123456789012".utf8)
        let config = TOTPConfig(secret: secret, algorithm: .SHA256, digits: 8, period: 30)
        let gen = TOTPGenerator(config: config)
        // SHA256 test vector from RFC 6238
        XCTAssertEqual(gen.code(at: Date(timeIntervalSince1970: 59)), "46119246")
    }

    func testSHA512Algorithm() throws {
        // RFC 6238 Appendix B has SHA512 vectors
        let secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let config = TOTPConfig(secret: secret, algorithm: .SHA512, digits: 8, period: 30)
        let gen = TOTPGenerator(config: config)
        // SHA512 test vector from RFC 6238
        XCTAssertEqual(gen.code(at: Date(timeIntervalSince1970: 59)), "90693936")
    }
}
