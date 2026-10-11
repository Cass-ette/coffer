import Foundation
import CoreFoundation

/// Resource amounts are remaining quotas, including incoming delegations.
public struct TronResources: Equatable, Sendable {
    public let energy: Int64
    public let bandwidth: Int64
    public let freeBandwidth: Int64

    public init(energy: Int64, bandwidth: Int64, freeBandwidth: Int64) throws {
        guard energy >= 0, bandwidth >= 0, freeBandwidth >= 0 else { throw TronGridError.badResponse }
        self.energy = energy
        self.bandwidth = bandwidth
        self.freeBandwidth = freeBandwidth
    }

    init(response: [String: Any]) throws {
        func counter(_ key: String, required: Bool = false) throws -> Int64 {
            guard let value = response[key] else {
                if required { throw TronGridError.badResponse }
                return 0
            }
            guard let number = WalletJSON.integer(value), number >= 0 else { throw TronGridError.badResponse }
            return number
        }
        try self.init(
            energy: max(0, counter("EnergyLimit") - counter("EnergyUsed")),
            bandwidth: max(0, counter("NetLimit") - counter("NetUsed")),
            freeBandwidth: max(0, counter("freeNetLimit", required: true) - counter("freeNetUsed")))
    }

    /// Each bandwidth pool must cover the whole transaction. Partial pools are never combined.
    public func consumingBandwidth(_ bytes: Int64) throws -> (remaining: TronResources, burned: Int64) {
        guard bytes >= 0 else { throw TronGridError.badResponse }
        if bandwidth >= bytes {
            return (try TronResources(energy: energy, bandwidth: bandwidth - bytes, freeBandwidth: freeBandwidth), 0)
        }
        if freeBandwidth >= bytes {
            return (try TronResources(energy: energy, bandwidth: bandwidth, freeBandwidth: freeBandwidth - bytes), 0)
        }
        return (self, bytes)
    }
}

enum WalletJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TronGridError.badResponse
        }
        return result
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard a >= 0, b >= 0, !overflow else { throw TronGridError.badResponse }
        return value
    }
    static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw TronGridError.badResponse }
        return value
    }
}
