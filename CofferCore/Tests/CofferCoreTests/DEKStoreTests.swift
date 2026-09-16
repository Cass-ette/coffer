import XCTest
@testable import CofferCore
import Security
import LocalAuthentication
import CryptoKit

final class DEKStoreTests: XCTestCase {

    // MARK: - Real Keychain Smoke Test

    func testSystemStoreAddDeleteRoundtripOnHost() throws {
        // Real Keychain smoke test: add/delete doesn't trigger auth UI
        // Unsigned test process can't carry ACL entitlement (-34018), auto-skip
        // Real ACL read deferred to packaged manual validation (Task 12/20)

        let store = SystemDEKStore()
        let testDEK = SymmetricKey(data: Data(repeating: 0xAB, count: 32))

        // First, clean up any existing entry from previous test runs
        _ = try? store.delete()

        do {
            // Store DEK with userPresence ACL
            try store.store(testDEK)

            // Verify it exists
            let exists = store.contains()
            XCTAssertTrue(exists, "DEK should exist after store()")

            // Clean up
            try store.delete()

            // Verify deletion
            let stillExists = store.contains()
            XCTAssertFalse(stillExists, "DEK should not exist after delete()")

        } catch let error as DEKStoreError {
            if case .unexpectedStatus(let status) = error, status == -34018 {
                // Auto-skip: unsigned test host can't carry ACL entitlement
                throw XCTSkip("Skipping real Keychain test: unsigned test process lacks entitlement (-34018)")
            }
            throw error
        }
    }

    // MARK: - Fake Store Semantics

    func testFakeStoreSemanticsForUnlockTests() throws {
        // FakeDEKStore test double for UnlockService logic tests
        let fake = FakeDEKStore()

        // Initially empty
        XCTAssertFalse(fake.contains())
        XCTAssertNil(try fake.retrieve(using: LAContext()))

        // Store a DEK
        let dek = SymmetricKey(data: Data(repeating: 0xCD, count: 32))
        try fake.store(dek)

        // Now exists
        XCTAssertTrue(fake.contains())

        // Retrieve returns the stored DEK
        let retrieved = try fake.retrieve(using: LAContext())
        let retrievedData = retrieved?.withUnsafeBytes { Data($0) }
        let dekData = dek.withUnsafeBytes { Data($0) }
        XCTAssertEqual(retrievedData, dekData)

        // peek() returns DEK without LAContext
        let peeked = fake.peek()
        let peekedData = peeked?.withUnsafeBytes { Data($0) }
        XCTAssertEqual(peekedData, dekData)

        // Delete removes it
        try fake.delete()
        XCTAssertFalse(fake.contains())
        XCTAssertNil(try fake.retrieve(using: LAContext()))
        XCTAssertNil(fake.peek())

        // Delete is idempotent
        try fake.delete() // Should not throw
    }
}

// MARK: - Test Double

/// Fake in-memory DEKStore for testing UnlockService logic
final class FakeDEKStore: DEKStoring, @unchecked Sendable {
    private var storage: SymmetricKey?
    private let lock = NSLock()
    var willReject = false

    func store(_ dek: SymmetricKey) throws {
        lock.lock()
        defer { lock.unlock() }
        storage = dek
    }

    func retrieve(using context: LAContext) throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return willReject ? nil : storage
    }

    func contains() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage != nil
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        storage = nil
    }

    /// Test-only: peek at stored DEK without LAContext
    func peek() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
