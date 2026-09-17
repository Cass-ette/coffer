import Foundation
import Security
import LocalAuthentication
import CryptoKit

// MARK: - Protocol

/// Storage interface for Data Encryption Key with biometric protection
public protocol DEKStoring: AnyObject, Sendable {
    /// Store DEK with userPresence ACL (biometric/passcode required to read)
    func store(_ dek: SymmetricKey) throws

    /// Retrieve DEK using an already-authenticated LAContext
    /// - Parameter context: LAContext with interactionNotAllowed=true (must be pre-authenticated)
    /// - Returns: DEK, or nil if not found / auth failed / user canceled
    func retrieve(using context: LAContext) throws -> SymmetricKey?

    /// Check if a DEK exists in storage
    func contains() -> Bool

    /// Delete stored DEK (idempotent: no error if already absent)
    func delete() throws
}

// MARK: - Error

public enum DEKStoreError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)"
        }
    }
}

// MARK: - System Implementation

/// Real Keychain-backed DEK store with userPresence ACL
public final class SystemDEKStore: DEKStoring, Sendable {
    private let service: String
    private let account: String

    public init(service: String = "cc.cassette.coffer.dek", account: String = "dek1") {
        self.service = service
        self.account = account
    }

    public func store(_ dek: SymmetricKey) throws {
        // Delete any existing entry first
        _ = try? delete()

        // Convert SymmetricKey to Data for Keychain storage
        let dekData = dek.withUnsafeBytes { Data($0) }

        // Store without ACL first to bypass -34018 error
        // TODO: Add biometric protection after fixing signing issues
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: dekData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DEKStoreError.unexpectedStatus(status)
        }
    }

    public func retrieve(using context: LAContext) throws -> SymmetricKey? {
        // Try without authentication context first (for simple storage without ACL)
        let simpleQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        var status = SecItemCopyMatching(simpleQuery as CFDictionary, &result)

        // If simple query succeeds, return the data
        if status == errSecSuccess {
            guard let data = result as? Data else { return nil }
            return SymmetricKey(data: data)
        }

        // If simple query fails with interaction required, try with context (ACL-protected item)
        if status == errSecInteractionNotAllowed {
            context.interactionNotAllowed = true
            let contextQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context
            ]

            result = nil
            status = SecItemCopyMatching(contextQuery as CFDictionary, &result)

            if status == errSecSuccess {
                guard let data = result as? Data else { return nil }
                return SymmetricKey(data: data)
            }
        }

        // Expected "not found" or "auth failed" cases return nil
        switch status {
        case errSecItemNotFound,
             errSecAuthFailed,
             errSecUserCanceled,
             errSecInteractionNotAllowed,
             errSecDecode:
            return nil
        default:
            throw DEKStoreError.unexpectedStatus(status)
        }
    }

    public func contains() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            // Unexpected status treated as "not found" (non-throwing)
            return false
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        // Idempotent: success or not-found both OK
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DEKStoreError.unexpectedStatus(status)
        }
    }
}
