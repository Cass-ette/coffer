import XCTest
@testable import CofferCore

final class TronSimulationTests: XCTestCase {
    typealias MockHTTP = TronTransferServiceTests.MockHTTP
    static let address = TronTransferServiceTests.address

    // Shape observed from a read-only mainnet USDT simulation. Public test addresses only.
    static func simulation(amount: Int64 = 1, returnValue: String = String(repeating: "0", count: 64)) -> [String: Any] {
        let topic = String(repeating: "0", count: 24) + TronTransferService.hex41(address)!.dropFirst(2)
        let amountHex = String(amount, radix: 16)
        return [
            "result": ["result": true], "energy_used": 64_317,
            "constant_result": [returnValue], "transaction": ["ret": [[:]]],
            "logs": [[
                "address": "a614f803b6fd780986a42c78ec9c7f77e6ded13c",
                "topics": ["ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", topic, topic],
                "data": String(repeating: "0", count: 64 - amountHex.count) + amountHex
            ]]
        ]
    }

    private func mock(_ simulation: [String: Any]) throws -> MockHTTP {
        let mock = MockHTTP()
        mock.stubs["/wallet/triggerconstantcontract"] = try JSONSerialization.data(withJSONObject: simulation)
        mock.stubs["/wallet/getchainparameters"] = Data(#"{"chainParameter":[{"key":"getTransactionFee","value":1000},{"key":"getEnergyFee","value":100}]}"#.utf8)
        mock.stubs["/wallet/getaccountresource"] = Data(#"{"freeNetLimit":600}"#.utf8)
        return mock
    }

    func testSuccessfulUSDTZeroReturnUsesMatchingTransferEvent() async throws {
        let mock = try mock(Self.simulation())
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(fee.energy, 64_317)
        XCTAssertEqual(fee.feeSun, 6_431_700)
        XCTAssertFalse(mock.posted.contains { $0.path.contains("broadcast") })
    }

    func testSuccessfulEmptyReturnStillRequiresMatchingTransferEvent() async throws {
        let mock = try mock(Self.simulation(returnValue: ""))
        let fee = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
        XCTAssertEqual(fee.energy, 64_317)
    }

    func testRealRevertWithTrueNodeResultCannotProduceQuote() async throws {
        var response = Self.simulation(returnValue: "")
        response["result"] = ["result": true, "message": "524556455254206f70636f6465206578656375746564"]
        response["transaction"] = ["ret": [["ret": "FAILED"]]]
        response["logs"] = []
        let mock = try mock(response)
        do {
            _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
            XCTFail("RPC success is not VM execution success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("预检")) }
        XCTAssertEqual(mock.posted.count, 1)
    }

    func testFailedExecutionCannotBeOverriddenByReturnValueOrEvent() async throws {
        for field in ["ret", "contractRet"] {
            var response = Self.simulation(returnValue: String(repeating: "0", count: 63) + "1")
            response["transaction"] = ["ret": [[field: field == "ret" ? "FAILED" : "REVERT"]]]
            let mock = try mock(response)
            do {
                _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
                XCTFail("Explicit execution failure must stop before a fee is quoted")
            } catch { }
            XCTAssertEqual(mock.posted.count, 1)
        }
    }

    func testMissingOrMismatchedUSDTTransferEventIsRejected() async throws {
        for mismatch in ["missing", "contract", "sender", "recipient", "amount", "topic"] {
            var response = Self.simulation(returnValue: String(repeating: "0", count: 63) + "1")
            var logs = response["logs"] as! [[String: Any]]
            var topics = logs[0]["topics"] as! [String]
            switch mismatch {
            case "missing": logs = []
            case "contract": logs[0]["address"] = String(repeating: "a", count: 40)
            case "sender": topics[1] = String(repeating: "0", count: 64); logs[0]["topics"] = topics
            case "recipient": topics[2] = String(repeating: "0", count: 64); logs[0]["topics"] = topics
            case "amount": logs[0]["data"] = String(repeating: "0", count: 63) + "2"
            default: topics[0] = String(repeating: "0", count: 64); logs[0]["topics"] = topics
            }
            response["logs"] = logs
            let mock = try mock(response)
            do {
                _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
                XCTFail("Unverified transfer: \(mismatch)")
            } catch { }
            XCTAssertEqual(mock.posted.count, 1)
        }
    }

    func testIncompleteExecutionStatusCannotSilentlySucceed() async throws {
        for transaction: Any in [[:], ["ret": []], ["ret": [["ret": true]]], ["ret": [["contractRet": 1]]]] {
            var response = Self.simulation(returnValue: "")
            response["transaction"] = transaction
            let mock = try mock(response)
            do {
                _ = try await TronTransferService(http: mock).estimateFee(from: Self.address, to: Self.address, usdtSun: 1)
                XCTFail("Missing/malformed VM status must not become a success")
            } catch { }
        }
    }
}
