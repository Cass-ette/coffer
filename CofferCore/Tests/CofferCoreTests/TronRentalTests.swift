import XCTest
import CryptoKit
@testable import CofferCore

final class TronRentalTests: XCTestCase {
    typealias MockHTTP = TronTransferServiceTests.MockHTTP
    static let address = TronTransferServiceTests.address
    // Offline fixture: public test mnemonic owner, never broadcast.
    static let raw = "0a0293c722084f63db12933385d440b89f8dc692345a68080112640a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412330a1541c8599111f29c1e1e061265b4af93ea1f274ad78a121541e1d21475bbdc974045a4121fc5209f027be618a418b2e68a027088d389c69234"
    static let now = Date(timeIntervalSince1970: 1_791_685_192)

    func stubQuote(_ mock: MockHTTP, price: String = "67.25", total: Int64 = 4_371_250, available: Int64 = 65_000) {
        mock.stubs["/v2/estimate-buy-resource"] = Data("""
        {"error":false,"data":{"unitPrice":\(price),"durationSec":3600,"estimateTrx":\(total),"availableResource":\(available)}}
        """.utf8)
    }

    static func paymentResponse(raw: String = raw, amount: Int64 = 4_371_250) throws -> Data {
        let chars = Array(raw)
        let bytes = Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
        return try JSONSerialization.data(withJSONObject: [
            "txID": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "raw_data_hex": raw, "visible": false,
            "raw_data": ["expiration": 1_791_685_251_000 as Int64,
                         "contract": [["type": "TransferContract", "parameter": ["value": [
                            "owner_address": TronTransferService.hex41(address)!,
                            "to_address": TronTransferService.hex41(TronSaveClient.paymentAddress)!,
                            "amount": amount]]]]]
        ])
    }

    func testFractionalUnitPriceRemainsExactAndNoAPIKeyIsNeeded() async throws {
        let mock = MockHTTP(); stubQuote(mock)
        let quote = try await TronSaveClient(http: mock).quote(address: Self.address, energy: 65_000, now: Self.now)
        XCTAssertEqual(quote.unitPrice, Decimal(string: "67.25"))
        XCTAssertEqual(quote.rentSun, 4_371_250)
        XCTAssertEqual(mock.posted[0].body["resourceAmount"] as? Int64, 65_000)
        XCTAssertEqual(mock.posted[0].body["receiver"] as? String, Self.address)
        XCTAssertTrue(mock.posted[0].headers.isEmpty)
    }

    func testQuoteRejectsPartialSupplyAndInconsistentPrice() async {
        for values in [(64_999, Int64(4_371_250)), (65_000, Int64(4_371_251))] {
            let mock = MockHTTP(); stubQuote(mock, total: values.1, available: Int64(values.0))
            do {
                _ = try await TronSaveClient(http: mock).quote(address: Self.address, energy: 65_000)
                XCTFail("Do not show an executable rental without full supply and consistent pricing")
            } catch { }
        }
    }

    func testRentalComparisonIncludesBothTransactionsBandwidth() async throws {
        let mock = MockHTTP(); stubQuote(mock)
        let quote = try await TronSaveClient(http: mock).quote(address: Self.address, energy: 65_000)
        let resources = try TronResources(energy: 0, bandwidth: 0, freeBandwidth: 600)
        let direct = try TronFee(energy: 65_000, energyPrice: 100, bandwidthBurned: 0,
                                 bandwidthPrice: 1000, resources: resources)
        let plan = try TronRentalPlan(quote: quote, directFee: direct)
        XCTAssertEqual(plan.paymentFeeSun, 0)
        XCTAssertEqual(plan.transferFeeSun, 345_000)
        XCTAssertEqual(plan.totalSun, 4_716_250)
        XCTAssertEqual(plan.savingsSun, 1_783_750)
        XCTAssertEqual(plan.maximumTotalSun, 6_016_250)
    }

    func testNativePaymentRejectsJSONAndProtobufDisagreementBeforeReadingKey() async throws {
        let mock = MockHTTP()
        mock.stubs["/wallet/createtransaction"] = try Self.paymentResponse(amount: 4_371_251)
        var keyRead = false
        do {
            _ = try await TronTransferService(http: mock).signRentalPayment(
                from: Self.address, amountSun: 4_371_250, now: Self.now, signingKey: {
                    keyRead = true
                    return try TronWalletService().privateKeyData(fromMnemonic: TronTransferServiceTests.mnemonic)
                })
            XCTFail("Provider JSON must describe the same payment as the signed bytes")
        } catch { }
        XCTAssertFalse(keyRead)
    }

