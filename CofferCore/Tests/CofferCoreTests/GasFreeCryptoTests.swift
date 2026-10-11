import XCTest
@testable import CofferCore

final class GasFreeCryptoTests: XCTestCase {
    // Independent vectors from gasfreeio/gasfree-sdk-js src/tests/constant.ts.
    func testOfficialMainnetAddressVectors() throws {
        for (owner, expected) in [
            ("TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC", "TBwmA2PtMXC4HiGvfi8xg2jZd5i3y89DjK"),
            ("TDvSsdrNM5eeXNL3czpa6AxLDHZA9nwe9K", "TTA7pGKZdpkJwiwuookcfbkdq6kZxysn86"),
            ("TKTX96CBxr5kvhjsDHcqoiPWZageGxoTW3", "TJyjjMa8AKvARKyMRNm2JrZ6ftQh3cC6Zg")
        ] { XCTAssertEqual(try GasFreeCrypto.address(owner: owner), expected) }
        XCTAssertThrowsError(try GasFreeCrypto.address(owner: "invalid"))
    }

    func testOfficialTIP712VectorAndMainnetDomainIsolation() throws {
        let permit = GasFreePermit(owner: "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC",
            receiver: "TJM1BE5wq1VdHh3gwjUeyaVkvZp9DVYCfC", provider: "TDbJyQ6g1Lx9BAfEEeN5S5TMjjDRAVFCaA",
            value: 10000, maxFee: 2000, deadline: 1726207632, nonce: 2)
        let hash = try GasFreeCrypto.hash(permit, token: "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
            chainID: 3448148188, controller: "THQGuFzL87ZqhxkgqYEryRAd7gqFqL5rdc")
        XCTAssertEqual(GasFreeCrypto.hex(hash), "b1226f3a0b690b04e2c39fac3b58352ed68943a12a54b58035045215aaf0b9b1")
        XCTAssertNotEqual(hash, try GasFreeCrypto.hash(permit))
        // Read-only mainnet Controller getMessageHashForTransfer query, 2026-10-11.
        XCTAssertEqual(try GasFreeCrypto.hex(GasFreeCrypto.hash(permit)),
                       "4578bb8cbd81e816b9db5d5d6e98d0c7a2c13339380ff3c4476af5c4fb5db189")
    }

    func testSignatureRecoveryByteAndOwnerValidation() throws {
        let permit = GasFreePermit(owner: "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC",
            receiver: "TJM1BE5wq1VdHh3gwjUeyaVkvZp9DVYCfC", provider: "TDbJyQ6g1Lx9BAfEEeN5S5TMjjDRAVFCaA",
            value: 5000000000, maxFee: 2000000, deadline: 1726207632, nonce: 2)
        let key = Data(repeating: 0, count: 31) + Data([1])
        let signature = try GasFreeCrypto.sign(permit, key: key)
        XCTAssertEqual(signature.count, 65)
        XCTAssertTrue([27, 28].contains(signature.last!))
        XCTAssertThrowsError(try GasFreeCrypto.sign(permit, key: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try GasFreeCrypto.sign(permit, key: Data(repeating: 0, count: 31) + Data([2])))
        XCTAssertEqual(GasFreeCrypto.hex(GasFreeCrypto.word(5000000000)), String(repeating: "0", count: 54) + "012a05f200")
    }
}
