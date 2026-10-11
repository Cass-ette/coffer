import Foundation
import Darwin

/// Public transaction metadata only. Never contains a credential or a signed transaction.
public struct TronRentalRecord: Codable, Equatable, Sendable {
    public let paymentHash: String
    public let expiration: Date
    public let energyTarget: Int64
    public let rentSun: Int64
    public var orderID: String?
    public var ready = false
    public var receipt: TronExecutionReceipt?
    public var paidRentSun: Int64 { receipt?.succeeded == false ? 0 : rentSun }

    public init(paymentHash: String, expiration: Date, energyTarget: Int64, rentSun: Int64) {
        self.paymentHash = paymentHash; self.expiration = expiration
        self.energyTarget = energyTarget; self.rentSun = rentSun
    }
}

public struct TronTransferRecord: Codable, Equatable, Sendable {
    public let hash: String
    public let expiration: Date
    public var receipt: TronExecutionReceipt?
    public init(hash: String, expiration: Date) { self.hash = hash; self.expiration = expiration }
}

public struct TronTransferJournal: Codable, Equatable, Sendable {
    public var rental: TronRentalRecord?
    public var transfer: TronTransferRecord?
    public init() {}
    public var blocksNewPayment: Bool {
        (rental != nil && rental?.ready != true) || (transfer != nil && transfer?.receipt == nil)
    }
    public var actualTotalSun: Int64? {
        guard let transferFee = transfer?.receipt?.feeSun else { return nil }
        guard let rental else { return transferFee }
        guard let payment = rental.receipt else { return nil }
        return try? WalletJSON.add(transferFee, WalletJSON.add(payment.feeSun, payment.succeeded ? rental.rentSun : 0))
    }
}

public enum TronJournalError: LocalizedError {
    case unreadable
    public var errorDescription: String? {
        "转账记录无法读取，已暂停新付款。请先核对上一笔链上交易；保险库条目不受影响。"
    }
}

/// Synchronous atomic persistence must finish before any signed transaction is submitted.
public final class TronTransferJournalStore {
    public let fileURL: URL
    private let directory: URL
    public init(directory: URL, address: String) throws {
        guard TronWalletService().validateAddress(address) else { throw TronGridError.invalidAddress }
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(address + ".json")
    }
    public func load() throws -> TronTransferJournal {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return TronTransferJournal() }
        do {
            let value = try JSONDecoder().decode(TronTransferJournal.self, from: Data(contentsOf: fileURL))
            try validate(value)
            return value
        } catch { throw TronJournalError.unreadable }
    }
    public func save(_ journal: TronTransferJournal) throws {
        try validate(journal)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: fileURL, options: .atomic)
    }
    /// Serialize payment reservations across windows and separate app processes.
    public func save(_ journal: TronTransferJournal, replacing previous: TronTransferJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw TronJournalError.unreadable }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw TronJournalError.unreadable }
        defer { flock(lock, LOCK_UN) }
        guard try load() == previous else { throw TronJournalError.unreadable }
        try save(journal)
    }
    private func validate(_ journal: TronTransferJournal) throws {
        func validHash(_ hash: String) -> Bool {
            hash.utf8.count == 64 && hash.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }
        if let rental = journal.rental {
            guard validHash(rental.paymentHash), rental.rentSun > 0, rental.energyTarget > 0,
                  rental.expiration.timeIntervalSince1970.isFinite,
                  rental.receipt == nil || rental.receipt?.txHash == rental.paymentHash else {
                throw TronJournalError.unreadable
            }
        }
        if let transfer = journal.transfer {
            guard validHash(transfer.hash), transfer.expiration.timeIntervalSince1970.isFinite,
                  transfer.receipt == nil || transfer.receipt?.txHash == transfer.hash else {
                throw TronJournalError.unreadable
            }
        }
    }
}
