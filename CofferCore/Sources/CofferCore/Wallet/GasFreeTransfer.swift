import Foundation
import CryptoKit
import TronKit
import HsCryptoKit

extension GasFreeService {
    /// Caller must obtain independent user authentication before providing the signing closure.
    @MainActor
    public func submit(_ quote: GasFreeQuote, store: GasFreeJournalStore,
                       signingKey: @MainActor () throws -> Data) async throws -> GasFreeRecord {
        let previous = try store.load()
        guard !previous.blocksNewPayment else { throw GasFreeError.pending }
        guard quote.snapshot.owner == store.owner, quote.isFresh() else { throw GasFreeError.quoteChanged }
        let fresh = try await self.quote(owner: quote.snapshot.owner, receiver: quote.receiver, value: quote.value)
        guard quote.isFresh(), fresh.maxFee == quote.maxFee,
              fresh.snapshot.activationFee == quote.snapshot.activationFee,
              fresh.snapshot.transferFee == quote.snapshot.transferFee,
              fresh.snapshot.active == quote.snapshot.active, fresh.snapshot.nonce == quote.snapshot.nonce,
              fresh.snapshot.provider == quote.snapshot.provider else { throw GasFreeError.quoteChanged }
        let deadline = try WalletJSON.add(Int64(Date().timeIntervalSince1970), fresh.snapshot.provider.defaultDeadline)
        let permit = GasFreePermit(owner: store.owner, receiver: quote.receiver, provider: fresh.snapshot.provider.address,
                                   value: quote.value, maxFee: quote.maxFee, deadline: deadline, nonce: fresh.snapshot.nonce)
        try Task.checkCancellation()
        var key = try signingKey()
        defer { key.resetBytes(in: 0..<key.count) }
        var signature = try GasFreeCrypto.sign(permit, key: key)
        key.resetBytes(in: 0..<key.count)
        defer { signature.resetBytes(in: 0..<signature.count) }
        let record = try GasFreeRecord(permit: permit, signatureDigest: GasFreeCrypto.hex(Data(SHA256.hash(data: signature))))
        try Task.checkCancellation()
        var reserved = previous
        reserved.records.append(record)
        // Atomic cross-process reservation precedes the first possible network submission.
        try store.save(reserved, replacing: previous)
        do {
            let response = try await client.request("/gasfree/submit", body: [
                "requestId": record.requestID, "token": usdtContract, "serviceProvider": permit.provider,
                "user": permit.owner, "receiver": permit.receiver, "value": permit.value, "maxFee": permit.maxFee,
                "deadline": permit.deadline, "version": 1, "nonce": permit.nonce, "sig": GasFreeCrypto.hex(signature)
            ])
            var accepted = try Self.matchResponse(response, record: record)
            accepted.state = response["state"] as! String
            var journal = reserved
            journal.records[journal.records.count - 1] = accepted
            // Persist returned trace even when the window was closed during the request.
            try store.save(journal, replacing: reserved)
            return accepted
        } catch {
            // Even HTTP rejection may be produced by an intermediary after delivery. Never clear/retry here.
            throw GasFreeError.pending
        }
    }

    public func refresh(store: GasFreeJournalStore, recoveredTraceID: String? = nil) async throws -> GasFreeRecord? {
        let previous = try store.load()
        guard var record = previous.records.last else { return nil }
        if record.settled { return record }
        let trace = recoveredTraceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? record.traceID
        var response: [String: Any] = [:]
        if let trace {
            guard UUID(uuidString: trace) != nil,
                  record.traceID == nil || record.traceID == trace else { throw GasFreeError.invalidResponse }
            response = try await client.request("/gasfree/" + trace)
            guard response["id"] as? String == trace else { throw GasFreeError.invalidResponse }
            record = try Self.matchResponse(response, record: record)
        }
        if let hash = record.transactionHash, !response.isEmpty {
            let info = try await chainObject("/walletsolidity/gettransactioninfobyid", body: ["value": hash])
            if !info.isEmpty {
                let transaction = try await chainObject("/walletsolidity/gettransactionbyid", body: ["value": hash])
                record.receipt = try Self.verifyReceipt(info: info, transaction: transaction, response: response, record: record)
                record.settled = record.receipt?.succeeded == true
            }
        }
        if !record.settled, let proof = try await unusedAfterExpiry(record) {
            record.expiryProof = proof
            record.settled = true
            if record.receipt == nil { record.state = "EXPIRED_UNUSED" }
        }
        var updated = previous
        updated.records[updated.records.count - 1] = record
        try store.save(updated, replacing: previous)
        return record
    }

