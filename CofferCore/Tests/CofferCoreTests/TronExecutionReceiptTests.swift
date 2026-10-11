import XCTest
@testable import CofferCore

final class TronExecutionReceiptTests: XCTestCase {
    let txHash = String(repeating: "a", count: 64)

    func testActualFeeComesFromChainReceiptIncludingFailureCosts() async throws {
        for result in ["SUCCESS", "OUT_OF_ENERGY"] {
            let mock = TronTransferServiceTests.MockHTTP()
            mock.stubs["/wallet/gettransactioninfobyid"] = Data("""
            {"id":"\(txHash)","blockNumber":123,"fee":345000,"receipt":{"result":"\(result)","energy_usage_total":65000,"energy_usage":65000,"net_fee":345000}}
            """.utf8)
            let receipt = try await TronTransferService(http: mock).executionReceipt(hash: txHash)
            XCTAssertEqual(receipt?.succeeded, result == "SUCCESS")
            XCTAssertEqual(receipt?.feeSun, 345_000)
            XCTAssertEqual(receipt?.energyFeeSun, 0)
            XCTAssertEqual(receipt?.energyConsumed, 65_000)
        }
    }

    func testUnconfirmedEmptyResponseIsPendingNotFreeSuccess() async throws {
        let mock = TronTransferServiceTests.MockHTTP()
        mock.stubs["/wallet/gettransactioninfobyid"] = Data("{}".utf8)
        let receipt = try await TronTransferService(http: mock).executionReceipt(hash: txHash)
        XCTAssertNil(receipt)
    }

    func testInvalidOrMismatchedReceiptIsRejected() async {
        for fragment in ["\"id\":\"wrong\",\"fee\":0", "\"id\":\"\(txHash)\",\"fee\":-1",
                         "\"id\":\"\(txHash)\",\"fee\":true"] {
            let mock = TronTransferServiceTests.MockHTTP()
            mock.stubs["/wallet/gettransactioninfobyid"] = Data("{\(fragment),\"blockNumber\":123,\"receipt\":{\"result\":\"SUCCESS\"}}".utf8)
            do {
                _ = try await TronTransferService(http: mock).executionReceipt(hash: txHash)
                XCTFail("Bad receipt must not become a successful zero-cost transfer")
            } catch { }
        }
    }
}
