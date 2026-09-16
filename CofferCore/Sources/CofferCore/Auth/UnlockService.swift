import Foundation
import CryptoKit
import LocalAuthentication

public protocol BiometryPrompting: AnyObject {
    /// 返回"已通过系统认证"的 LAContext；用户取消/失败返回 nil。
    /// 真实现只做一次 evaluatePolicy，Keychain 用同一 context 静默放行。
    func authenticatedContext(reason: String) async -> LAContext?
}

public final class TouchIDPrompt: BiometryPrompting {
    public init() {}
    public func authenticatedContext(reason: String) async -> LAContext? {
        let ctx = LAContext()
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: reason)
            return ok ? ctx : nil
        } catch {
            return nil
        }
    }
}

public enum UnlockResult: Equatable {
    case unlocked
    case needMasterPassword  // Keychain 无 DEK / 生物认证不可用 → 引导主密码
    case wrongPassword
    case cancelled           // 用户主动取消
    case failed(String)
}

public final class UnlockService: ObservableObject {
    @Published public private(set) var isUnlocked = false
    @Published public var document: VaultDocument?  // app 层编辑后调 persist() 落盘
    public private(set) var envelope: VaultFileEnvelope?

    private var dek: SymmetricKey?
    private let vaultStore: VaultStore
    private let dekStore: DEKStoring
    private let prompt: BiometryPrompting

    public init(vaultStore: VaultStore, dekStore: DEKStoring, prompt: BiometryPrompting) {
        self.vaultStore = vaultStore
        self.dekStore = dekStore
        self.prompt = prompt
    }

    public func probe() -> VaultProbe { vaultStore.probe() }

    /// 首次建库：创建 vault + 把 DEK 写进 Keychain + 进入解锁态
    @discardableResult
    public func createVault(masterPassword: String) throws -> Bool {
        let doc = try vaultStore.createFirstVault(masterPassword: masterPassword)
        envelope = try vaultStore.fileStore.readEnvelope()
        let newDEK = try vaultStore.dek(from: envelope!, masterPassword: masterPassword)
        try dekStore.store(newDEK)
        dek = newDEK
        document = doc
        isUnlocked = true
        return true
    }

    @discardableResult
    public func unlockWithBiometrics() async -> UnlockResult {
        guard envelope != nil else { return .failed("vault 未加载") }
        guard dekStore.contains() else { return .needMasterPassword }  // 免认证探测，避免白按指纹
        guard let ctx = await prompt.authenticatedContext(reason: "解锁 Coffer 保险库") else {
            return .cancelled
        }
        do {
            guard let key = try dekStore.retrieve(using: ctx) else {
                return .needMasterPassword
            }
            return try finishUnlock(dek: key)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    public func unlockWithMasterPassword(_ password: String) -> UnlockResult {
        guard let env = envelope else { return .failed("vault 未加载") }
        do {
            let key = try vaultStore.dek(from: env, masterPassword: password)
            return try finishUnlock(dek: key)
        } catch {
            return .wrongPassword  // PBKDF2 解包失败 = 密码不对（GCM 认证失败）
        }
    }

    public func loadEnvelope() {
        envelope = try? vaultStore.fileStore.readEnvelope()
    }

    /// 损坏恢复：用最近备份覆盖 vault 文件并加载其信封。
    /// Keychain 里的 DEK 不动——DEK 从不随保存/备份变化，恢复后指纹解锁依旧可用。
    @discardableResult
    public func restoreFromLatestBackup() -> Bool {
        guard let backup = vaultStore.fileStore.latestBackup() else { return false }
        do {
            try vaultStore.fileStore.restoreFromBackup(1)
            loadEnvelope()
            return true
        } catch {
            return false
        }
    }

    /// 损坏且无备份可救时：放弃所有数据（含 Keychain DEK），回到首次建库
    public func discardVaultAndBackups() {
        let fm = FileManager.default
        let dir = vaultStore.fileStore.directory
        for name in ["vault.vault", "vault.bak1", "vault.bak2", "vault.bak3", "vault.tmp"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        try? dekStore.delete()
        envelope = nil
        isUnlocked = false
        document = nil
        dek = nil
    }

    public func lock() {
        isUnlocked = false
        document = nil
        dek = nil  // best-effort（spec 5.2 如实承认 String/SymmetricKey 无法保证清零）
    }

    /// 持久化当前 document 到磁盘
    public func persist() throws {
        guard let doc = document, let d = dek, let env = envelope else {
            throw NSError(domain: "UnlockService", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "未解锁或缺少必要状态"])
        }
        envelope = try vaultStore.save(doc, dek: d, previous: env)
    }

    /// 更改主密码：重新包装 DEK（文档不重加密）
    public func setMasterPassword(_ newPassword: String) throws {
        guard let d = dek, let env = envelope else {
            throw NSError(domain: "UnlockService", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "未解锁"])
        }
        envelope = try vaultStore.changeMasterPassword(newPassword, dek: d, previous: env)
    }

    private func finishUnlock(dek: SymmetricKey) throws -> UnlockResult {
        loadEnvelope()
        guard let env = envelope else { return .failed("vault 不存在") }
        self.dek = dek
        document = try vaultStore.document(from: env, dek: dek)
        isUnlocked = true
        return .unlocked
    }
}