    /// A finalized, still-unused contract nonce plus finalized expiry proves a lost authorization cannot execute.
    private func unusedAfterExpiry(_ record: GasFreeRecord) async throws -> GasFreeExpiryProof? {
        let block = try await chainObject("/walletsolidity/getnowblock", body: [:])
        let header = block["block_header"] as? [String: Any]
        let raw = header?["raw_data"] as? [String: Any]
        guard let timestamp = WalletJSON.integer(raw?["timestamp"]), timestamp > 0 else { throw GasFreeError.invalidResponse }
        let safeAfter = try WalletJSON.multiply(WalletJSON.add(record.permit.deadline, 60), 1000)
        guard timestamp > safeAfter else { return nil }
        let nonceResponse = try await chainObject("/walletsolidity/triggerconstantcontract", body: [
            "owner_address": record.permit.owner, "contract_address": GasFreeCrypto.controller,
            "function_selector": "nonces(address)", "parameter": try GasFreeCrypto.hex(GasFreeCrypto.addressWord(record.permit.owner)),
            "visible": true
        ])
        guard let result = nonceResponse["result"] as? [String: Any], WalletJSON.bool(result["result"]) == true,
              let words = nonceResponse["constant_result"] as? [String], words.count == 1,
              words[0].count == 64, let nonce = Int64(words[0], radix: 16), nonce >= 0 else { throw GasFreeError.invalidResponse }
        guard nonce <= record.permit.nonce else { return nil }
        return GasFreeExpiryProof(finalizedTimestamp: timestamp, unusedNonce: nonce)
    }

    private func chainObject(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let headers = chainKey.isEmpty ? [:] : ["TRON-PRO-API-KEY": chainKey]
        return try WalletJSON.object(await chain.post(path, body: body, headers: headers))
    }

    static func matchResponse(_ response: [String: Any], record: GasFreeRecord) throws -> GasFreeRecord {
        let permit = record.permit
        guard let trace = response["id"] as? String, UUID(uuidString: trace) != nil,
              record.traceID == nil || record.traceID == trace,
              response["accountAddress"] as? String == permit.owner,
              response["gasFreeAddress"] as? String == record.address,
              response["providerAddress"] as? String == permit.provider,
              response["targetAddress"] as? String == permit.receiver,
              response["tokenAddress"] as? String == usdtContract,
              try GasFreeJSON.amount(response["amount"]) == permit.value,
              try GasFreeJSON.amount(response["nonce"]) == permit.nonce,
              let expiry = response["expiredAt"] as? String,
              let state = response["state"] as? String,
              ["WAITING", "INPROGRESS", "CONFIRMING", "SUCCEED", "FAILED"].contains(state) else {
            throw GasFreeError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry)
        guard let date, abs(date.timeIntervalSince1970 - Double(permit.deadline)) < 0.001 else { throw GasFreeError.invalidResponse }
        if let maxFee = response["maxFee"] { guard try GasFreeJSON.amount(maxFee) == permit.maxFee else { throw GasFreeError.invalidResponse } }
        if let version = response["version"] { guard try GasFreeJSON.amount(version) == 1 else { throw GasFreeError.invalidResponse } }
        if let signature = response["signature"] as? String {
            let data = try GasFreeJSON.data(hex: signature.lowercased())
            guard data.count == 65, GasFreeCrypto.hex(Data(SHA256.hash(data: data))) == record.signatureDigest else {
                throw GasFreeError.invalidResponse
            }
        }
        var updated = record
        updated.traceID = trace; updated.state = state
        if let hash = response["txnHash"] as? String, !hash.isEmpty {
            let normalized = hash.lowercased()
            guard GasFreeJSON.validHash(normalized), record.transactionHash == nil || record.transactionHash == normalized else {
                throw GasFreeError.invalidResponse
            }
            updated.transactionHash = normalized
        }
        return updated
    }