    func testNativePaymentChecksRealProtobufBeforeReadingKey() async throws {
        let mock = MockHTTP()
        mock.stubs["/wallet/createtransaction"] = try Self.paymentResponse(
            raw: Self.raw.replacingOccurrences(of: "b2e68a02", with: "b3e68a02"))
        var keyRead = false
        do {
            _ = try await TronTransferService(http: mock).signRentalPayment(
                from: Self.address, amountSun: 4_371_250, now: Self.now, signingKey: {
                    keyRead = true
                    return try TronWalletService().privateKeyData(fromMnemonic: TronTransferServiceTests.mnemonic)
                })
            XCTFail("A JSON-matching response with different signed amount must be rejected")
        } catch { }
        XCTAssertFalse(keyRead)
    }

    func testRentalPaymentSignsLocallyAndDoesNotBroadcastSeparately() async throws {
        let mock = MockHTTP()
        mock.stubs["/wallet/createtransaction"] = try Self.paymentResponse()
        let payment = try await TronTransferService(http: mock).signRentalPayment(
            from: Self.address, amountSun: 4_371_250, now: Self.now, signingKey: {
                try TronWalletService().privateKeyData(fromMnemonic: TronTransferServiceTests.mnemonic)
            })
        let signed = try WalletJSON.object(payment.payload)
        XCTAssertEqual((signed["signature"] as? [String])?.first?.count, 130)
        XCTAssertLessThanOrEqual(payment.bandwidth, TronRentalPlan.paymentBandwidth)
        XCTAssertFalse(mock.posted.contains { $0.path == "/wallet/broadcasttransaction" })
    }

    func testSubmittingPaymentUsesPriceCapAndTimeoutStaysUncertain() async throws {
        let mock = MockHTTP(); stubQuote(mock)
        mock.stubs["/wallet/createtransaction"] = try Self.paymentResponse()
        let quote = try await TronSaveClient(http: mock).quote(address: Self.address, energy: 65_000, now: Self.now)
        let payment = try await TronTransferService(http: mock).signRentalPayment(
            from: Self.address, amountSun: quote.rentSun, now: Self.now, signingKey: {
                try TronWalletService().privateKeyData(fromMnemonic: TronTransferServiceTests.mnemonic)
            })
        mock.failurePath = "/v2/buy-resource"
        do {
            _ = try await TronSaveClient(http: mock).buy(quote: quote, payment: payment, now: Self.now)
            XCTFail("Submission timeout must retain the payment hash")
        } catch RentalError.uncertain(let hash) { XCTAssertEqual(hash, payment.txHash) }
        let options = try XCTUnwrap(mock.posted.last?.body["options"] as? [String: Any])
        XCTAssertEqual(options["allowPartialFill"] as? Bool, false)
        XCTAssertEqual(options["onlyCreateWhenFulfilled"] as? Bool, true)
        XCTAssertEqual(options["preventDuplicateIncompleteOrders"] as? Bool, true)
        XCTAssertEqual((options["maxPriceAccepted"] as? NSDecimalNumber)?.stringValue, "67.25")
    }

    func testExpiredQuoteNeverSubmitsPayment() async throws {
        let mock = MockHTTP(); stubQuote(mock)
        mock.stubs["/wallet/createtransaction"] = try Self.paymentResponse()
        let quote = try await TronSaveClient(http: mock).quote(address: Self.address, energy: 65_000, now: Self.now)
        let payment = try await TronTransferService(http: mock).signRentalPayment(
            from: Self.address, amountSun: quote.rentSun, now: Self.now, signingKey: {
                try TronWalletService().privateKeyData(fromMnemonic: TronTransferServiceTests.mnemonic)
            })
        do {
            _ = try await TronSaveClient(http: mock).buy(quote: quote, payment: payment, now: Self.now.addingTimeInterval(120))
            XCTFail("Expired quote needs a new confirmation")
        } catch RentalError.expired { }
        XCTAssertFalse(mock.posted.contains { $0.path == "/v2/buy-resource" })
    }
}
