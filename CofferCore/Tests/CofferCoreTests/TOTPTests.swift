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
        let cfg = try OTPAuthParser.parse(
            "otpauth://totp/Example:alice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA256&digits=6&period=30")
        XCTAssertEqual(cfg.secret, Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(cfg.algorithm, .SHA256)
        XCTAssertEqual(cfg.digits, 6)
        XCTAssertEqual(cfg.period, 30)
    }

    func testOTPAuthDefaultsAndRejection() throws {
        let cfg = try OTPAuthParser.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(cfg.algorithm, .SHA1)
        XCTAssertEqual(cfg.digits, 6)
        XCTAssertEqual(cfg.period, 30)
        XCTAssertThrowsError(try OTPAuthParser.parse("https://example.com"))          // 非 otpauth
        XCTAssertThrowsError(try OTPAuthParser.parse("otpauth://totp/x?secret="))     // 缺 secret
    }
}
