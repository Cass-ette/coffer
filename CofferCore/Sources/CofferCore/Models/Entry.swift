import Foundation

public enum EntryType: String, Codable, Sendable, CaseIterable {
    case login, access
    case apiKey = "api_key"
    case sshKey = "ssh_key"
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
    case totp(TOTPPayload)
    case secureNote(SecureNotePayload)
}

public struct Group: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String  // SF Symbol
    public init(id: UUID = UUID(), name: String, symbolName: String) {
        self.id = id; self.name = name; self.symbolName = symbolName
    }
}

public struct Entry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var type: EntryType
    public var title: String
    public var subtitle: String
    public var groupID: UUID?
    public var tags: [String]
    public var isFavorite: Bool
    public var permissionNote: String
    public var customFields: [CustomField]
    public var createdAt: Date
    public var updatedAt: Date
    public var payload: EntryPayload

    public init(id: UUID = UUID(), type: EntryType, title: String, subtitle: String,
                groupID: UUID?, tags: [String], isFavorite: Bool, permissionNote: String,
                customFields: [CustomField], createdAt: Date, updatedAt: Date, payload: EntryPayload) {
        self.id = id; self.type = type; self.title = title; self.subtitle = subtitle
        self.groupID = groupID; self.tags = tags; self.isFavorite = isFavorite
        self.permissionNote = permissionNote; self.customFields = customFields
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.payload = payload
    }
}
