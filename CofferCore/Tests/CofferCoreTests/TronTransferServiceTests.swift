import XCTest
import CryptoKit
@testable import CofferCore

final class TronTransferServiceTests: XCTestCase {
    static let address = "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"
    static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    // Unsigned TronGrid response for the public test mnemonic; no live transaction was broadcast.
    static let rawHex = "0a02754b220870169e132c9f68e540a8f6f7ba92345aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a1541c8599111f29c1e1e061265b4af93ea1f274ad78a121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb000000000000000000000000c8599111f29c1e1e061265b4af93ea1f274ad78a00000000000000000000000000000000000000000000000000000000000f424070c9b9f4ba923490018087a70e"

    private static func data(hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...$0+1]), radix: 16)!
        })
    }

    final class MockHTTP: HTTPProviding {
        var stubs: [String: Data] = [:]
        var posted: [(path: String, body: [String: Any], headers: [String: String])] = []
        var failurePath: String?
        var balanceResponse = Data()

        func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> Data {
            posted.append((path, body, headers))
            if failurePath == path { throw URLError(.timedOut) }
            if path == "/wallet/triggerconstantcontract", body["function_selector"] as? String == "balanceOf(address)" {
                return balanceResponse
            }
            return stubs[path] ?? Data()
        }
        func get(_ path: String, headers: [String: String]) async throws -> Data {
            return stubs[path] ?? Data()
        }
    }

    private func stubBalances(_ mock: MockHTTP, trx: Int64 = 50_000_000, usdt: Int64 = 1_000_000,
                              freeLimit: Int = 600, freeUsed: Int = 400) {
        mock.stubs["/v1/accounts/\(Self.address)"] = Data("""
        {"success":true,"data":[{"balance":\(trx),
        "trc20":[{"\(usdtContract)":"\(usdt)"}]}]}
        """.utf8)
        mock.stubs["/wallet/getaccountresource"] = Data("""
        {"freeNetLimit":\(freeLimit),"freeNetUsed":\(freeUsed)}
        """.utf8)
        let hex = String(usdt, radix: 16)
        mock.balanceResponse = Data("""
        {"result":{"result":true},"constant_result":["\(String(repeating: "0", count: 64 - hex.count))\(hex)"]}
        """.utf8)
    }

    private func stubFee(_ mock: MockHTTP) {
        mock.stubs["/wallet/triggerconstantcontract"] = Data("""
        {"result":{"result":true},"energy_used":64317,"transaction":{"raw_data_hex":"0a02"}}
        """.utf8)
        mock.stubs["/wallet/getchainparameters"] = Data("""
        {"chainParameter":[{"key":"getTransactionFee","value":1000},{"key":"getEnergyFee","value":420}]}
        """.utf8)
    }

    private func stubBuiltTransaction(_ mock: MockHTTP, owner: String? = nil, amount: Int64 = 1_000_000,
                                      fee: Int64 = 30_000_000, badHash: Bool = false) {
        let raw = Self.data(hex: Self.rawHex)
        let actualHash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let transaction: [String: Any] = [
            "txID": badHash ? String(repeating: "f", count: 64) : actualHash,
            "raw_data_hex": Self.rawHex,
            "visible": false,
            "raw_data": [
                "fee_limit": fee,
                "contract": [[
                    "type": "TriggerSmartContract",
                    "parameter": ["value": [
                        "owner_address": owner ?? TronTransferService.hex41(Self.address)!,
                        "contract_address": TronTransferService.usdtContractHex,
                        "data": "a9059cbb" + TronTransferService.abiEncode(to: Self.address, amount: amount)!
                    ]]
                ]]
            ]
        ]
        mock.stubs["/wallet/triggersmartcontract"] = try! JSONSerialization.data(withJSONObject: [
            "result": ["result": true], "transaction": transaction
        ])
    }

    func testFeeEstimateParsesEnergyAndBandwidth() async throws {
        let mock = MockHTTP()
        stubBalances(mock)
        stubFee(mock)
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1_000_000)
        XCTAssertEqual(fee.energy, 64_317)
        XCTAssertEqual(fee.energyPrice, 420)
        // TRON charges all transaction bytes if the free allowance cannot cover the whole transaction.
        XCTAssertEqual(fee.bandwidthBurned, 345)
        XCTAssertEqual(fee.feeSun, 64_317 * 420 + 345 * 1000)
        let resourceRequest = try XCTUnwrap(mock.posted.first { $0.path == "/wallet/getaccountresource" })
        XCTAssertEqual(resourceRequest.body["address"] as? String, Self.address)
        XCTAssertEqual(resourceRequest.body["visible"] as? Bool, true)
    }

    func testMissingFeeParametersRejected() async {
        let mock = MockHTTP()
        stubBalances(mock)
        stubFee(mock)
        mock.stubs["/wallet/getchainparameters"] = Data(#"{"chainParameter":[]}"#.utf8)
        do {
            _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
            XCTFail("Must not guess live network fees")
        } catch { }
    }

    func testDelegatedEnergyReducesOnlyTheTRXBurnNotTheExecutionBudget() async throws {
        let mock = MockHTTP()
        stubFee(mock)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{"freeNetLimit":600,"EnergyLimit":60000,"EnergyUsed":10000}"#.utf8)
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(fee.energyAvailable, 50_000)
        XCTAssertEqual(fee.energyBurned, 14_317)
        XCTAssertEqual(fee.feeSun, 14_317 * 420)
        XCTAssertEqual(fee.feeLimitSun, 64_317 * 420)
    }

    func testEnoughResourcesAllowTransferWithoutTRX() async throws {
        let mock = MockHTTP()
        stubBalances(mock, trx: 0)
        stubFee(mock)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{"freeNetLimit":600,"EnergyLimit":100000}"#.utf8)
        let quote = try await TronTransferService(http: mock).quote(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(quote.fee.feeSun, 0)
        XCTAssertGreaterThan(quote.fee.feeLimitSun, 0)
    }

    func testDelegatedBandwidthIsUsedBeforeFreeBandwidth() async throws {
        let mock = MockHTTP()
        stubFee(mock)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{"freeNetLimit":600,"freeNetUsed":590,"NetLimit":400,"NetUsed":20}"#.utf8)
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(fee.bandwidthBurned, 0)
    }

    func testInsufficientBandwidthPoolsCannotBeAddedTogether() async throws {
        let mock = MockHTTP()
        stubFee(mock)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{"freeNetLimit":600,"freeNetUsed":300,"NetLimit":300}"#.utf8)
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(fee.bandwidthBurned, 345)
    }

    func testInvalidResourceCountersFailClosed() async {
        for invalid in [#""EnergyLimit":-1"#, #""EnergyUsed":true"#, #""NetLimit":1.5"#, #""EnergyLimit":9223372036854775808"#] {
            let mock = MockHTTP()
            stubFee(mock)
            mock.stubs["/wallet/getaccountresource"] = Data("{\"freeNetLimit\":600,\(invalid)}".utf8)
            do {
                _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
                XCTFail("Malformed resource counters must not be treated as free resources")
            } catch { }
        }
    }

    func testZeroResourceUsageMayBeOmittedByNode() async throws {
        let mock = MockHTTP()
        stubFee(mock)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{"freeNetLimit":600}"#.utf8)
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(fee.bandwidthBurned, 0)
    }

    func testMissingResourceLimitRejected() async {
        let mock = MockHTTP()
        stubFee(mock)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{}"#.utf8)
        do {
            _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
            XCTFail("Must not assume free bandwidth on a malformed response")
        } catch { }
    }

    func testAmountExceedsBalanceRejectedBeforeEstimate() async throws {
        let mock = MockHTTP()
        stubBalances(mock, usdt: 1_000_000)
        do {
            _ = try await TronTransferService(http: mock).validateTransfer(from: Self.address, to: Self.address, usdtSun: 2_000_000)
            XCTFail("Should reject insufficient USDT")
        } catch let error as TransferValidationError {
            XCTAssertEqual(error, .insufficientUSDT)
        }
        XCTAssertEqual(mock.posted.count, 1)
        XCTAssertEqual(mock.posted.first?.body["function_selector"] as? String, "balanceOf(address)")
    }

    func testInsufficientTRXForFeeRejected() async throws {
        let mock = MockHTTP()
        stubBalances(mock, trx: 100)
        stubFee(mock)
        do {
            _ = try await TronTransferService(http: mock).validateTransfer(from: Self.address, to: Self.address, usdtSun: 500_000)
            XCTFail("Should reject insufficient TRX")
        } catch let error as TransferValidationError {
            XCTAssertEqual(error, .insufficientTRXForFee(neededSun: 64_317 * 420 + 345 * 1000, haveSun: 100))
        }
    }

    func testBadAddressAndAmountRejectedBeforeNetwork() async throws {
        let mock = MockHTTP()
        let service = TronTransferService(http: mock)
        do {
            _ = try await service.validateTransfer(from: "abc", to: Self.address, usdtSun: 1)
            XCTFail("Should reject address")
        } catch let error as TransferValidationError { XCTAssertEqual(error, .invalidAddress) }
        do {
            _ = try await service.validateTransfer(from: Self.address, to: Self.address, usdtSun: 0)
            XCTFail("Should reject zero")
        } catch let error as TransferValidationError { XCTAssertEqual(error, .invalidAmount) }
        XCTAssertTrue(mock.posted.isEmpty)
    }

    func testABIUsesFull64BitAmount() {
        let addressHex = TronTransferService.hex41(Self.address)!
        XCTAssertEqual(addressHex.count, 42)
        XCTAssertTrue(addressHex.hasPrefix("41"))
        let small = TronTransferService.abiEncode(to: Self.address, amount: 1_000_000)!
        XCTAssertEqual(small.count, 128)
        XCTAssertTrue(small.hasSuffix("00000000000f4240"))
        let large = TronTransferService.abiEncode(to: Self.address, amount: 8_589_934_592)!
        XCTAssertTrue(large.hasSuffix("0000000200000000"))
    }

    func testSendUSDTBuildsSignsAndBroadcasts() async throws {
        let mock = MockHTTP()
        stubBuiltTransaction(mock)
        mock.stubs["/wallet/broadcasttransaction"] = Data(#"{"result":true}"#.utf8)
        let key = try TronWalletService().privateKey(fromMnemonic: Self.mnemonic)
        let receipt = try await TronTransferService(http: mock, apiKey: "key").sendUSDT(
            from: Self.address, to: Self.address, usdtSun: 1_000_000,
            privateKeyHex: key, feeLimitSun: 30_000_000)
        XCTAssertEqual(receipt.txHash.count, 64)
        XCTAssertTrue(receipt.tronscanURL.absoluteString.contains(receipt.txHash))
        let built = mock.posted.first { $0.path == "/wallet/triggersmartcontract" }!
        XCTAssertEqual(built.body["fee_limit"] as? Int64, 30_000_000)
        XCTAssertEqual(built.headers["TRON-PRO-API-KEY"], "key")
        let broadcast = mock.posted.last { $0.path == "/wallet/broadcasttransaction" }!
        let signatures = broadcast.body["signature"] as? [String] ?? []
        XCTAssertEqual(signatures.count, 1)
        XCTAssertEqual(signatures.first?.count, 130)
        XCTAssertEqual(broadcast.body["txID"] as? String, receipt.txHash)
    }

    func testTamperedBuilderResponseNeverSignsOrBroadcasts() async throws {
        let mock = MockHTTP()
        let service = TronTransferService(http: mock)
        var keyRead = false
        for badHash in [true, false] {
            stubBuiltTransaction(mock, owner: badHash ? nil : String(repeating: "0", count: 42), badHash: badHash)
            do {
                _ = try await service.sendUSDT(from: Self.address, to: Self.address, usdtSun: 1_000_000,
                                               feeLimitSun: 30_000_000, signingKey: {
                    keyRead = true
                    return try TronWalletService().privateKeyData(fromMnemonic: Self.mnemonic)
                })
                XCTFail("Must reject wrong txID/owner")
            } catch { }
        }
        XCTAssertFalse(keyRead)
        XCTAssertFalse(mock.posted.contains { $0.path == "/wallet/broadcasttransaction" })
    }

    func testMismatchedPrivateKeyNeverBroadcasts() async throws {
        let mock = MockHTTP()
        stubBuiltTransaction(mock)
        do {
            _ = try await TronTransferService(http: mock).sendUSDT(
                from: Self.address, to: Self.address, usdtSun: 1_000_000,
                privateKeyHex: String(repeating: "0", count: 63) + "1", feeLimitSun: 30_000_000)
            XCTFail("Should reject wrong sender key")
        } catch let error as TransferValidationError {
            XCTAssertEqual(error, .privateKeyMismatch)
        }
        XCTAssertFalse(mock.posted.contains { $0.path == "/wallet/broadcasttransaction" })
    }

    func testSignedBytesMustMatchConfirmedTransferEvenWithValidHash() async throws {
        let mock = MockHTTP()
        stubBuiltTransaction(mock)
        var response = try JSONSerialization.jsonObject(with: mock.stubs["/wallet/triggersmartcontract"]!) as! [String: Any]
        var transaction = response["transaction"] as! [String: Any]
        let tamperedHex = Self.rawHex.replacingOccurrences(of: "00000f4240", with: "00000f4241")
        transaction["raw_data_hex"] = tamperedHex
        transaction["txID"] = SHA256.hash(data: Self.data(hex: tamperedHex)).map { String(format: "%02x", $0) }.joined()
        response["transaction"] = transaction
        mock.stubs["/wallet/triggersmartcontract"] = try JSONSerialization.data(withJSONObject: response)
        mock.stubs["/wallet/broadcasttransaction"] = Data(#"{"result":true}"#.utf8)
        var keyRead = false
        do {
            _ = try await TronTransferService(http: mock).sendUSDT(
                from: Self.address, to: Self.address, usdtSun: 1_000_000, feeLimitSun: 30_000_000,
                signingKey: {
                    keyRead = true
                    return try TronWalletService().privateKeyData(fromMnemonic: Self.mnemonic)
                })
            XCTFail("JSON can match while the signed protobuf transfers a different amount")
        } catch { }
        XCTAssertFalse(keyRead)
        XCTAssertFalse(mock.posted.contains { $0.path == "/wallet/broadcasttransaction" })
    }

    func testBroadcastDuplicateRejected() async throws {
        let mock = MockHTTP()
        stubBuiltTransaction(mock)
        mock.stubs["/wallet/broadcasttransaction"] = Data(#"{"result":"DUPLICATE_INPUT"}"#.utf8)
        let key = try TronWalletService().privateKey(fromMnemonic: Self.mnemonic)
        do {
            _ = try await TronTransferService(http: mock).sendUSDT(
                from: Self.address, to: Self.address, usdtSun: 1_000_000,
                privateKeyHex: key, feeLimitSun: 30_000_000)
            XCTFail("Should reject immediate broadcast error")
        } catch is BroadcastError { }
    }

    func testBroadcastTimeoutIsUncertainNotFailed() async throws {
        let mock = MockHTTP()
        stubBuiltTransaction(mock)
        mock.failurePath = "/wallet/broadcasttransaction"
        let key = try TronWalletService().privateKey(fromMnemonic: Self.mnemonic)
        do {
            _ = try await TronTransferService(http: mock).sendUSDT(
                from: Self.address, to: Self.address, usdtSun: 1_000_000,
                privateKeyHex: key, feeLimitSun: 30_000_000)
            XCTFail("Should retain hash for chain lookup")
        } catch let error as BroadcastError {
            if case .uncertain(let hash) = error { XCTAssertEqual(hash.count, 64) }
            else { XCTFail("Timeout must be uncertain") }
        }
    }
}
