import Foundation
import Security
import LocalAuthentication

// MARK: - Protocol

/// Storage interface for Data Encryption Key with biometric protection
public protocol DEKStoring: AnyObject, Sendable {
    /// Store DEK with userPresence ACL (biometric/passcode required to read)
    func store(_ dek: Data) throws

    /// Retrieve DEK using an already-authenticated LAContext
    /// - Parameter context: LAContext with interactionNotAllowed=true (must be pre-authenticated)
    /// - Returns: DEK data, or nil if not found / auth failed / user canceled
    func retrieve(using context: LAContext) throws -> Data?

    /// Check if a DEK exists in storage
    func contains() throws -> Bool

    /// Delete stored DEK (idempotent: no error if already absent)
    func delete() throws
}

// MARK: - Error

public enum DEKStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
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

    public func store(_ dek: Data) throws {
        // Delete any existing entry first
        _ = try? delete()

        // Create access control with userPresence requirement
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw DEKStoreError.unexpectedStatus(errSecParam)
        }

        // Store with ACL
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: dek,
            kSecAttrAccessControl as String: access
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DEKStoreError.unexpectedStatus(status)
        }
    }

    public func retrieve(using context: LAContext) throws -> Data? {
        // Use LAContext with interactionNotAllowed=true (already authenticated)
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // Expected "not found" or "auth failed" cases return nil
        switch status {
        case errSecSuccess:
            return result as? Data
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

    public func contains() throws -> Bool {
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
            throw DEKStoreError.unexpectedStatus(status)
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
