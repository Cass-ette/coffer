import Foundation
import CryptoKit

public enum EntryType: String, Codable, Sendable, CaseIterable {
    case login, access
    case apiKey = "api_key"
    case sshKey = "ssh_key"
    case database
    case totp
    case secureNote = "secure_note"
    case wallet
    case unknown
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

/// Tron 钱包。secret 为助记词/私钥原文（watchOnly 为 nil）；
/// 与其他 payload 同级进 vault 密文，转账前才解密（spec §4）。
public struct WalletPayload: Codable, Hashable, Sendable {
    public enum Chain: String, Codable, Hashable, Sendable {
        case tron
    }
    public enum SecretKind: String, Codable, Hashable, Sendable {
        case mnemonic
        case privateKey
        case watchOnly
    }

    public var chain: Chain
    public var address: String
    public var secretKind: SecretKind
    public var secret: String?
    public var derivationPath: String?
    public var note: String?

    public init(chain: Chain, address: String, secretKind: SecretKind,
                secret: String?, derivationPath: String?, note: String?) {
        self.chain = chain; self.address = address; self.secretKind = secretKind
        // 不变量：watchOnly 钱包不携带 secret。构造时归一化而非 crash，
        // 避免旧/损坏数据在读取路径上炸掉整个 vault。
        self.secret = secretKind == .watchOnly ? nil : secret
        self.derivationPath = derivationPath; self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case chain, address, secretKind, secret, derivationPath, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(chain: try container.decode(Chain.self, forKey: .chain),
                  address: try container.decode(String.self, forKey: .address),
                  secretKind: try container.decode(SecretKind.self, forKey: .secretKind),
                  secret: try container.decodeIfPresent(String.self, forKey: .secret),
                  derivationPath: try container.decodeIfPresent(String.self, forKey: .derivationPath),
                  note: try container.decodeIfPresent(String.self, forKey: .note))
    }
}

/// Known cases keep Swift's synthesized {"case":{"_0":payload}} disk shape.
/// Unknown cases retain their JSON structure for lossless round-tripping.
public enum EntryPayload: Codable, Hashable, Sendable {
    case login(LoginPayload)
    case access(AccessPayload)
    case apiKey(APIKeyPayload)
    case sshKey(SSHKeyPayload)
    case database(DatabasePayload)
    case totp(TOTPPayload)
    case secureNote(SecureNotePayload)
    case wallet(WalletPayload)
    case unknown(RawJSON)

    public init(from decoder: Decoder) throws {
        let dict = try decoder.singleValueContainer().decode([String: RawJSON].self)
        self = .unknown(.object(dict))
        if let value = dict["login"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(LoginPayload.self, from: data) {
            self = .login(payload); return
        }
        if let value = dict["access"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(AccessPayload.self, from: data) {
            self = .access(payload); return
        }
        if let value = dict["apiKey"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(APIKeyPayload.self, from: data) {
            self = .apiKey(payload); return
        }
        if let value = dict["sshKey"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(SSHKeyPayload.self, from: data) {
            self = .sshKey(payload); return
        }
        if let value = dict["database"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(DatabasePayload.self, from: data) {
            self = .database(payload); return
        }
        if let value = dict["totp"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(TOTPPayload.self, from: data) {
            self = .totp(payload); return
        }
        if let value = dict["secureNote"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(SecureNotePayload.self, from: data) {
            self = .secureNote(payload); return
        }
        if let value = dict["wallet"], case .object(let inner) = value,
           let zero = inner["_0"], let data = zero.jsonData,
           let payload = try? JSONDecoder().decode(WalletPayload.self, from: data) {
            self = .wallet(payload); return
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .login(let p): try container.encode(Self.wrap("login", p))
        case .access(let p): try container.encode(Self.wrap("access", p))
        case .apiKey(let p): try container.encode(Self.wrap("apiKey", p))
        case .sshKey(let p): try container.encode(Self.wrap("sshKey", p))
        case .database(let p): try container.encode(Self.wrap("database", p))
        case .totp(let p): try container.encode(Self.wrap("totp", p))
        case .secureNote(let p): try container.encode(Self.wrap("secureNote", p))
        case .wallet(let p): try container.encode(Self.wrap("wallet", p))
        case .unknown(let raw): try container.encode(raw)
        }
    }

    private static func wrap<P: Encodable>(_ key: String, _ payload: P) throws -> [String: RawJSON] {
        let raw = try JSONEncoder().encode(payload)
        guard let value = RawJSON.from(raw) else {
            throw EncodingError.invalidValue(payload, .init(codingPath: [], debugDescription: "Payload is not JSON"))
        }
        return [key: .object(["_0": value])]
    }
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
    public var degradedTypeRaw: String?
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
        self.id = id; self.type = type; self.degradedTypeRaw = nil
        self.title = title; self.subtitle = subtitle
        self.groupIDs = groupIDs; self.tags = tags; self.isFavorite = isFavorite
        self.isHidden = isHidden; self.permissionNote = permissionNote; self.customFields = customFields
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.payload = payload
    }

    // Migration helper: decode old groupID field to groupIDs array
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let rawType = try container.decode(String.self, forKey: .type)
        if let known = EntryType(rawValue: rawType) {
            type = known
            degradedTypeRaw = try container.decodeIfPresent(String.self, forKey: .degradedTypeRaw)
        } else {
            type = .unknown
            degradedTypeRaw = rawType
        }
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
        try container.encode(type == .unknown ? degradedTypeRaw ?? type.rawValue : type.rawValue, forKey: .type)
        try container.encodeIfPresent(degradedTypeRaw, forKey: .degradedTypeRaw)
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
        case id, type, degradedTypeRaw, title, subtitle, groupID, groupIDs, tags, isFavorite, isHidden
        case permissionNote, customFields, createdAt, updatedAt, payload
    }
}
