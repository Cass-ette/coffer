import Foundation
import Combine
import ServiceManagement

/// 启动前就要可读的设置（spec §6.3 启动前层）：全局快捷键、登录时启动。
/// 安全偏好（锁定时长等）在加密库内（VaultDocument.EncryptedSettings）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum HotkeyModifier: String, Codable, CaseIterable {
        case command, option, control, shift
    }

    struct Hotkey: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: [HotkeyModifier]
        /// 默认 ⌥Space（kVK_Space = 49）
        static let defaultHotkey = Hotkey(keyCode: 49, modifiers: [.option])
    }

    private let defaults: UserDefaults

    @Published var hotkey: Hotkey {
        didSet { save(hotkey, for: Keys.hotkey) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            save(launchAtLogin, for: Keys.launchAtLogin)
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = Self.load(Keys.hotkey, from: defaults) ?? .defaultHotkey
        launchAtLogin = Self.load(Keys.launchAtLogin, from: defaults) ?? true  // 成功标准 1 的前提，默认开
    }

    private enum Keys {
        static let hotkey = "coffer.hotkey"
        static let launchAtLogin = "coffer.launchAtLogin"
    }

    private func save<T: Codable>(_ value: T, for key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Codable>(_ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

enum LaunchAtLogin {
    static func set(_ enabled: Bool) {
        // SMAppService 需要打包后的 app；开发裸跑时静默失败属预期
        let service = SMAppService.mainApp
        if enabled {
            try? service.register()
        } else {
            try? service.unregister()
        }
    }
    static func isEnabled() -> Bool { SMAppService.mainApp.status == .enabled }
}
