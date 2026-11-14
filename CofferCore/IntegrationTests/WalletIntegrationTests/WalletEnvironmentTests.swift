import XCTest
import CryptoKit
import TronKit
import HsCryptoKit
@testable import CofferCore

/// Uses a separate, stateful HTTP process. No URLProtocol or HTTPProviding stub.
@MainActor
final class WalletEnvironmentTests: XCTestCase {
    private func environment(_ scenario: String) async throws -> WalletLab {
        let lab = try await WalletLab.start(scenario: scenario)
        addTeardownBlock { await MainActor.run { lab.stop() } }
        return lab
    }

    func testUSDTZeroReturnStillTransfersAndReconcilesRealFees() async throws {
        let lab = try await environment("direct-usdt-zero-return")
        let quote = try await lab.quote()
        XCTAssertEqual(quote.fee.energy, 64_285)
        XCTAssertEqual(quote.fee.feeSun, 6_428_500)
        let before = try await lab.balances()
        let receipt = try await lab.send(quote)
        let result = try await lab.receipt(receipt.txHash)
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThanOrEqual(result.feeSun, quote.fee.maximumFeeSun)
        let after = try await lab.balances()
        XCTAssertEqual(after.usdtSun, before.usdtSun - WalletLab.amount)
        XCTAssertEqual(after.trxBalance, before.trxBalance - result.feeSun)
        try lab.settle(result)
        XCTAssertEqual(try lab.store().load().actualTotalSun, result.feeSun)
        let state = try await lab.state()
        XCTAssertEqual(state["committed_transactions"] as? Int, 1)
        XCTAssertEqual(lab.requestCount("/wallet/broadcasttransaction", state), 1)
        XCTAssertEqual(try lab.recipientBalance(state), 10_000_000 + WalletLab.amount)
    }

    func testMnemonicSliceRentalWaitsForEnergyBeforeTransferring() async throws {
        let lab = try await environment("key-slice-rental")
        XCTAssertGreaterThan(lab.key.startIndex, 0, "Reproduce the actual mnemonic Data slice")
        try await lab.completeRental(expectLostResponse: false)
    }

    func testRentalAcceptedWithLostResponseSurvivesRestartWithoutRebuying() async throws {
        let lab = try await environment("rental-response-lost")
        try await lab.completeRental(expectLostResponse: true)
    }

    func testFractionalSUNRentalQuoteUsesObservedTruncation() async throws {
        let lab = try await environment("fractional-rental-price")
        let direct = try await lab.quote()
        XCTAssertEqual(direct.fee.energy, 130_285)
        let rental = try await lab.rental.quote(address: lab.owner, energy: direct.fee.energyBurned)
        XCTAssertEqual(rental.unitPrice, Decimal(string: "67.25"))
        XCTAssertEqual(rental.rentSun, 8_761_666)
        let plan = try TronRentalPlan(quote: rental, directFee: direct.fee)
        XCTAssertGreaterThan(plan.savingsSun, 0)
    }

    func testUnactivatedAccountHasUSDTDespiteEmptyNativeIndex() async throws {
        let lab = try await environment("unactivated-usdt")
        let indexed = try WalletJSON.object(await lab.raw.get("/v1/accounts/" + lab.owner, headers: [:]))
        XCTAssertEqual((indexed["data"] as? [Any])?.count, 0)
        let balance = try await lab.balances()
        XCTAssertEqual(balance.trxBalance, 0)
        XCTAssertEqual(balance.usdtSun, 3_500_000)
    }

