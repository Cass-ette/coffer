import XCTest
import CryptoKit
import HsCryptoKit
@testable import CofferCore

final class GasFreeReceiptTests: XCTestCase {
    func fixture() throws -> (GasFreeRecord, [String: Any], [String: Any], [String: Any]) {
        let permit = GasFreePermit(owner: GasFreeClientTests.owner, receiver: GasFreeClientTests.receiver,
            provider: GasFreeClientTests.provider, value: 1000000, maxFee: 2000000, deadline: 2000000000, nonce: 0)
        let signature = try GasFreeCrypto.sign(permit, key: Data(repeating: 0, count: 31) + Data([1]))
        var record = try GasFreeRecord(permit: permit, signatureDigest: GasFreeCrypto.hex(Data(SHA256.hash(data: signature))))
        let hash = String(repeating: "b", count: 64)
        record.transactionHash = hash
        let head = try GasFreeCrypto.addressWord(usdtContract) + GasFreeCrypto.addressWord(permit.owner)
            + GasFreeCrypto.addressWord(permit.receiver)
        let values = GasFreeCrypto.word(permit.value) + GasFreeCrypto.word(permit.maxFee) + GasFreeCrypto.word(permit.deadline)
            + GasFreeCrypto.word(1) + GasFreeCrypto.word(permit.nonce) + GasFreeCrypto.word(288)
        let call = head + values + GasFreeCrypto.word(65) + signature + Data(repeating: 0, count: 31)
        let transaction: [String: Any] = ["txID": hash, "raw_data": ["contract": [["type": "TriggerSmartContract",
            "parameter": ["value": ["contract_address": TronTransferService.hex41(GasFreeCrypto.controller)!,
                "data": "6f21b898" + GasFreeCrypto.hex(call)]]]]]]
        func log(receiver: String, amount: Int64) throws -> [String: Any] {
            ["address": String(TronTransferService.hex41(usdtContract)!.dropFirst(2)),
             "topics": ["ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                        try GasFreeCrypto.hex(GasFreeCrypto.addressWord(record.address)),
                        try GasFreeCrypto.hex(GasFreeCrypto.addressWord(receiver))],
             "data": GasFreeCrypto.hex(GasFreeCrypto.word(amount))]
        }
        let eventTopic = GasFreeCrypto.hex(Crypto.sha3(Data("GasFreeTransfer(address,address,address,address,uint256,uint256,uint256,uint256)".utf8)))
        let eventData = try GasFreeCrypto.addressWord(permit.provider) + GasFreeCrypto.word(permit.value)
            + GasFreeCrypto.word(1000000) + GasFreeCrypto.word(1000000) + GasFreeCrypto.word(permit.nonce)
        let event: [String: Any] = ["address": String(TronTransferService.hex41(GasFreeCrypto.controller)!.dropFirst(2)),
            "topics": [eventTopic, try GasFreeCrypto.hex(GasFreeCrypto.addressWord(usdtContract)),
                       try GasFreeCrypto.hex(GasFreeCrypto.addressWord(permit.owner)),
                       try GasFreeCrypto.hex(GasFreeCrypto.addressWord(permit.receiver))], "data": GasFreeCrypto.hex(eventData)]
        let info: [String: Any] = ["id": hash, "blockNumber": 1, "receipt": ["result": "SUCCESS"],
            "log": [try log(receiver: permit.receiver, amount: permit.value), try log(receiver: permit.provider, amount: 2000000), event]]
        let response: [String: Any] = ["txnActivateFee": 1000000, "txnTransferFee": 1000000,
                                       "txnTotalFee": 2000000, "txnAmount": 1000000, "txnTotalCost": 3000000]
        return (record, info, transaction, response)
    }
    func testReceiptChecksActualUSDTDebitAndSignatureIdentity() throws {
        let (record, info, transaction, response) = try fixture()
        let receipt = try GasFreeService.verifyReceipt(info: info, transaction: transaction, response: response, record: record)
        XCTAssertTrue(receipt.succeeded)
        XCTAssertEqual(receipt.totalCost, 3000000)
        var wrongTransaction = transaction
        wrongTransaction["txID"] = String(repeating: "c", count: 64)
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: info, transaction: wrongTransaction, response: response, record: record))
        let wrongRecord = try GasFreeRecord(permit: record.permit, signatureDigest: String(repeating: "a", count: 64))
        var changed = wrongRecord; changed.transactionHash = record.transactionHash
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: info, transaction: transaction, response: response, record: changed))
    }
    func testRejectClaimedSuccessWithoutTransferOrWithWrongFee() throws {
        let (record, info, transaction, response) = try fixture()
        var noTransfer = info; noTransfer["log"] = []
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: noTransfer, transaction: transaction, response: response, record: record))
        var wrongFee = response; wrongFee["txnTotalFee"] = 0
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: info, transaction: transaction, response: wrongFee, record: record))
        var overLimit = response
        overLimit["txnActivateFee"] = 3000000; overLimit["txnTotalFee"] = 4000000; overLimit["txnTotalCost"] = 5000000
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: info, transaction: transaction, response: overLimit, record: record))
    }
    func testControllerEventMustBindProviderAndNonce() throws {
        let (record, info, transaction, response) = try fixture()
        var missingEvent = info
        missingEvent["log"] = Array((info["log"] as! [[String: Any]]).prefix(2))
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: missingEvent, transaction: transaction, response: response, record: record))
        var logs = info["log"] as! [[String: Any]]
        let data = logs[2]["data"] as! String
        logs[2]["data"] = String(data.dropLast(64)) + GasFreeCrypto.hex(GasFreeCrypto.word(record.permit.nonce + 1))
        var wrongNonce = info; wrongNonce["log"] = logs
        XCTAssertThrowsError(try GasFreeService.verifyReceipt(info: wrongNonce, transaction: transaction, response: response, record: record))
    }
    func testRevertedTransactionReportsZeroUSDTNotRelayerTRX() throws {
        let (record, info, transaction, response) = try fixture()
        var reverted = info
        reverted["receipt"] = ["result": "REVERT", "energy_fee": 1000000]
        reverted["fee"] = 1000000; reverted["log"] = []
        let receipt = try GasFreeService.verifyReceipt(info: reverted, transaction: transaction, response: response, record: record)
        XCTAssertFalse(receipt.succeeded); XCTAssertEqual(receipt.totalCost, 0)
    }
}
