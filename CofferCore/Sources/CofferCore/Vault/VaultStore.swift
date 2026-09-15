import Foundation
import CryptoKit

public enum VaultProbe: Equatable {
    case firstRun             // 无 vault 无备份 → 首次设置向导
    case available            // vault 存在且可解码
    case corrupted(hasBackup: Bool) // vault 存在但读不出
}

public final class VaultStore {
    public let fileStore: VaultFileStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileStore: VaultFileStore) {
        self.fileStore = fileStore
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func probe() -> VaultProbe {
        if FileManager.default.fileExists(atPath: fileStore.vaultURL.path) {
            if (try? fileStore.readEnvelope()) != nil { return .available }
            return .corrupted(hasBackup: fileStore.latestBackup() != nil)
        }
        if fileStore.latestBackup() != nil {
            return .corrupted(hasBackup: true)  // vault 丢失但备份在：按损坏处理，绝不进首建向导
        }
        return .firstRun
    }

    /// 首次建库：生成 salt/DEK，主密码 KEK 包装 DEK，写入加密空文档
    @discardableResult
    public func createFirstVault(masterPassword: String) throws -> VaultDocument {
        let salt = try VaultCrypto.randomData(VaultCrypto.saltLength)
        let kek = try VaultCrypto.pbkdf2(password: masterPassword, salt: salt)
        let dek = VaultCrypto.generateDEK()
        let wrapped = try VaultCrypto.wrap(dek, with: kek)
        let doc = VaultDocument.empty()
        let envelope = try makeEnvelope(doc: doc, dek: dek, kdf: .init(
            algo: "PBKDF2-SHA256", iterations: VaultCrypto.pbkdf2Iterations, salt: salt),
            wrappedDEK: wrapped)
        try fileStore.write(envelope)
        return doc
    }

    public func dek(from envelope: VaultFileEnvelope, masterPassword: String) throws -> SymmetricKey {
        let kek = try VaultCrypto.pbkdf2(password: masterPassword, salt: envelope.kdf.salt,
                                         iterations: envelope.kdf.iterations)
        return try VaultCrypto.unwrap(envelope.wrappedDEK, with: kek)
    }

    public func document(from envelope: VaultFileEnvelope, dek: SymmetricKey) throws -> VaultDocument {
        let plaintext = try VaultCrypto.decrypt(envelope.ciphertext, with: dek)
        return try decoder.decode(VaultDocument.self, from: plaintext)
    }

    /// 保存：保留原 kdf/wrappedDEK（除非换主密码），重新加密文档
    public func save(_ doc: VaultDocument, dek: SymmetricKey,
                     previous: VaultFileEnvelope) throws -> VaultFileEnvelope {
        let envelope = try makeEnvelope(doc: doc, dek: dek, kdf: previous.kdf,
                                        wrappedDEK: previous.wrappedDEK)
        try fileStore.write(envelope)
        return envelope
    }

    /// 修改主密码：新 salt 派生新 KEK，重新包装同一 DEK，文档不重加密
    public func changeMasterPassword(_ newPassword: String, dek: SymmetricKey,
                                     previous: VaultFileEnvelope) throws -> VaultFileEnvelope {
        let salt = try VaultCrypto.randomData(VaultCrypto.saltLength)
        let kek = try VaultCrypto.pbkdf2(password: newPassword, salt: salt)
        let wrapped = try VaultCrypto.wrap(dek, with: kek)
        let envelope = VaultFileEnvelope(kdf: .init(
            algo: "PBKDF2-SHA256", iterations: VaultCrypto.pbkdf2Iterations, salt: salt),
            wrappedDEK: wrapped, ciphertext: previous.ciphertext, updatedAt: Date())
        try fileStore.write(envelope)
        return envelope
    }

    private func makeEnvelope(doc: VaultDocument, dek: SymmetricKey,
                              kdf: VaultFileEnvelope.KDFParams, wrappedDEK: Data) throws -> VaultFileEnvelope {
        let plaintext = try encoder.encode(doc)
        let ciphertext = try VaultCrypto.encrypt(plaintext, with: dek)
        return VaultFileEnvelope(kdf: kdf, wrappedDEK: wrappedDEK,
                                 ciphertext: ciphertext, updatedAt: Date())
    }
}
