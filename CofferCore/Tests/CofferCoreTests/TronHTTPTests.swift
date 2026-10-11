import XCTest
@testable import CofferCore

final class TronHTTPTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        struct Reply {
            let status: Int
            var headers: [String: String] = [:]
            var body = Data("{}".utf8)
        }
        private static let lock = NSLock()
        private static var replies: [Reply] = []
        private static var requests: [URLRequest] = []
        private static var times: [TimeInterval] = []
        static func prepare(_ values: [Reply]) {
            lock.lock(); defer { lock.unlock() }
            replies = values; requests = []; times = []
        }
        static var recorded: ([URLRequest], [TimeInterval]) {
            lock.lock(); defer { lock.unlock() }
            return (requests, times)
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            Self.requests.append(request)
            Self.times.append(ProcessInfo.processInfo.systemUptime)
            let reply = Self.replies.isEmpty ? Reply(status: 500) : Self.replies.removeFirst()
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
    private func coordinator(spacing: TimeInterval = 0) -> TronGridRequestCoordinator {
        TronGridRequestCoordinator(minimumInterval: spacing, keyedInterval: spacing,
                                   initialCooldown: 0.025, repeatedCooldown: 0.1, maximumAutomaticWait: 0.1)
    }

    func testReadOnly429WaitsThenRetriesSameRequestOnce() async throws {
        StubProtocol.prepare([.init(status: 429), .init(status: 200, body: Data("{\"ok\":true}".utf8))])
        let session = session(); defer { session.invalidateAndCancel() }
        let http = URLSessionHTTP(session: session, coordinator: coordinator())
        let result = try await http.post("/wallet/getaccountresource", body: ["address": "public-address"], headers: [:])
        XCTAssertEqual(result, Data("{\"ok\":true}".utf8))
        let (requests, times) = StubProtocol.recorded
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.02)
    }

    func testRepeated429StopsInsteadOfRetryingForever() async throws {
        StubProtocol.prepare([.init(status: 429), .init(status: 429), .init(status: 200)])
        let session = session(); defer { session.invalidateAndCancel() }
        let http = URLSessionHTTP(session: session, coordinator: coordinator())
        do {
            _ = try await http.get("/v1/accounts/public-address", headers: [:])
            XCTFail("A second 429 must return a cooldown to the user")
        } catch { XCTAssertTrue(error.localizedDescription.contains("秒")) }
        XCTAssertEqual(StubProtocol.recorded.0.count, 2)
    }

    func testLongRetryAfterStopsWithoutSendingAnEarlyRetry() async throws {
        StubProtocol.prepare([.init(status: 429, headers: ["Retry-After": "60"]), .init(status: 200)])
        let session = session(); defer { session.invalidateAndCancel() }
        let http = URLSessionHTTP(session: session, coordinator: coordinator())
        do {
            _ = try await http.post("/wallet/triggerconstantcontract", body: [:], headers: [:])
            XCTFail("Do not retry early or hide a long wait")
        } catch { XCTAssertTrue(error.localizedDescription.contains("60")) }
        XCTAssertEqual(StubProtocol.recorded.0.count, 1)
    }

    func testIndependentClientsShareRequestPacing() async throws {
        StubProtocol.prepare([.init(status: 200), .init(status: 200)])
        let session = session(); defer { session.invalidateAndCancel() }
        let gate = coordinator(spacing: 0.035)
        let first = URLSessionHTTP(session: session, coordinator: gate)
        let second = URLSessionHTTP(session: session, coordinator: gate)
        async let a = first.post("/wallet/getaccountresource", body: [:], headers: [:])
        async let b = second.post("/wallet/getchainparameters", body: [:], headers: [:])
        _ = try await (a, b)
        let times = StubProtocol.recorded.1
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.03)
    }

    func testBroadcastAndRentalPaymentAreNeverAutomaticallyRetried() async throws {
        for (base, path) in [("https://api.trongrid.io", "/wallet/broadcasttransaction"),
                             ("https://api.tronsave.io", "/v2/buy-resource")] {
            StubProtocol.prepare([.init(status: 429), .init(status: 200)])
            let session = session(); defer { session.invalidateAndCancel() }
            let http = URLSessionHTTP(base: URL(string: base)!, session: session, coordinator: coordinator())
            do {
                _ = try await http.post(path, body: ["signature": ["test-signature"]], headers: [:])
                XCTFail("Signed submission must not be retried by HTTP")
            } catch { }
            XCTAssertEqual(StubProtocol.recorded.0.count, 1)
        }
    }

    func testCancellationDuringCooldownNeverMakesAnotherRequest() async throws {
        StubProtocol.prepare([.init(status: 429), .init(status: 200)])
        let session = session(); defer { session.invalidateAndCancel() }
        let gate = TronGridRequestCoordinator(minimumInterval: 0, keyedInterval: 0,
            initialCooldown: 0.3, repeatedCooldown: 1, maximumAutomaticWait: 1)
        let http = URLSessionHTTP(session: session, coordinator: gate)
        let task = Task { try await http.post("/wallet/getaccountresource", body: [:], headers: [:]) }
        for _ in 0..<100 {
            if !StubProtocol.recorded.0.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled query must stop") }
        catch { }
        XCTAssertEqual(StubProtocol.recorded.0.count, 1)
    }

    func testValidChainParametersAreCachedButBalanceAndResourcesStayFresh() async throws {
        let parameters = Data(#"{"chainParameter":[{"key":"getTransactionFee","value":1000},{"key":"getEnergyFee","value":100}]}"#.utf8)
        StubProtocol.prepare([.init(status: 200, body: parameters)] + Array(repeating: .init(status: 200), count: 6))
        let session = session(); defer { session.invalidateAndCancel() }
        let gate = coordinator()
        let first = URLSessionHTTP(session: session, coordinator: gate)
        let second = URLSessionHTTP(session: session, coordinator: gate)
        let a = try await first.post("/wallet/getchainparameters", body: [:], headers: [:])
        let b = try await second.post("/wallet/getchainparameters", body: [:], headers: [:])
        XCTAssertEqual(a, parameters)
        XCTAssertEqual(b, parameters)
        _ = try await first.post("/wallet/getaccountresource", body: [:], headers: [:])
        _ = try await second.post("/wallet/getaccountresource", body: [:], headers: [:])
        _ = try await first.get("/v1/accounts/public-address", headers: [:])
        _ = try await second.get("/v1/accounts/public-address", headers: [:])
        _ = try await first.post("/wallet/triggerconstantcontract", body: [:], headers: [:])
        _ = try await second.post("/wallet/triggerconstantcontract", body: [:], headers: [:])
        XCTAssertEqual(StubProtocol.recorded.0.count, 7)
    }

    func testMalformedChainParametersAreNeverCached() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let http = URLSessionHTTP(session: session, coordinator: coordinator())
        for invalid in ["{}", #"{"chainParameter":[{"key":"getTransactionFee","value":1000},{"key":"getEnergyFee","value":true}]}"#,
                        #"{"chainParameter":[{"key":"getTransactionFee","value":0},{"key":"getEnergyFee","value":100}]}"#] {
            StubProtocol.prepare([.init(status: 200, body: Data(invalid.utf8)), .init(status: 200)])
            _ = try await http.post("/wallet/getchainparameters", body: [:], headers: [:])
            _ = try await http.post("/wallet/getchainparameters", body: [:], headers: [:])
            XCTAssertEqual(StubProtocol.recorded.0.count, 2)
        }
    }

    func testChainParameterCacheExpiresAndExplicitRefreshBypassesIt() async throws {
        let first = Data(#"{"chainParameter":[{"key":"getTransactionFee","value":1000},{"key":"getEnergyFee","value":100}]}"#.utf8)
        let changed = Data(#"{"chainParameter":[{"key":"getTransactionFee","value":1000},{"key":"getEnergyFee","value":200}]}"#.utf8)
        StubProtocol.prepare([.init(status: 200, body: first), .init(status: 200, body: changed), .init(status: 200, body: first)])
        let session = session(); defer { session.invalidateAndCancel() }
        let gate = TronGridRequestCoordinator(minimumInterval: 0, keyedInterval: 0, chainParametersTTL: 0.025)
        let http = URLSessionHTTP(session: session, coordinator: gate)
        _ = try await http.post("/wallet/getchainparameters", body: [:], headers: [:])
        let fresh = try await http.post("/wallet/getchainparameters", body: [:], headers: ["Cache-Control": "no-cache"])
        XCTAssertEqual(fresh, changed)
        try await Task.sleep(for: .milliseconds(35))
        let expired = try await http.post("/wallet/getchainparameters", body: [:], headers: [:])
        XCTAssertEqual(expired, first)
        XCTAssertEqual(StubProtocol.recorded.0.count, 3)
    }

    func testHTTPDateCooldownIsSharedWithOtherClients() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: Date().addingTimeInterval(3600))
        StubProtocol.prepare([.init(status: 429, headers: ["Retry-After": header]), .init(status: 200)])
        let session = session(); defer { session.invalidateAndCancel() }
        let gate = coordinator()
        for http in [URLSessionHTTP(session: session, coordinator: gate), URLSessionHTTP(session: session, coordinator: gate)] {
            do {
                _ = try await http.post("/wallet/getaccountresource", body: [:], headers: [:])
                XCTFail("All clients must respect the provider's cooldown")
            } catch TronGridError.rateLimited(let seconds) { XCTAssertGreaterThan(seconds, 3500) }
        }
        XCTAssertEqual(StubProtocol.recorded.0.count, 1)
    }
}
