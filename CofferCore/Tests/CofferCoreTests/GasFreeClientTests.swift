import XCTest
@testable import CofferCore

final class GasFreeMockHTTP: HTTPProviding {
    var responses: [String: [String: Any]] = [:]
    var requests: [(String, [String: Any], [String: String])] = []
    var failure: Error?
    var onPost: ((String, [String: Any]) -> [String: Any]?)?
    func get(_ path: String, headers: [String: String]) async throws -> Data {
        requests.append((path, [:], headers))
        if let failure { throw failure }
        return try JSONSerialization.data(withJSONObject: responses[path] ?? [:])
    }
    func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> Data {
        requests.append((path, body, headers))
        if let failure { throw failure }
        return try JSONSerialization.data(withJSONObject: onPost?(path, body) ?? responses[path] ?? [:])
    }
}

final class GasFreeClientTests: XCTestCase {
    static let owner = "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
    static let address = "TBwmA2PtMXC4HiGvfi8xg2jZd5i3y89DjK"
    static let provider = "TDbJyQ6g1Lx9BAfEEeN5S5TMjjDRAVFCaA"
    static let receiver = "TJM1BE5wq1VdHh3gwjUeyaVkvZp9DVYCfC"
    static func envelope(_ data: [String: Any]) -> [String: Any] { ["code": 200, "data": data] }
    static func fixture() -> (GasFreeMockHTTP, GasFreeMockHTTP) {
        let api = GasFreeMockHTTP(), chain = GasFreeMockHTTP()
        api.responses["/tron/api/v1/config/token/all"] = envelope(["tokens": [[
            "tokenAddress": usdtContract, "supported": true, "decimal": 6, "symbol": "USDT",
            "activateFee": 1000000, "transferFee": 1000000]]])
        api.responses["/tron/api/v1/config/provider/all"] = envelope(["providers": [[
            "address": provider, "name": "Official", "config": ["maxPendingTransfer": 1,
                "minDeadlineDuration": 60, "maxDeadlineDuration": 600, "defaultDeadlineDuration": 180]]]])
        api.responses["/tron/api/v1/address/" + owner] = envelope([
            "accountAddress": owner, "gasFreeAddress": address, "active": false, "nonce": 0,
            "allow_submit": true, "assets": [["tokenAddress": usdtContract, "decimal": 6,
                "activateFee": 1000000, "transferFee": 1000000, "frozen": 500000]]])
        chain.responses["/v1/accounts/" + address] = ["success": true, "data": []]
        chain.responses["/wallet/triggerconstantcontract"] = ["result": ["result": true],
            "constant_result": [GasFreeCrypto.hex(GasFreeCrypto.word(10000000))]]
        return (api, chain)
    }
    static func client(_ api: GasFreeMockHTTP) throws -> GasFreeClient {
        try GasFreeClient(credentials: GasFreeCredentials(key: "key", secret: "secret"), http: api,
                          now: { Date(timeIntervalSince1970: 1731912286) })
    }
    func testHMACIncludesMainnetPrefix() async throws {
        let (api, _) = Self.fixture()
        try await Self.client(api).verifyCredentials()
        let headers = try XCTUnwrap(api.requests.first?.2)
        XCTAssertEqual(headers["Timestamp"], "1731912286")
        XCTAssertEqual(headers["Authorization"], "ApiKey key:60S0XZPDW0ImrgERpdMPWWmsMlUe+xvunSIT0ln3d2I=")
        XCTAssertThrowsError(try GasFreeCredentials(key: " ", secret: "secret"))
    }
    func testQuoteUsesIndependentBalanceAndActivationFee() async throws {
        let (api, chain) = Self.fixture()
        let quote = try await GasFreeService(client: Self.client(api), chain: chain)
            .quote(owner: Self.owner, receiver: Self.receiver, value: 1000000)
        XCTAssertEqual(quote.snapshot.address, Self.address)
        XCTAssertEqual(quote.snapshot.available, 9500000)
        XCTAssertEqual(quote.snapshot.activationFee, 1000000)
        XCTAssertEqual(quote.maxFee, 2000000)
        XCTAssertEqual(quote.total, 3000000)
        XCTAssertFalse(chain.requests.contains { $0.0.contains(Self.owner) })
    }
    func testRejectWrongAddressBusinessErrorAndConflictingAllowSubmit() async throws {
        let (api, _) = Self.fixture()
        let path = "/tron/api/v1/address/" + Self.owner
        let original = api.responses[path]!
        for change: [String: Any] in [["gasFreeAddress": Self.owner], ["allowSubmit": false],
                                      ["nonce": -1], ["active": 1]] {
            var data = original["data"] as! [String: Any]
            for (key, value) in change { data[key] = value }
            api.responses[path] = Self.envelope(data)
            do { _ = try await Self.client(api).account(owner: Self.owner); XCTFail("invalid account") } catch { }
        }
        api.responses[path] = ["code": 400, "data": original["data"]!]
        do { _ = try await Self.client(api).account(owner: Self.owner); XCTFail("business error") } catch { }
    }
    func testFrozenFundsAndPendingBlockQuotes() async throws {
        let (api, chain) = Self.fixture()
        let service = try GasFreeService(client: Self.client(api), chain: chain)
        do { _ = try await service.quote(owner: Self.owner, receiver: Self.receiver, value: 8000000); XCTFail() }
        catch { XCTAssertEqual(error as? GasFreeError, .insufficientBalance) }
        var account = api.responses["/tron/api/v1/address/" + Self.owner]!["data"] as! [String: Any]
        account["allow_submit"] = false
        api.responses["/tron/api/v1/address/" + Self.owner] = Self.envelope(account)
        do { _ = try await service.quote(owner: Self.owner, receiver: Self.receiver, value: 1); XCTFail() }
        catch { XCTAssertEqual(error as? GasFreeError, .unavailable) }
    }
}
