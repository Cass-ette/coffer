import Foundation

/// 加密后的 vault 文件信封。ciphertext 为 AES-GCM combined 格式
/// （自带 12 字节 nonce 与 16 字节 tag），故不再单列 nonce 字段。
public struct VaultFileEnvelope: Codable, Equatable, Sendable {
    public let format: String       // 恒为 "coffer-vault"
    public let version: Int         // 当前 1
    public let kdf: KDFParams
    public let wrappedDEK: Data
    public let ciphertext: Data
    public let updatedAt: Date

    public struct KDFParams: Codable, Equatable, Sendable {
        public let algo: String
        public let iterations: Int
        public let salt: Data
        public init(algo: String, iterations: Int, salt: Data) {
            self.algo = algo; self.iterations = iterations; self.salt = salt
        }
    }

    public init(format: String = "coffer-vault", version: Int = 1,
                kdf: KDFParams, wrappedDEK: Data, ciphertext: Data, updatedAt: Date) {
        self.format = format; self.version = version; self.kdf = kdf
        self.wrappedDEK = wrappedDEK; self.ciphertext = ciphertext; self.updatedAt = updatedAt
    }
}

public final class VaultFileStore {
    public let directory: URL
    public let vaultURL: URL
    private let bakURLs: [URL]  // index 0 = bak1

    public init(directory: URL) {
        self.directory = directory
        self.vaultURL = directory.appendingPathComponent("vault.vault")
        self.bakURLs = (1...3).map { directory.appendingPathComponent("vault.bak\($0)") }
    }

    /// 默认库目录：~/Library/Application Support/Coffer
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coffer", isDirectory: true)
    }

    // MARK: 读

    public func readEnvelope() throws -> VaultFileEnvelope {
        try decodeEnvelope(at: vaultURL)
    }

    public func readBackup(_ n: Int) throws -> VaultFileEnvelope? {
        precondition((1...3).contains(n))
        guard FileManager.default.fileExists(atPath: bakURLs[n - 1].path) else { return nil }
        return try decodeEnvelope(at: bakURLs[n - 1])
    }

    public func latestBackup() -> VaultFileEnvelope? {
        for i in 1...3 {
            if let env = try? readBackup(i) { return env }
        }
        return nil
    }

    private func decodeEnvelope(at url: URL) throws -> VaultFileEnvelope {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(VaultFileEnvelope.self, from: data)
    }

    // MARK: 写（原子 + 轮换）

    public func write(_ envelope: VaultFileEnvelope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(envelope)
        let tmp = directory.appendingPathComponent("vault-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)

        let fm = FileManager.default
        if fm.fileExists(atPath: vaultURL.path) {
            if fm.fileExists(atPath: bakURLs[2].path) { try fm.removeItem(at: bakURLs[2]) }
            if fm.fileExists(atPath: bakURLs[1].path) { try fm.moveItem(at: bakURLs[1], to: bakURLs[2]) }
            if fm.fileExists(atPath: bakURLs[0].path) { try fm.moveItem(at: bakURLs[0], to: bakURLs[1]) }
            try fm.copyItem(at: vaultURL, to: bakURLs[0])    // 旧 vault → bak1
            _ = try fm.replaceItemAt(vaultURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: vaultURL)
        }
    }

    /// 用备份 n 覆盖当前 vault（恢复流程用）。
    /// 注意：内部走 write()，被覆盖的旧 vault（可能已损坏）会被轮换进 bak1，
    /// 好副本至少在 bak2 存活一份。
    public func restoreFromBackup(_ n: Int) throws {
        guard let env = try readBackup(n) else { return }
        try write(env)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
