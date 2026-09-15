import Foundation

public struct VaultDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [Entry]
    public var groups: [Group]
    public var settings: EncryptedSettings

    public struct EncryptedSettings: Codable, Equatable, Sendable {
        public var autoLockSeconds: Int      // 0 = 不自动锁定
        public var clipboardClearSeconds: Int // 0 = 不清空
        public init(autoLockSeconds: Int = 300, clipboardClearSeconds: Int = 45) {
            self.autoLockSeconds = autoLockSeconds
            self.clipboardClearSeconds = clipboardClearSeconds
        }
    }

    public static func empty() -> VaultDocument {
        VaultDocument(
            schemaVersion: 1,
            entries: [],
            groups: [
                Group(name: "内网系统", symbolName: "network"),
                Group(name: "校内服务", symbolName: "graduationcap"),
                Group(name: "开发密钥", symbolName: "chevron.left.forwardslash.chevron.right"),
                Group(name: "个人", symbolName: "person"),
            ],
            settings: EncryptedSettings()
        )
    }

    public init(schemaVersion: Int, entries: [Entry], groups: [Group], settings: EncryptedSettings) {
        self.schemaVersion = schemaVersion; self.entries = entries
        self.groups = groups; self.settings = settings
    }
}
