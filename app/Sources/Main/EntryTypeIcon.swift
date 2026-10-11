import SwiftUI
import CofferCore

extension EntryType {
    var symbol: String {
        switch self {
        case .login: return "globe"
        case .access: return "building.columns"
        case .apiKey: return "key"
        case .sshKey: return "terminal"
        case .server: return "server.rack"
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
        case .server: return "服务器"
        case .database: return "数据库"
        case .totp: return "验证码"
        case .secureNote: return "安全笔记"
        case .wallet: return "钱包"
        case .unknown: return "未知类型"
        }
    }

    var purpose: String {
        switch self {
        case .login: return "网站与应用的账号、密码和登录地址"
        case .access: return "记录系统入口、网络与访问权限"
        case .apiKey: return "服务 API 密钥与环境变量名"
        case .sshKey: return "单独保管 SSH 私钥"
        case .server: return "SSH 主机、端口、登录密码或私钥"
        case .database: return "数据库连接信息与登录凭证"
        case .totp: return "生成一次性双重验证码"
        case .secureNote: return "加密笔记、恢复码与附件"
        case .wallet: return "Tron USDT 钱包、收款与转账"
        case .unknown: return "保留来自更新版本的内容"
        }
    }
}

struct EntryCreationCategory: Identifiable {
    let title: String
    let types: [EntryType]
    var id: String { title }
    static let all: [Self] = [
        .init(title: "账号与访问", types: [.login, .totp, .access]),
        .init(title: "开发与运维", types: [.server, .database, .apiKey, .sshKey]),
        .init(title: "私密资料与资产", types: [.secureNote, .wallet]),
    ]
}

extension ServerPayload.Authentication {
    var label: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥"
        case .sshAgent: return "本机 SSH agent / 配置"
        }
    }
}
