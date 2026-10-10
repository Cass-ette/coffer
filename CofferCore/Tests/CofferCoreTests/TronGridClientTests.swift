import XCTest
@testable import CofferCore

final class TronGridClientTests: XCTestCase {
    final class MockHTTP: HTTPProviding {
        var stubs: [String: Data] = [:]
        var headers: [String: String] = [:]
        func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> Data {
            self.headers = headers
            return stubs[path] ?? Data()
        }
        func get(_ path: String, headers: [String: String]) async throws -> Data {
            self.headers = headers
            return stubs[path] ?? Data()
        }
    }

    func testParseBalances() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/test"] = Data(#"{"success":true,"data":[{"balance":9,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"8250355783"}]}]}"#.utf8)
        let result = try await TronGridClient(http: mock, apiKey: "test-key").balances(address: "test")
        XCTAssertEqual(result, TronBalances(trxBalance: 9, usdtSun: 8_250_355_783))
        XCTAssertEqual(mock.headers, ["TRON-PRO-API-KEY": "test-key"])
    }

    func testAccountNotFoundYieldsZero() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/test"] = Data(#"{"success":true,"data":[]}"#.utf8)
        let result = try await TronGridClient(http: mock).balances(address: "test")
        XCTAssertEqual(result, TronBalances(trxBalance: 0, usdtSun: 0))
        XCTAssertTrue(mock.headers.isEmpty)
    }

    func testMalformedBalancesFailInsteadOfPretendingZero() async {
        let mock = MockHTTP()
        for response in [#"{"success":false,"data":[]}"#, #"{"success":true}"#,
                         #"{"success":true,"data":[{"balance":-1}]}"#,
                         #"{"success":true,"data":[{"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"nope"}]}]}"#] {
            mock.stubs["/v1/accounts/test"] = Data(response.utf8)
            do {
                _ = try await TronGridClient(http: mock).balances(address: "test")
                XCTFail("Must reject malformed response")
            } catch { }
        }
    }

    func testSunConversionOnly() {
        XCTAssertEqual(TronGridClient.parseSun("123.456789"), 123_456_789)
        XCTAssertEqual(TronGridClient.parseSun("0.000001"), 1)
        XCTAssertEqual(TronGridClient.parseSun("1.1"), 1_100_000)
        XCTAssertEqual(TronGridClient.parseSun("9223372036854.775807"), Int64.max)
        for invalid in ["", ".", ".1", "1.", "-1.1", "+1", "1..2", "123.4567 89", "1.1234567", "1e6", "１２", "9223372036854.775808", "9223372036855"] {
            XCTAssertNil(TronGridClient.parseSun(invalid), invalid)
        }
    }

    func testFormattingPreservesIntegerPrecision() {
        XCTAssertEqual(TronGridClient.formatUSDT(8_250_355_783), "8250.355783")
        XCTAssertEqual(TronGridClient.formatUSDT(1), "0.000001")
        XCTAssertEqual(TronGridClient.formatUSDT(Int64.min), "-9223372036854.775808")
    }

    func testBalanceCacheExpiresAtBoundary() {
        let cached = CachedTronBalances(balances: .init(trxBalance: 1, usdtSun: 2), updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(cached.isFresh(at: Date(timeIntervalSince1970: 399), maxAge: 300))
        XCTAssertFalse(cached.isFresh(at: Date(timeIntervalSince1970: 400), maxAge: 300))
        XCTAssertFalse(cached.isFresh(at: Date(timeIntervalSince1970: 99), maxAge: 300))
    }
}