    func testRealHTTP429HonorsRetryAfterAndRetriesQueryOnce() async throws {
        let lab = try await environment("trongrid-429")
        let resources = try await lab.chain.resources(address: lab.owner)
        XCTAssertEqual(resources.energy, 0)
        let state = try await lab.state()
        let requests = try XCTUnwrap(state["requests"] as? [[String: Any]])
            .filter { $0["path"] as? String == "/wallet/getaccountresource" }
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first?["time"] as? Double)
        let second = try XCTUnwrap(requests.last?["time"] as? Double)
        XCTAssertGreaterThanOrEqual(second - first, 0.95)
    }

    func testAnonymousQuotaStopsRetryingAndAPIKeyHasSeparateQuota() async throws {
        let lab = try await environment("direct-usdt-zero-return")
        _ = try await lab.admin("configure", ["rate_limits": [
            "anonymous": ["capacity": 1, "refill_per_second": 0],
            "keyed": ["capacity": 10, "refill_per_second": 0]]])
        _ = try await lab.chain.resources(address: lab.owner)
        do {
            _ = try await lab.chain.resources(address: lab.owner)
            XCTFail("Repeated 429 must stop")
        } catch {
            guard case .rateLimited? = error as? TronGridError else { return XCTFail("Unexpected error: \(error)") }
        }
        let keyed = TronTransferService(http: lab.http, apiKey: "public-integration-test-key")
        _ = try await keyed.resources(address: lab.owner)
        let state = try await lab.state()
        XCTAssertEqual(lab.requestCount("/wallet/getaccountresource", state), 4)
    }

    func testLostBroadcastResponseRestoresHashAndQueriesDelayedReceipt() async throws {
        let lab = try await environment("broadcast-response-lost")
        let quote = try await lab.quote()
        var hash: String?
        do {
            _ = try await lab.send(quote)
            XCTFail("An incomplete acknowledgment must be uncertain")
        } catch BroadcastError.uncertain(let value) { hash = value }
        let persisted = try lab.store().load()
        XCTAssertTrue(persisted.blocksNewPayment)
        XCTAssertEqual(persisted.transfer?.hash, hash)
        let pending = try await lab.chain.executionReceipt(hash: XCTUnwrap(hash))
        XCTAssertNil(pending)
        _ = try await lab.admin("advance", ["blocks": 2])
        let result = try await lab.receipt(XCTUnwrap(hash))
        XCTAssertTrue(result.succeeded)
        try lab.settle(result)
        XCTAssertFalse(try lab.store().load().blocksNewPayment)
        let state = try await lab.state()
        XCTAssertEqual(lab.requestCount("/wallet/broadcasttransaction", state), 1)
        XCTAssertEqual(state["committed_transactions"] as? Int, 1)
        let balance = try await lab.balances()
        XCTAssertEqual(balance.usdtSun, 1_950_000)
    }

    func testDynamicEnergyRequoteAndOldBudgetFailureChargeOnlyFees() async throws {
        let lab = try await environment("dynamic-energy")
        let old = try await lab.quote()
        _ = try await lab.admin("advance", ["blocks": 1])
        let updated = try await lab.quote()
        XCTAssertEqual(updated.fee.energy, 96_428)
        XCTAssertGreaterThan(updated.fee.maximumFeeSun, old.fee.maximumFeeSun)
        // Deliberately exercise an obsolete budget; the production screen must
        // re-confirm changed quotes before sending. No real money is involved.
        let sent = try await lab.send(old)
        let result = try await lab.receipt(sent.txHash)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.result, "OUT_OF_ENERGY")
        XCTAssertGreaterThan(result.feeSun, 0)
        let balance = try await lab.balances()
        XCTAssertEqual(balance.usdtSun, 3_500_000)
        XCTAssertEqual(balance.trxBalance, 18_500_000 - result.feeSun)
        try lab.settle(result)
        XCTAssertFalse(try lab.store().load().blocksNewPayment)
    }

    func testVMRevertCannotBecomeSuccessfulQuote() async throws {
        let lab = try await environment("usdt-revert")
        do {
            _ = try await lab.quote()
            XCTFail("RPC success cannot override VM REVERT")
        } catch { XCTAssertEqual(error as? TransferSimulationError, .failed) }
        let state = try await lab.state()
        XCTAssertEqual(lab.requestCount("/wallet/triggersmartcontract", state), 0)
        XCTAssertEqual(state["committed_transactions"] as? Int, 0)
    }

    func testSignedSubmission429NeverRetriesAndExpiresOnlyAfterChainProof() async throws {
        let lab = try await environment("direct-usdt-zero-return")
        _ = try await lab.admin("configure", ["faults": [["path": "/wallet/broadcasttransaction",
            "attempts": [1], "status": 429, "headers": ["Retry-After": "1"]]]])
        let quote = try await lab.quote()
        do { _ = try await lab.send(quote); XCTFail("Broadcast is uncertain") }
        catch BroadcastError.uncertain { }
        let record = try XCTUnwrap(lab.store().load().transfer)
        XCTAssertTrue(try lab.store().load().blocksNewPayment)
        let state = try await lab.state()
        XCTAssertEqual(lab.requestCount("/wallet/broadcasttransaction", state), 1)
        XCTAssertEqual(state["committed_transactions"] as? Int, 0)
        let early = try await lab.chain.isExpiredUnconfirmed(hash: record.hash, expiration: record.expiration)
        XCTAssertFalse(early)
        _ = try await lab.admin("advance", ["seconds": 181])
        let expired = try await lab.chain.isExpiredUnconfirmed(hash: record.hash, expiration: record.expiration)
        XCTAssertTrue(expired)
    }

    func testEnvironmentVerifiesSignatureAndRejectsDuplicatePayment() async throws {
        let lab = try await environment("direct-usdt-zero-return")
        let payment = try await lab.chain.signRentalPayment(from: lab.owner, amountSun: 4_323_166, signingKey: { lab.key })
        var transaction = try WalletJSON.object(payment.payload)
        var signature = try XCTUnwrap((transaction["signature"] as? [String])?.first)
        signature.replaceSubrange(signature.startIndex...signature.startIndex, with: signature.first == "0" ? "1" : "0")
        transaction["signature"] = [signature]
        let rejected = try WalletJSON.object(await lab.raw.post("/wallet/broadcasttransaction", body: transaction, headers: [:]))
        XCTAssertEqual(rejected["code"] as? String, "SIGERROR")
        let signed = try WalletJSON.object(payment.payload)
        let accepted = try WalletJSON.object(await lab.raw.post("/wallet/broadcasttransaction", body: signed, headers: [:]))
        XCTAssertEqual(accepted["result"] as? Bool, true)
        let duplicate = try WalletJSON.object(await lab.raw.post("/wallet/broadcasttransaction", body: signed, headers: [:]))
        XCTAssertEqual(duplicate["code"] as? String, "DUP_TRANSACTION_ERROR")
        let state = try await lab.state()
        XCTAssertEqual(state["committed_transactions"] as? Int, 1)
        let balance = try await lab.balances()
        XCTAssertEqual(balance.trxBalance, 18_500_000 - 4_323_166)
    }

    func testInsufficientRentalFundsCannotChangeBalancesOrResources() async throws {
        let lab = try await environment("direct-usdt-zero-return")
        let initial = try await lab.state()
        var accounts = try XCTUnwrap(initial["accounts"] as? [[String: Any]])
        let index = try XCTUnwrap(accounts.firstIndex { $0["address"] as? String == lab.owner })
        accounts[index]["trx"] = 1
        _ = try await lab.admin("reset", ["scenario": "direct-usdt-zero-return.json", "accounts": accounts])
        let payment = try await lab.chain.signRentalPayment(from: lab.owner, amountSun: 4_323_166, signingKey: { lab.key })
        let body = try WalletJSON.object(payment.payload)
        let rejected = try WalletJSON.object(await lab.raw.post("/wallet/broadcasttransaction", body: body, headers: [:]))
        XCTAssertEqual(rejected["code"] as? String, "CONTRACT_VALIDATE_ERROR")
        let balance = try await lab.balances()
        let resources = try await lab.chain.resources(address: lab.owner)
        XCTAssertEqual(balance.trxBalance, 1)
        XCTAssertEqual(balance.usdtSun, 3_500_000)
        XCTAssertEqual(resources.freeBandwidth, 600)
        let final = try await lab.state()
        XCTAssertEqual(final["committed_transactions"] as? Int, 0)
    }

    func testRentalPriceIncreaseCannotChargeAboveSignedQuote() async throws {
        let lab = try await environment("direct-usdt-zero-return")
        let quote = try await lab.rental.quote(address: lab.owner, energy: 64_285)
        let payment = try await lab.chain.signRentalPayment(from: lab.owner, amountSun: quote.rentSun, signingKey: { lab.key })
        _ = try await lab.admin("configure", ["rental_unit_price": 68])
        do { _ = try await lab.rental.buy(quote: quote, payment: payment); XCTFail("Changed price must not charge") }
        catch RentalError.uncertain(let hash) { XCTAssertEqual(hash, payment.txHash) }
        let balance = try await lab.balances()
        XCTAssertEqual(balance.trxBalance, 18_500_000)
        let final = try await lab.state()
        XCTAssertEqual((final["orders"] as? [Any])?.count, 0)
        XCTAssertEqual(final["committed_transactions"] as? Int, 0)
    }
}

