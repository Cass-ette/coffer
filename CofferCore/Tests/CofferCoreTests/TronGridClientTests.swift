import XCTest
@testable import CofferCore

final class TronGridClientTests: XCTestCase {
    static let address = "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"

    final class MockHTTP: HTTPProviding {
        var stubs: [String: Data] = [:]
        var headers: [String: String] = [:]
        var posted: [(path: String, body: [String: Any])] = []
        func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> Data {
            self.headers = headers
            posted.append((path, body))
            return stubs[path] ?? Data()
        }
        func get(_ path: String, headers: [String: String]) async throws -> Data {
            self.headers = headers
            return stubs[path] ?? Data()
        }
    }

    private func stubUSDT(_ mock: MockHTTP, sun: Int64) {
        let hex = String(sun, radix: 16)
        mock.stubs["/wallet/triggerconstantcontract"] = Data("""
        {"result":{"result":true},"constant_result":["\(String(repeating: "0", count: 64 - hex.count))\(hex)"]}
        """.utf8)
    }

    func testParseBalances() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/\(Self.address)"] = Data(#"{"success":true,"data":[{"balance":9,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"8250355783"}]}]}"#.utf8)
        stubUSDT(mock, sun: 8_250_355_783)
        let result = try await TronGridClient(http: mock, apiKey: "test-key").balances(address: Self.address)
        XCTAssertEqual(result, TronBalances(trxBalance: 9, usdtSun: 8_250_355_783))
        XCTAssertEqual(mock.headers, ["TRON-PRO-API-KEY": "test-key"])
    }

    func testAccountNotFoundYieldsZero() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/\(Self.address)"] = Data(#"{"success":true,"data":[]}"#.utf8)
        stubUSDT(mock, sun: 0)
        let result = try await TronGridClient(http: mock).balances(address: Self.address)
        XCTAssertEqual(result, TronBalances(trxBalance: 0, usdtSun: 0))
        XCTAssertTrue(mock.headers.isEmpty)
    }

    func testMalformedBalancesFailInsteadOfPretendingZero() async {
        let mock = MockHTTP()
        stubUSDT(mock, sun: 0)
        for response in [#"{"success":false,"data":[]}"#, #"{"success":true}"#,
                         #"{"success":true,"data":[{"balance":-1}]}"#,
                         #"{"success":true,"data":[{"balance":"nope"}]}"#] {
            mock.stubs["/v1/accounts/\(Self.address)"] = Data(response.utf8)
            do {
                _ = try await TronGridClient(http: mock).balances(address: Self.address)
                XCTFail("Must reject malformed response")
            } catch { }
        }
    }

    func testUnactivatedAccountCanAlreadyHoldUSDT() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/\(Self.address)"] = Data(#"{"success":true,"data":[]}"#.utf8)
        stubUSDT(mock, sun: 3_500_000)
        let result = try await TronGridClient(http: mock, apiKey: "test-key").balances(address: Self.address)
        XCTAssertEqual(result, TronBalances(trxBalance: 0, usdtSun: 3_500_000))
        let query = try XCTUnwrap(mock.posted.first)
        XCTAssertEqual(query.path, "/wallet/triggerconstantcontract")
        XCTAssertEqual(query.body["contract_address"] as? String, usdtContract)
        XCTAssertEqual(query.body["function_selector"] as? String, "balanceOf(address)")
        XCTAssertEqual(query.body["owner_address"] as? String, Self.address)
        XCTAssertEqual(query.body["visible"] as? Bool, true)
        XCTAssertEqual(query.body["parameter"] as? String,
                       "000000000000000000000000c8599111f29c1e1e061265b4af93ea1f274ad78a")
        XCTAssertEqual(mock.headers["TRON-PRO-API-KEY"], "test-key")
    }

    func testContractBalanceOverridesStaleAccountIndex() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/\(Self.address)"] = Data(#"{"success":true,"data":[{"balance":9,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"0"}]}]}"#.utf8)
        stubUSDT(mock, sun: 3_500_000)
        let result = try await TronGridClient(http: mock).balances(address: Self.address)
        XCTAssertEqual(result, TronBalances(trxBalance: 9, usdtSun: 3_500_000))
    }

    func testInvalidContractResponseNeverPretendsZero() async {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/\(Self.address)"] = Data(#"{"success":true,"data":[]}"#.utf8)
        let zero = String(repeating: "0", count: 64)
        for response in [
            #"{}"#,
            #"{"result":{"result":true},"constant_result":[]}"#,
            "{\"result\":{\"result\":false},\"constant_result\":[\"\(zero)\"]}",
            "{\"result\":{\"result\":true},\"constant_result\":[\"\(zero)\",\"\(zero)\"]}",
            #"{"result":{"result":true},"constant_result":["nope"]}"#,
            #"{"result":{"result":true},"constant_result":["0000000000000000000000000000000000000000000000008000000000000000"]}"#
        ] {
            mock.stubs["/wallet/triggerconstantcontract"] = Data(response.utf8)
            do {
                _ = try await TronGridClient(http: mock).balances(address: Self.address)
                XCTFail("Must preserve query failure instead of reporting zero USDT")
            } catch { }
        }
    }

    func testContractBalancePreservesIntegerPrecision() async throws {
        let mock = MockHTTP()
        mock.stubs["/v1/accounts/\(Self.address)"] = Data(#"{"success":true,"data":[]}"#.utf8)
        stubUSDT(mock, sun: Int64.max)
        let result = try await TronGridClient(http: mock).balances(address: Self.address)
        XCTAssertEqual(result.usdtSun, Int64.max)
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