    static func verifyReceipt(info: [String: Any], transaction: [String: Any],
                              response: [String: Any], record: GasFreeRecord) throws -> GasFreeReceipt {
        guard let hash = record.transactionHash, transaction["txID"] as? String == hash,
              let raw = transaction["raw_data"] as? [String: Any],
              let contracts = raw["contract"] as? [[String: Any]], contracts.count == 1,
              contracts[0]["type"] as? String == "TriggerSmartContract",
              let parameter = contracts[0]["parameter"] as? [String: Any],
              let value = parameter["value"] as? [String: Any],
              (value["contract_address"] as? String)?.lowercased() == (try Address(address: GasFreeCrypto.controller).hex.lowercased()),
              let input = (value["data"] as? String)?.lowercased(), input.count <= 131072,
              let execution = try TronExecutionReceipt.parse(JSONSerialization.data(withJSONObject: info), expectedHash: hash) else {
            throw GasFreeError.invalidResponse
        }
        // Mainnet Controller permitTransfer(address,address,address,uint256,uint256,uint256,uint256,uint256,bytes).
        // Fixed ABI and signature digest bind the receipt to the exact locally authorized nonce and fee cap.
        let inputData = try GasFreeJSON.data(hex: input)
        let permit = record.permit
        let head = try GasFreeCrypto.addressWord(usdtContract) + GasFreeCrypto.addressWord(permit.owner) + GasFreeCrypto.addressWord(permit.receiver)
        let values = GasFreeCrypto.word(permit.value) + GasFreeCrypto.word(permit.maxFee) + GasFreeCrypto.word(permit.deadline)
            + GasFreeCrypto.word(1) + GasFreeCrypto.word(permit.nonce) + GasFreeCrypto.word(288) + GasFreeCrypto.word(65)
        guard inputData.count == 420, input.hasPrefix("6f21b898"),
              inputData.subdata(in: 4..<324) == head + values,
              inputData.suffix(31).allSatisfy({ $0 == 0 }),
              GasFreeCrypto.hex(Data(SHA256.hash(data: inputData.subdata(in: 324..<389)))) == record.signatureDigest else {
            throw GasFreeError.invalidResponse
        }
        let logs = info["log"] as? [[String: Any]] ?? []
        let contract = try GasFreeCrypto.hex(Address(address: usdtContract).nonPrefixed)
        let sender = try GasFreeCrypto.hex(GasFreeCrypto.addressWord(record.address))
        let receiver = try GasFreeCrypto.hex(GasFreeCrypto.addressWord(record.permit.receiver))
        let topic = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
        var debit: Int64 = 0
        var matches = 0
        for log in logs {
            guard (log["address"] as? String)?.lowercased() == contract,
                  let topics = log["topics"] as? [String], topics.count == 3,
                  topics[0].lowercased() == topic, topics[1].lowercased() == sender else { continue }
            guard let data = (log["data"] as? String)?.lowercased(), data.count == 64,
                  let amount = Int64(data, radix: 16), amount >= 0 else { throw GasFreeError.invalidResponse }
            debit = try WalletJSON.add(debit, amount)
            if topics[2].lowercased() == receiver && amount == record.permit.value { matches += 1 }
        }
        if !execution.succeeded {
            guard debit == 0 else { throw GasFreeError.invalidResponse }
            return GasFreeReceipt(hash: hash, succeeded: false, activationFee: 0, transferFee: 0, amount: 0)
        }
        let activation = try GasFreeJSON.amount(response["txnActivateFee"])
        let transfer = try GasFreeJSON.amount(response["txnTransferFee"])
        let fee = try WalletJSON.add(activation, transfer)
        let cost = try WalletJSON.add(record.permit.value, fee)
        let eventSignature = GasFreeCrypto.hex(Crypto.sha3(Data("GasFreeTransfer(address,address,address,address,uint256,uint256,uint256,uint256)".utf8)))
        let eventTopics = try [eventSignature, GasFreeCrypto.hex(GasFreeCrypto.addressWord(usdtContract)),
                               GasFreeCrypto.hex(GasFreeCrypto.addressWord(permit.owner)), receiver]
        let eventData = try GasFreeCrypto.addressWord(permit.provider) + GasFreeCrypto.word(permit.value)
            + GasFreeCrypto.word(transfer) + GasFreeCrypto.word(activation) + GasFreeCrypto.word(permit.nonce)
        let controllerHex = try GasFreeCrypto.hex(Address(address: GasFreeCrypto.controller).nonPrefixed)
        let matchingEvents = logs.filter {
            ($0["address"] as? String)?.lowercased() == controllerHex &&
            ($0["topics"] as? [String])?.map({ $0.lowercased() }) == eventTopics &&
            ($0["data"] as? String)?.lowercased() == GasFreeCrypto.hex(eventData)
        }
        guard matches == 1, matchingEvents.count == 1, fee <= record.permit.maxFee, debit == cost,
              try GasFreeJSON.amount(response["txnTotalFee"]) == fee,
              try GasFreeJSON.amount(response["txnAmount"]) == record.permit.value,
              try GasFreeJSON.amount(response["txnTotalCost"]) == cost else { throw GasFreeError.invalidResponse }
        return GasFreeReceipt(hash: hash, succeeded: true, activationFee: activation, transferFee: transfer, amount: record.permit.value)
    }
}