@MainActor
private final class WalletLab {
    static let amount: Int64 = 1_550_000
    let key: Data
    let owner: String
    let recipient: String
    let process: Process
    let directory: URL
    let session: URLSession
    let raw: URLSessionHTTP
    let http: URLSessionHTTP
    let chain: TronTransferService
    let rental: TronSaveClient
    private let errorHandle: FileHandle

    private init(process: Process, directory: URL, base: URL, errorHandle: FileHandle) throws {
        self.process = process; self.directory = directory; self.errorHandle = errorHandle
        key = try TronWalletService().privateKeyData(fromMnemonic:
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        owner = try Signer.address(privateKey: key).base58
        recipient = try Signer.address(privateKey: Data(repeating: 0, count: 31) + Data([1])).base58
        session = URLSession(configuration: .ephemeral)
        raw = URLSessionHTTP(base: base, session: session)
        let gate = TronGridRequestCoordinator(minimumInterval: 0, keyedInterval: 0, initialCooldown: 0.02,
                                             repeatedCooldown: 1, maximumAutomaticWait: 2)
        http = URLSessionHTTP(base: base, session: session, coordinator: gate, usesTronGridPolicy: true)
        chain = TronTransferService(http: http)
        rental = TronSaveClient(http: raw)
    }

    static func start(scenario: String) async throws -> WalletLab {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coffer-wallet-lab-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let errors = directory.appendingPathComponent("server.log")
        _ = FileManager.default.createFile(atPath: errors.path, contents: Data())
        let handle = try FileHandle(forWritingTo: errors)
        let ready = directory.appendingPathComponent("ready.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", root.appendingPathComponent("integration/wallet/simulator.py").path,
                             "--scenario", scenario + ".json", "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = handle
        do {
            try process.run()
            for _ in 0..<250 {
                if FileManager.default.fileExists(atPath: ready.path) { break }
                guard process.isRunning else { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard process.isRunning, let data = try? Data(contentsOf: ready),
                  let object = try? WalletJSON.object(data), let url = object["base_url"] as? String,
                  let base = URL(string: url), base.host == "127.0.0.1" else {
                throw NSError(domain: "WalletLab", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Simulator did not start: " + ((try? String(contentsOf: errors, encoding: .utf8)) ?? "unknown error")])
            }
            let lab = try WalletLab(process: process, directory: directory, base: base, errorHandle: handle)
            let recipientKey = Data(repeating: 0, count: 31) + Data([1])
            let accounts: [[String: Any]] = [
                ["hex": TronTransferService.hex41(lab.owner)!, "public_key": hex(Crypto.publicKey(privateKey: lab.key, compressed: false))],
                ["hex": TronTransferService.hex41(lab.recipient)!, "public_key": hex(Crypto.publicKey(privateKey: recipientKey, compressed: false)),
                 "trx": 0, "usdt": 10_000_000]]
            _ = try await lab.admin("reset", ["scenario": scenario + ".json", "accounts": accounts])
            return lab
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? handle.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() {
        session.invalidateAndCancel()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? errorHandle.close()
        try? FileManager.default.removeItem(at: directory)
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    func admin(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        try WalletJSON.object(await raw.post("/__admin/" + action, body: body, headers: [:]))
    }
    func state() async throws -> [String: Any] {
        try WalletJSON.object(await raw.get("/__admin/state", headers: [:]))
    }
    func quote() async throws -> TronTransferQuote {
        try await chain.quote(from: owner, to: recipient, usdtSun: Self.amount, refreshFeeParameters: true)
    }
    func balances() async throws -> TronBalances { try await TronGridClient(http: http).balances(address: owner) }
    func receipt(_ hash: String) async throws -> TronExecutionReceipt {
        let result = try await chain.executionReceipt(hash: hash)
        return try XCTUnwrap(result)
    }
    func store() throws -> TronTransferJournalStore {
        try TronTransferJournalStore(directory: directory.appendingPathComponent("journal"), address: owner)
    }
    func send(_ quote: TronTransferQuote) async throws -> TransferReceipt {
        try await chain.sendUSDT(from: owner, to: recipient, usdtSun: Self.amount,
            feeLimitSun: quote.fee.feeLimitSun, bandwidthLimit: quote.fee.bandwidthRequired,
            willBroadcast: { hash, expiration in
                let store = try self.store()
                let previous = try store.load()
                var next = previous
                next.transfer = TronTransferRecord(hash: hash, expiration: expiration)
                try store.save(next, replacing: previous)
            }, signingKey: { self.key })
    }
    func settle(_ receipt: TronExecutionReceipt) throws {
        let store = try store(), previous = try store.load()
        var next = previous; next.transfer?.receipt = receipt
        try store.save(next, replacing: previous)
    }
    func requestCount(_ path: String, _ state: [String: Any]) -> Int {
        (state["requests"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == path }.count
    }
    func recipientBalance(_ state: [String: Any]) throws -> Int64 {
        let account = try XCTUnwrap((state["accounts"] as? [[String: Any]])?.first { $0["address"] as? String == recipient })
        return try XCTUnwrap((account["usdt"] as? NSNumber)?.int64Value)
    }

    func completeRental(expectLostResponse: Bool) async throws {
        let before = try await balances(), quote = try await quote()
        let rent = try await rental.quote(address: owner, energy: quote.fee.energyBurned)
        XCTAssertEqual(rent.rentSun, 4_323_166)
        let payment = try await chain.signRentalPayment(from: owner, amountSun: rent.rentSun, signingKey: { self.key })
        let store = try store(), original = try store.load()
        var journal = original
        journal.rental = TronRentalRecord(paymentHash: payment.txHash, expiration: payment.expiration,
                                         energyTarget: quote.fee.energy, rentSun: rent.rentSun)
        try store.save(journal, replacing: original)
        if expectLostResponse {
            do { _ = try await rental.buy(quote: rent, payment: payment); XCTFail("Submission must be uncertain") }
            catch RentalError.uncertain(let hash) { XCTAssertEqual(hash, payment.txHash) }
        } else {
            let order = try await rental.buy(quote: rent, payment: payment)
            XCTAssertTrue(order.hasPrefix("sim-"))
        }
        // Recreate the store, matching a restarted app reading its reservation.
        let restored = try self.store().load()
        XCTAssertTrue(restored.blocksNewPayment)
        let paymentResult = try await self.receipt(payment.txHash)
        XCTAssertTrue(paymentResult.succeeded)
        let waiting = try await chain.resources(address: owner)
        XCTAssertEqual(waiting.energy, 0)
        let waitingBalance = try await balances()
        XCTAssertEqual(waitingBalance.usdtSun, before.usdtSun)
        _ = try await admin("advance", ["blocks": 2])
        let ready = try await chain.resources(address: owner)
        XCTAssertEqual(ready.energy, quote.fee.energy)
        var updated = restored
        updated.rental?.receipt = paymentResult; updated.rental?.ready = true
        try store.save(updated, replacing: restored)
        let requoted = try await self.quote()
        XCTAssertEqual(requoted.fee.energyBurned, 0)
        let receipt = try await send(requoted)
        let result = try await self.receipt(receipt.txHash)
        XCTAssertTrue(result.succeeded)
        try settle(result)
        let after = try await balances()
        let total = rent.rentSun + paymentResult.feeSun + result.feeSun
        XCTAssertEqual(after.usdtSun, before.usdtSun - Self.amount)
        XCTAssertEqual(after.trxBalance, before.trxBalance - total)
        XCTAssertEqual(try self.store().load().actualTotalSun, total)
        XCTAssertFalse(try self.store().load().blocksNewPayment)
        let final = try await state()
        XCTAssertEqual((final["orders"] as? [Any])?.count, 1)
        XCTAssertEqual(final["committed_transactions"] as? Int, 2)
        XCTAssertEqual(requestCount("/v2/buy-resource", final), 1)
        XCTAssertEqual(requestCount("/wallet/broadcasttransaction", final), 1)
    }
}
