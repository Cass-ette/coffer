import Foundation
import CryptoKit

public enum TokenScope: String, Codable, Sendable {
    case read
    case readWrite = "read_write"
}

public struct AuthToken: Codable, Identifiable, Sendable {
    public let id: String
    public let scope: TokenScope
    public let createdAt: Date
    public let expiresAt: Date
    public let description: String

    public init(id: String, scope: TokenScope, createdAt: Date, expiresAt: Date, description: String = "") {
        self.id = id
        self.scope = scope
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.description = description
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }

    public var isValid: Bool {
        !isExpired
    }

    public static func generate(scope: TokenScope, expiresIn hours: Int, description: String = "") -> AuthToken {
        let id = "coffer_tk_" + randomString(length: 32)
        let now = Date()
        let expires = now.addingTimeInterval(TimeInterval(hours * 3600))
        return AuthToken(id: id, scope: scope, createdAt: now, expiresAt: expires, description: description)
    }

    private static func randomString(length: Int) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        var result = ""
        for _ in 0..<length {
            if let char = chars.randomElement() {
                result.append(char)
            }
        }
        return result
    }
}

public struct TokenStore: Codable, Sendable {
    public var tokens: [AuthToken]

    public init(tokens: [AuthToken] = []) {
        self.tokens = tokens
    }

    public mutating func add(_ token: AuthToken) {
        tokens.append(token)
    }

    public mutating func revoke(_ tokenId: String) {
        tokens.removeAll { $0.id == tokenId }
    }

    public mutating func cleanExpired() {
        tokens.removeAll { $0.isExpired }
    }

    public func validate(_ tokenId: String) -> (valid: Bool, scope: TokenScope?) {
        guard let token = tokens.first(where: { $0.id == tokenId }) else {
            return (false, nil)
        }
        if token.isExpired {
            return (false, nil)
        }
        return (true, token.scope)
    }

    public var validTokens: [AuthToken] {
        tokens.filter { $0.isValid }
    }
}

public final class TokenManager {
    private let tokenPath: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(tokenPath: URL? = nil) {
        if let path = tokenPath {
            self.tokenPath = path
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            self.tokenPath = homeDir.appendingPathComponent(".coffer/tokens.json")
        }

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> TokenStore {
        guard FileManager.default.fileExists(atPath: tokenPath.path) else {
            return TokenStore()
        }
        let data = try Data(contentsOf: tokenPath)
        return try decoder.decode(TokenStore.self, from: data)
    }

    public func save(_ store: TokenStore) throws {
        let dir = tokenPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(store)
        try data.write(to: tokenPath, options: .atomic)
    }

    public func grant(scope: TokenScope, expiresIn hours: Int, description: String = "") throws -> AuthToken {
        var store = try load()
        store.cleanExpired()
        let token = AuthToken.generate(scope: scope, expiresIn: hours, description: description)
        store.add(token)
        try save(store)
        return token
    }

    public func revoke(_ tokenId: String) throws {
        var store = try load()
        store.revoke(tokenId)
        try save(store)
    }

    public func validate(_ tokenId: String) throws -> (valid: Bool, scope: TokenScope?) {
        let store = try load()
        return store.validate(tokenId)
    }

    public func listValid() throws -> [AuthToken] {
        var store = try load()
        store.cleanExpired()
        try save(store)
        return store.validTokens
    }
}
