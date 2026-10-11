import XCTest
@testable import CofferCore

final class TronTransferJournalTests: XCTestCase {
    func testRentalCostAndPendingPaymentSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TronTransferJournalStore(directory: directory, address: TronRentalTests.address)
        var journal = TronTransferJournal()
        journal.rental = TronRentalRecord(paymentHash: String(repeating: "a", count: 64),
            expiration: Date().addingTimeInterval(60), energyTarget: 65_000, rentSun: 4_000_000)
        try store.save(journal)
        XCTAssertTrue(try store.load().blocksNewPayment)
        journal.rental?.ready = true
        try store.save(journal)
        let restored = try store.load()
        XCTAssertFalse(restored.blocksNewPayment)
        XCTAssertEqual(restored.rental?.rentSun, 4_000_000)
    }

    func testCorruptedJournalNeverBecomesEmptyPendingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TronTransferJournalStore(directory: directory, address: TronRentalTests.address)
        try store.save(TronTransferJournal())
        try Data("broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }

    func testPendingTransferBlocksEvenAfterRentalBecomesReady() throws {
        var journal = TronTransferJournal()
        journal.rental = TronRentalRecord(paymentHash: String(repeating: "a", count: 64),
            expiration: Date(), energyTarget: 65_000, rentSun: 4_000_000)
        journal.rental?.ready = true
        journal.transfer = TronTransferRecord(hash: String(repeating: "b", count: 64), expiration: Date())
        XCTAssertTrue(journal.blocksNewPayment)
    }

    func testCannotSaveToInvalidDestinationOrUseAddressAsPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let store = try TronTransferJournalStore(directory: directory, address: TronRentalTests.address)
        XCTAssertThrowsError(try store.save(TronTransferJournal()))
        XCTAssertThrowsError(try TronTransferJournalStore(directory: directory, address: "../vault"))
    }

    func testStaleWindowCannotOverwritePendingPayment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TronTransferJournalStore(directory: directory, address: TronRentalTests.address)
        let original = try store.load()
        var pending = original
        pending.transfer = TronTransferRecord(hash: String(repeating: "b", count: 64), expiration: Date())
        try store.save(pending, replacing: original)
        XCTAssertThrowsError(try store.save(TronTransferJournal(), replacing: original))
        XCTAssertTrue(try store.load().blocksNewPayment)
    }
}
