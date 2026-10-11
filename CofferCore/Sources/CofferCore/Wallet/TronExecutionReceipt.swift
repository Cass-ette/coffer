import Foundation

public struct TronExecutionReceipt: Equatable, Codable, Sendable {
    public let txHash: String
    public let result: String
    public let blockNumber: Int64
    public let feeSun: Int64
    public let energyFeeSun: Int64
    public let bandwidthFeeSun: Int64
    public let energyConsumed: Int64
    public var succeeded: Bool { result == "SUCCESS" }

    static func parse(_ data: Data, expectedHash: String) throws -> TronExecutionReceipt? {
        let object = try WalletJSON.object(data)
        if object.isEmpty { return nil }
        guard object["id"] as? String == expectedHash,
              let block = WalletJSON.integer(object["blockNumber"]), block >= 0,
              let receipt = object["receipt"] as? [String: Any] else { throw TronGridError.badResponse }
        func amount(_ value: Any?) throws -> Int64 {
            if value == nil { return 0 }
            guard let n = WalletJSON.integer(value), n >= 0 else { throw TronGridError.badResponse }
            return n
        }
        if let value = receipt["result"], !(value is String) { throw TronGridError.badResponse }
        if let value = object["result"], !(value is String) { throw TronGridError.badResponse }
        let receiptResult = receipt["result"] as? String
        let result = object["result"] as? String == "FAILED" && receiptResult == "SUCCESS"
            ? "FAILED" : (receiptResult ?? (object["result"] as? String ?? "SUCCESS"))
        guard !result.isEmpty else { throw TronGridError.badResponse }
        let fee = try amount(object["fee"])
        let energyFee = try amount(receipt["energy_fee"])
        let bandwidthFee = try amount(receipt["net_fee"])
        guard fee >= (try WalletJSON.add(energyFee, bandwidthFee)) else { throw TronGridError.badResponse }
        return TronExecutionReceipt(txHash: expectedHash, result: result, blockNumber: block, feeSun: fee,
                                    energyFeeSun: energyFee, bandwidthFeeSun: bandwidthFee,
                                    energyConsumed: try amount(receipt["energy_usage_total"]))
    }
}
