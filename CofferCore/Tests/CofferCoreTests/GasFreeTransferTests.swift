import XCTest
@testable import CofferCore

final class GasFreeTransferTests: XCTestCase {
    func store() throws -> GasFreeJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try GasFreeJournalStore(directory: directory, owner: GasFreeClientTests.owner)
    }
    func testJournalCASCorruptionAndNoExecutableSecrets() throws {
        let store = try store()
        var journal = GasFreeJournal()
        let permit = GasFreePermit(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver,
            provider: GasFreeClientTests.provider, value: 1000000, maxFee: 2000000, deadline: 2000000000, nonce: 0)
        let record = try GasFreeRecord(permit: permit, signatureDigest: String(repeating: "a", count: 64))
        journal.records.append(record)
        try store.save(journal, replacing: GasFreeJournal())
        XCTAssertTrue(try store.load().blocksNewPayment)
        XCTAssertThrowsError(try store.save(GasFreeJournal(), replacing: GasFreeJournal()))
        let object = try WalletJSON.object(Data(contentsOf: store.fileURL))
        let saved = (object["records"] as! [[String: Any]])[0]
        XCTAssertNil(saved["signature"]); XCTAssertNil(saved["sig"]); XCTAssertNil(saved["secret"])
        try Data("broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }
    func testSubmitTimeoutPersistsAndNeverResends() async throws {
        let (api, chain) = GasFreeClientTests.fixture()
        let service = try GasFreeService(client: GasFreeClientTests.client(api), chain: chain)
        let quote = try await service.quote(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver, value: 1000000)
        let store = try store()
        // An empty successful HTTP response is just as ambiguous as a timeout after acceptance.
        var signingCount = 0
        do {
            _ = try await service.submit(quote, store: store) {
                signingCount += 1
                return Data(repeating: 0, count: 31) + Data([1])
            }
            XCTFail("ambiguous response")
        } catch { XCTAssertEqual(error as? GasFreeError, .pending) }
        let journal = try store.load()
        XCTAssertTrue(journal.blocksNewPayment)
        XCTAssertNil(journal.records.last?.traceID)
        XCTAssertEqual(signingCount, 1)
        do { _ = try await service.submit(quote, store: store) { XCTFail("must not sign"); return Data() }; XCTFail() }
        catch { XCTAssertEqual(error as? GasFreeError, .pending) }
        XCTAssertEqual(api.requests.filter { $0.0 == "/tron/api/v1/gasfree/submit" }.count, 1)
    }
    func testFeeIncreaseStopsBeforeSigningAndPersistence() async throws {
        let (api, chain) = GasFreeClientTests.fixture()
        let service = try GasFreeService(client: GasFreeClientTests.client(api), chain: chain)
        let quote = try await service.quote(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver, value: 1000000)
        api.responses["/tron/api/v1/config/token/all"] = GasFreeClientTests.envelope(["tokens": [[
            "tokenAddress": usdtContract, "supported": true, "decimal": 6, "activateFee": 9000000, "transferFee": 1000000]]])
        let store = try store()
        do { _ = try await service.submit(quote, store: store) { XCTFail("must not sign"); return Data() }; XCTFail() }
        catch { }
        XCTAssertTrue(try store.load().records.isEmpty)
        XCTAssertFalse(api.requests.contains { $0.0.hasSuffix("/submit") })
    }
    func testSubmitBindsPermitAndStoresRealTraceSeparateFromRequestID() async throws {
        let (api, chain) = GasFreeClientTests.fixture()
        let service = try GasFreeService(client: GasFreeClientTests.client(api), chain: chain)
        let quote = try await service.quote(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver, value: 1000000)
        let store = try store()
        let trace = UUID().uuidString
        api.onPost = { path, body in
            guard path.hasSuffix("/submit") else { return nil }
            XCTAssertTrue((try? store.load().blocksNewPayment) == true, "must persist before network")
            XCTAssertEqual(body["maxFee"] as? Int64, 2000000)
            XCTAssertEqual(body["value"] as? Int64, 1000000)
            XCTAssertEqual((body["sig"] as? String)?.count, 130)
            let expiry = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(body["deadline"] as! Int64)))
            return GasFreeClientTests.envelope(["id": trace, "accountAddress": GasFreeClientTests.owner,
                "gasFreeAddress": GasFreeClientTests.address, "targetAddress": GasFreeClientTests.receiver,
                "tokenAddress": usdtContract, "providerAddress": GasFreeClientTests.provider,
                "amount": body["value"]!, "maxFee": body["maxFee"]!, "nonce": body["nonce"]!,
                "signature": body["sig"]!, "expiredAt": expiry, "state": "WAITING"])
        }
        let accepted = try await service.submit(quote, store: store) { Data(repeating: 0, count: 31) + Data([1]) }
        XCTAssertEqual(accepted.traceID, trace)
        XCTAssertNotEqual(accepted.requestID, trace)
        XCTAssertEqual(try store.load().records.last, accepted)
        XCTAssertTrue(try store.load().blocksNewPayment)
        XCTAssertNil(accepted.transactionHash)
    }
    func testUnrelatedTraceCannotReleasePendingRecord() async throws {
        let (api, chain) = GasFreeClientTests.fixture()
        let service = try GasFreeService(client: GasFreeClientTests.client(api), chain: chain)
        let store = try store()
        let permit = GasFreePermit(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver,
            provider: GasFreeClientTests.provider, value: 1000000, maxFee: 2000000, deadline: 2000000000, nonce: 0)
        var journal = GasFreeJournal()
        journal.records.append(try GasFreeRecord(permit: permit, signatureDigest: String(repeating: "a", count: 64)))
        try store.save(journal, replacing: GasFreeJournal())
        let trace = UUID().uuidString
        api.responses["/tron/api/v1/gasfree/" + trace] = GasFreeClientTests.envelope([
            "id": trace, "accountAddress": GasFreeClientTests.receiver, "state": "SUCCEED"])
        do { _ = try await service.refresh(store: store, recoveredTraceID: trace); XCTFail() } catch { }
        XCTAssertEqual(try store.load(), journal)
    }
    func testLostSubmitResponseRecoversOnlyAfterFinalizedExpiryAndUnusedNonce() async throws {
        let (api, chain) = GasFreeClientTests.fixture()
        let service = try GasFreeService(client: GasFreeClientTests.client(api), chain: chain)
        let store = try store()
        let permit = GasFreePermit(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver,
            provider: GasFreeClientTests.provider, value: 1000000, maxFee: 2000000, deadline: 1700000000, nonce: 0)
        var journal = GasFreeJournal()
        journal.records.append(try GasFreeRecord(permit: permit, signatureDigest: String(repeating: "a", count: 64)))
        try store.save(journal, replacing: GasFreeJournal())
        chain.responses["/walletsolidity/getnowblock"] = ["block_header": ["raw_data": ["timestamp": Int64(1700000060001)]]]
        chain.responses["/walletsolidity/triggerconstantcontract"] = ["result": ["result": true],
            "constant_result": [GasFreeCrypto.hex(GasFreeCrypto.word(1))]]
        _ = try? await service.refresh(store: store)
        XCTAssertTrue(try store.load().blocksNewPayment, "consumed nonce requires transaction recovery")
        chain.responses["/walletsolidity/triggerconstantcontract"] = ["result": ["result": true],
            "constant_result": [GasFreeCrypto.hex(GasFreeCrypto.word(0))]]
        chain.responses["/walletsolidity/getnowblock"] = ["block_header": ["raw_data": ["timestamp": Int64(1700000060000)]]]
        _ = try? await service.refresh(store: store)
        XCTAssertTrue(try store.load().blocksNewPayment, "must exceed finalized expiry margin")
        chain.responses["/walletsolidity/getnowblock"] = ["block_header": ["raw_data": ["timestamp": Int64(1700000060001)]]]
        let record = try await service.refresh(store: store)
        XCTAssertEqual(record?.state, "EXPIRED_UNUSED")
        XCTAssertFalse(try store.load().blocksNewPayment)
        XCTAssertFalse(api.requests.contains { $0.0.hasSuffix("/submit") })
        let nonceRequest = try XCTUnwrap(chain.requests.last)
        XCTAssertEqual(nonceRequest.1["contract_address"] as? String, GasFreeCrypto.controller)
        XCTAssertEqual(nonceRequest.1["function_selector"] as? String, "nonces(address)")
    }
}
