import XCTest
@testable import CofferCore

final class TronWalletServiceTests: XCTestCase {
    let svc = TronWalletService()
    let goldenMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    let goldenAddress = "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"

    func testValidateAddress() {
        XCTAssertTrue(svc.validateAddress(goldenAddress))
        for invalid in ["abc", "AUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH", "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdI", ""] {
            XCTAssertFalse(svc.validateAddress(invalid))
        }
    }

    func testMnemonicToAddress() throws {
        XCTAssertEqual(try svc.address(fromMnemonic: goldenMnemonic), goldenAddress)
        XCTAssertEqual(try svc.address(fromMnemonic: goldenMnemonic.replacingOccurrences(of: " ", with: "\n")), goldenAddress)
    }

    func testGenerateMnemonicDeterministicFromEntropy() throws {
        let entropy = Data(repeating: 0x07, count: 16)
        let words = try svc.generateMnemonic(entropy: entropy)
        XCTAssertEqual(words, try svc.generateMnemonic(entropy: entropy))
        XCTAssertEqual(words.count, 12)
        XCTAssertTrue(svc.validateAddress(try svc.address(fromMnemonic: words.joined(separator: " "))))
    }

    func testGeneratedMnemonicUsesTwelveWords() throws {
        let words = try svc.generateMnemonic()
        XCTAssertEqual(words.count, 12)
        XCTAssertNoThrow(try svc.address(fromMnemonic: words.joined(separator: " ")))
        XCTAssertThrowsError(try svc.generateMnemonic(entropy: Data()))
    }

    func testInvalidMnemonicThrows() {
        XCTAssertThrowsError(try svc.address(fromMnemonic: "not twelve words"))
        XCTAssertThrowsError(try svc.address(fromMnemonic: Array(repeating: "abandon", count: 12).joined(separator: " ")))
    }

    func testPrivateKeyToAddress() throws {
        let key = try svc.privateKey(fromMnemonic: goldenMnemonic)
        XCTAssertEqual(key.count, 64)
        XCTAssertEqual(try svc.address(fromPrivateKey: key), goldenAddress)
    }

    func testInvalidPrivateKeysAreRejected() {
        for key in ["abc", String(repeating: "00", count: 32), String(repeating: "ff", count: 32), String(repeating: "zz", count: 32)] {
            XCTAssertThrowsError(try svc.address(fromPrivateKey: key))
        }
    }
}
