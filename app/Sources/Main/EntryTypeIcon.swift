import SwiftUI
import CofferCore

extension EntryType {
    var symbol: String {
        switch self {
        case .login: return "globe"
        case .access: return "building.columns"
        case .apiKey: return "key"
        case .sshKey: return "terminal"
        case .database: return "cylinder"
        case .totp: return "timer"
        case .secureNote: return "note.text"
        case .wallet: return "bitcoinsign.circle"
        case .unknown: return "questionmark.square"
        }
    }

    var label: String {
        switch self {
        case .login: return "登录"
        case .access: return "权限"
        case .apiKey: return "API 密钥"
        case .sshKey: return "SSH 密钥"
        case .database: return "数据库"
        case .totp: return "验证码"
        case .secureNote: return "安全笔记"
        case .wallet: return "钱包"
        case .unknown: return "未知类型"
        }
    }
}
