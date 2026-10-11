import Foundation

public struct ServerPayload: Codable, Hashable, Sendable {
    public enum Authentication: String, Codable, CaseIterable, Sendable {
        case password, privateKey, sshAgent
    }
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    public var password: String
    public var privateKey: String
    public var passphrase: String
    public var networkLocation: String

    public init(host: String, port: Int = 22, username: String, authentication: Authentication = .password,
                password: String = "", privateKey: String = "", passphrase: String = "", networkLocation: String = "公网") {
        self.host = host; self.port = port; self.username = username; self.authentication = authentication
        self.password = password; self.privateKey = privateKey; self.passphrase = passphrase
        self.networkLocation = networkLocation
    }

    public var connectionError: String? {
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy(hostCharacters.contains),
              host.contains(where: { $0.isLetter || $0.isNumber }) else {
            return "主机请填写域名或 IP，不要包含协议、路径、空格或命令"
        }
        guard (1...65535).contains(port) else { return "SSH 端口需为 1–65535，默认 22" }
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
        guard !username.isEmpty, username.count <= 256, username.unicodeScalars.allSatisfy(userCharacters.contains) else {
            return "请填写 SSH 用户名，仅使用字母、数字、点、下划线、连字符或 @"
        }
        return nil
    }

    /// A user-copyable command only. Never contains a password, key, or passphrase and never executes.
    public var sshCommand: String? {
        guard connectionError == nil else { return nil }
        return "ssh -p \(port) -l '\(username)' -- '\(host)'"
    }
}
