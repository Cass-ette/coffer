import Foundation
import CofferCore

struct CopyTarget {
    let label: String
    let value: String
}

enum CopyTargets {
    static func targets(for entry: Entry, at date: Date = Date()) -> [CopyTarget] {
        switch entry.payload {
        case .login(let p):
            var t: [CopyTarget] = []
            if !p.username.isEmpty { t.append(CopyTarget(label: "用户名", value: p.username)) }
            if !p.password.isEmpty { t.append(CopyTarget(label: "密码", value: p.password)) }
            if let url = p.urls.first { t.append(CopyTarget(label: "地址", value: url)) }
            return t
        case .access(let p):
            var t: [CopyTarget] = []
            if let a = p.addresses.first { t.append(CopyTarget(label: "地址", value: a)) }
            return t
        case .apiKey(let p):
            var t: [CopyTarget] = []
            if !p.secret.isEmpty { t.append(CopyTarget(label: "密钥", value: p.secret)) }
            if !p.envPrefix.isEmpty { t.append(CopyTarget(label: "环境变量", value: p.envPrefix)) }
            return t
        case .sshKey(let p):
            var t: [CopyTarget] = []
            if !p.user.isEmpty { t.append(CopyTarget(label: "用户", value: p.user)) }
            if !p.privateKey.isEmpty { t.append(CopyTarget(label: "私钥", value: p.privateKey)) }
            return t
        case .totp(let p):
            guard let secret = try? Base32.decode(p.secretBase32) else { return [] }
            let cfg = TOTPConfig(secret: secret,
                                 algorithm: TOTPAlgorithm(rawValue: p.algorithm) ?? .SHA1,
                                 digits: p.digits, period: p.period)
            return [CopyTarget(label: "验证码",
                               value: TOTPGenerator(config: cfg).code(at: date)),
                    CopyTarget(label: "种子", value: p.secretBase32)]
        case .secureNote:
            return []
        }
    }

    static func firstURL(of entry: Entry) -> URL? {
        switch entry.payload {
        case .login(let p): return p.urls.first.flatMap(URL.init(string:))
        case .access(let p): return p.addresses.first.flatMap(URL.init(string:))
        default: return nil
        }
    }
}
