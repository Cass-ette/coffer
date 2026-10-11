import XCTest
@testable import CofferCore

final class GasFreeCredentialStoreTests: XCTestCase {
    func testIsolatedKeychainRoundTripUpdateAndDelete() throws {
        let store = GasFreeCredentialStore(service: "cc.cassette.coffer.test.gasfree." + UUID().uuidString)
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let first = try GasFreeCredentials(key: "test-key", secret: "test-secret")
        try store.save(first)
        XCTAssertEqual(try store.load(), first)
        let replacement = try GasFreeCredentials(key: "new-key", secret: "new-secret")
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
