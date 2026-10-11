import Foundation
import Security

/// A separate non-synchronizing item. Never accesses the vault's DEK service.
public final class GasFreeCredentialStore {
    private let service: String
    public init(service: String = "cc.cassette.coffer.gasfree.api.mainnet") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "credentials", kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> GasFreeCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DEKStoreError.unexpectedStatus(status) }
        let value = try JSONDecoder().decode(GasFreeCredentials.self, from: data)
        return try GasFreeCredentials(key: value.key, secret: value.secret)
    }
    public func save(_ credentials: GasFreeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DEKStoreError.unexpectedStatus(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DEKStoreError.unexpectedStatus(status) }
    }
}
