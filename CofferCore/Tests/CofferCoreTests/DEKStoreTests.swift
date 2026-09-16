import XCTest
@testable import CofferCore
import Security
import LocalAuthentication

final class DEKStoreTests: XCTestCase {

    // MARK: - Real Keychain Smoke Test

    func testSystemStoreAddDeleteRoundtripOnHost() throws {
        // Real Keychain smoke test: add/delete doesn't trigger auth UI
        // Unsigned test process can't carry ACL entitlement (-34018), auto-skip
        // Real ACL read deferred to packaged manual validation (Task 12/20)

        let store = SystemDEKStore()
        let testDEK = Data(repeating: 0xAB, count: 32)

        // First, clean up any existing entry from previous test runs
        _ = try? store.delete()

        do {
            // Store DEK with userPresence ACL
            try store.store(testDEK)

            // Verify it exists
            let exists = try store.contains()
            XCTAssertTrue(exists, "DEK should exist after store()")

            // Clean up
            try store.delete()

            // Verify deletion
            let stillExists = try store.contains()
            XCTAssertFalse(stillExists, "DEK should not exist after delete()")

        } catch let error as DEKStoreError {
            if case .unexpectedStatus(let status) = error, status == errSecMissingEntitlement {
                // Auto-skip: unsigned test host can't carry ACL entitlement
                throw XCTSkip("Skipping real Keychain test: unsigned test process lacks entitlement (errSecMissingEntitlement)")
            }
            throw error
        }
    }

    // MARK: - Fake Store Semantics

    func testFakeStoreSemanticsForUnlockTests() throws {
        // FakeDEKStore test double for UnlockService logic tests
        let fake = FakeDEKStore()

        // Initially empty
        XCTAssertFalse(try fake.contains())
        XCTAssertNil(try fake.retrieve(using: LAContext()))

        // Store a DEK
        let dek = Data(repeating: 0xCD, count: 32)
        try fake.store(dek)

        // Now exists
        XCTAssertTrue(try fake.contains())

        // Retrieve returns the stored DEK
        let retrieved = try fake.retrieve(using: LAContext())
        XCTAssertEqual(retrieved, dek)

        // Delete removes it
        try fake.delete()
        XCTAssertFalse(try fake.contains())
        XCTAssertNil(try fake.retrieve(using: LAContext()))

        // Delete is idempotent
        try fake.delete() // Should not throw
    }
}

// MARK: - Test Double

/// Fake in-memory DEKStore for testing UnlockService logic
final class FakeDEKStore: DEKStoring, @unchecked Sendable {
    private var storage: Data?
    private let lock = NSLock()

    func store(_ dek: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        storage = dek
    }

    func retrieve(using context: LAContext) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func contains() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage != nil
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        storage = nil
    }
}
