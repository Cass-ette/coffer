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

        // Create access control with biometric protection
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,  // Require biometry, invalidate if biometry changes
            nil
        ) else {
            throw DEKStoreError.unexpectedStatus(-50)  // errSecParam
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: dekData,
            kSecAttrAccessControl as String: access
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DEKStoreError.unexpectedStatus(status)
        }
    }

    public func retrieve(using context: LAContext) throws -> SymmetricKey? {
        // Use the pre-authenticated context to retrieve DEK
        context.interactionNotAllowed = true  // Silent retrieval, no additional prompts

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw DEKStoreError.unexpectedStatus(status)
        }

        guard let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
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
