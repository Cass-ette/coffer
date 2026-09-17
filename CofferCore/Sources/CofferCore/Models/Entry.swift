import Foundation
import CryptoKit

public enum EntryType: String, Codable, Sendable, CaseIterable {
    case login, access
    case apiKey = "api_key"
    case sshKey = "ssh_key"
    case database
    case totp
    case secureNote = "secure_note"
}

public struct CustomField: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var isSensitive: Bool
    public init(name: String, value: String, isSensitive: Bool) {
        self.name = name; self.value = value; self.isSensitive = isSensitive
    }
}

public struct LoginPayload: Codable, Hashable, Sendable {
    public var username: String
    public var password: String
    public var urls: [String]
    public init(username: String, password: String, urls: [String]) {
        self.username = username; self.password = password; self.urls = urls
    }
}

public struct AccessPayload: Codable, Hashable, Sendable {
    public var addresses: [String]
    public var loginMethod: String    // SSO / 密码 / 免登
    public var networkLocation: String // 内网 / 公网
    public var roleNote: String
    public init(addresses: [String], loginMethod: String, networkLocation: String, roleNote: String) {
        self.addresses = addresses; self.loginMethod = loginMethod
        self.networkLocation = networkLocation; self.roleNote = roleNote
    }
}

public struct APIKeyPayload: Codable, Hashable, Sendable {
    public var provider: String
    public var secret: String
    public var envPrefix: String
    public init(provider: String, secret: String, envPrefix: String) {
        self.provider = provider; self.secret = secret; self.envPrefix = envPrefix
    }
}

public struct SSHKeyPayload: Codable, Hashable, Sendable {
    public var host: String
    public var user: String
    public var privateKey: String
    public init(host: String, user: String, privateKey: String) {
        self.host = host; self.user = user; self.privateKey = privateKey
    }
}

public struct DatabasePayload: Codable, Hashable, Sendable {
    public var host: String
    public var port: String
    public var databaseName: String
    public var username: String
    public var password: String
    public var dbType: String  // MySQL / PostgreSQL / MongoDB / Redis / etc
    public var networkLocation: String  // 内网 / 公网
    public init(host: String, port: String, databaseName: String, username: String, password: String, dbType: String, networkLocation: String) {
        self.host = host; self.port = port; self.databaseName = databaseName
        self.username = username; self.password = password
        self.dbType = dbType; self.networkLocation = networkLocation
    }
}

public struct TOTPPayload: Codable, Hashable, Sendable {
    public var secretBase32: String
    public var algorithm: String  // "SHA1" / "SHA256" / "SHA512"
    public var digits: Int
    public var period: Int
    public init(secretBase32: String, algorithm: String, digits: Int, period: Int) {
        self.secretBase32 = secretBase32; self.algorithm = algorithm
        self.digits = digits; self.period = period
    }
}

public struct Attachment: Codable, Hashable, Sendable {
    public var fileName: String
    public var mimeType: String
    public var dataBase64: String
    public init(fileName: String, mimeType: String, dataBase64: String) {
        self.fileName = fileName; self.mimeType = mimeType; self.dataBase64 = dataBase64
    }
}

public struct SecureNotePayload: Codable, Hashable, Sendable {
    public var body: String
    public var attachments: [Attachment]
    public init(body: String, attachments: [Attachment]) {
        self.body = body; self.attachments = attachments
    }
}

/// 关联值枚举的 Codable 由 Swift 5.5+ 自动合成（按 case 名 keyed 编码）
public enum EntryPayload: Codable, Hashable, Sendable {
    case login(LoginPayload)
    case access(AccessPayload)
    case apiKey(APIKeyPayload)
    case sshKey(SSHKeyPayload)
    case database(DatabasePayload)
    case totp(TOTPPayload)
    case secureNote(SecureNotePayload)
}

public struct Group: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String  // SF Symbol
    public var isHidden: Bool
    public var passwordHash: String?  // SHA-256 hash of password, nil if using biometry only

    public init(id: UUID = UUID(), name: String, symbolName: String, isHidden: Bool = false, passwordHash: String? = nil) {
        self.id = id; self.name = name; self.symbolName = symbolName
        self.isHidden = isHidden; self.passwordHash = passwordHash
    }

    /// Verify password against stored hash
    public func verifyPassword(_ password: String) -> Bool {
        guard let hash = passwordHash else { return true }  // No password set
        return Self.hashPassword(password) == hash
    }

    /// Create SHA-256 hash of password
    public static func hashPassword(_ password: String) -> String {
        let data = Data(password.utf8)
        let hash = CryptoKit.SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}


public struct Entry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var type: EntryType
    public var title: String
    public var subtitle: String
    public var groupIDs: [UUID]
    public var tags: [String]
    public var isFavorite: Bool
    public var isHidden: Bool
    public var permissionNote: String
    public var customFields: [CustomField]
    public var createdAt: Date
    public var updatedAt: Date
    public var payload: EntryPayload

    public init(id: UUID = UUID(), type: EntryType, title: String, subtitle: String,
                groupIDs: [UUID], tags: [String], isFavorite: Bool, isHidden: Bool, permissionNote: String,
                customFields: [CustomField], createdAt: Date, updatedAt: Date, payload: EntryPayload) {
        self.id = id; self.type = type; self.title = title; self.subtitle = subtitle
        self.groupIDs = groupIDs; self.tags = tags; self.isFavorite = isFavorite
        self.isHidden = isHidden; self.permissionNote = permissionNote; self.customFields = customFields
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.payload = payload
    }

    // Migration helper: decode old groupID field to groupIDs array
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(EntryType.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)

        // Try new groupIDs first, fall back to old groupID
        if let groupIDs = try? container.decode([UUID].self, forKey: .groupIDs) {
            self.groupIDs = groupIDs
        } else if let groupID = try? container.decodeIfPresent(UUID.self, forKey: .groupID) {
            self.groupIDs = [groupID]
        } else {
            self.groupIDs = []
        }

        tags = try container.decode([String].self, forKey: .tags)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        permissionNote = try container.decode(String.self, forKey: .permissionNote)
        customFields = try container.decode([CustomField].self, forKey: .customFields)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        payload = try container.decode(EntryPayload.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(groupIDs, forKey: .groupIDs)
        try container.encode(tags, forKey: .tags)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(permissionNote, forKey: .permissionNote)
        try container.encode(customFields, forKey: .customFields)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(payload, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, subtitle, groupID, groupIDs, tags, isFavorite, isHidden
        case permissionNote, customFields, createdAt, updatedAt, payload
    }
}
