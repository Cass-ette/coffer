import Foundation
import Darwin

public struct GasFreeReceipt: Codable, Equatable, Sendable {
    public let hash: String
    public let succeeded: Bool
    public let activationFee: Int64
    public let transferFee: Int64
    public let amount: Int64
    public var totalFee: Int64 { activationFee + transferFee }
    public var totalCost: Int64 { amount + totalFee }
}

public struct GasFreeRecord: Codable, Equatable, Sendable {
    public let permit: GasFreePermit
    public let address: String
    public let requestID: String
    public let permitHash: String
    public let signatureDigest: String
    public var traceID: String?
    public var transactionHash: String?
    public var state: String = "UNKNOWN"
    public var receipt: GasFreeReceipt?
    public var expiryProof: GasFreeExpiryProof?
    public var settled = false
    init(permit: GasFreePermit, signatureDigest: String) throws {
        self.permit = permit
        self.address = try GasFreeCrypto.address(owner: permit.owner)
        self.requestID = UUID().uuidString.lowercased()
        self.permitHash = try GasFreeCrypto.hex(GasFreeCrypto.hash(permit))
        self.signatureDigest = signatureDigest
    }
}

public struct GasFreeExpiryProof: Codable, Equatable, Sendable {
    public let finalizedTimestamp: Int64
    public let unusedNonce: Int64
}

public struct GasFreeJournal: Codable, Equatable, Sendable {
    public var records: [GasFreeRecord] = []
    public init() {}
    public var blocksNewPayment: Bool { records.contains { !$0.settled } }
}

/// Only public metadata and one-way signature digests; no replayable authorization or API secrets.
public final class GasFreeJournalStore {
    public let fileURL: URL
    public let owner: String
    private let directory: URL
    public init(directory: URL, owner: String) throws {
        guard TronWalletService().validateAddress(owner) else { throw TronGridError.invalidAddress }
        self.directory = directory; self.owner = owner
        fileURL = directory.appendingPathComponent(owner + ".json")
    }
    public func load() throws -> GasFreeJournal {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return GasFreeJournal() }
        do {
            let value = try JSONDecoder().decode(GasFreeJournal.self, from: Data(contentsOf: fileURL))
            try validate(value)
            return value
        } catch { throw GasFreeError.storage }
    }
    public func save(_ journal: GasFreeJournal, replacing previous: GasFreeJournal) throws {
        try validate(journal)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw GasFreeError.storage }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw GasFreeError.storage }
        defer { flock(lock, LOCK_UN) }
        guard try load() == previous else { throw GasFreeError.storage }
        try JSONEncoder().encode(journal).write(to: fileURL, options: .atomic)
    }
    private func validate(_ journal: GasFreeJournal) throws {
        guard Set(journal.records.map(\.requestID)).count == journal.records.count,
              journal.records.dropLast().allSatisfy(\.settled) else { throw GasFreeError.storage }
        for record in journal.records {
            guard record.permit.owner == owner, record.address == (try GasFreeCrypto.address(owner: owner)),
                  record.permitHash == (try GasFreeCrypto.hex(GasFreeCrypto.hash(record.permit))),
                  GasFreeJSON.validHash(record.signatureDigest), UUID(uuidString: record.requestID) != nil,
                  record.traceID == nil || UUID(uuidString: record.traceID!) != nil,
                  record.transactionHash == nil || GasFreeJSON.validHash(record.transactionHash!),
                  !record.settled || record.receipt?.succeeded == true || record.expiryProof != nil else { throw GasFreeError.storage }
            if let proof = record.expiryProof {
                let safeAfter = try WalletJSON.multiply(WalletJSON.add(record.permit.deadline, 60), 1000)
                guard proof.finalizedTimestamp > safeAfter, proof.unusedNonce >= 0,
                      proof.unusedNonce <= record.permit.nonce else { throw GasFreeError.storage }
            }
            if let receipt = record.receipt {
                let fee = try WalletJSON.add(receipt.activationFee, receipt.transferFee)
                _ = try WalletJSON.add(receipt.amount, fee)
                guard receipt.hash == record.transactionHash, fee <= record.permit.maxFee,
                      receipt.amount == (receipt.succeeded ? record.permit.value : 0),
                      receipt.succeeded || fee == 0 else { throw GasFreeError.storage }
            }
        }
    }
}

extension GasFreeJSON {
    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func data(hex: String) throws -> Data {
        guard hex.utf8.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GasFreeError.invalidResponse
        }
        var result = Data()
        let bytes = Array(hex.utf8)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(bytes: bytes[i...i+1], encoding: .utf8)!, radix: 16) else { throw GasFreeError.invalidResponse }
            result.append(byte)
        }
        return result
    }
}
