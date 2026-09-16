import Foundation
import CryptoKit

public enum TOTPError: LocalizedError, Sendable {
    case invalidBase32Character(Character)
    case invalidOTPAuthURI
    case missingSecret
    public var errorDescription: String? {
        switch self {
        case .invalidBase32Character(let c): return "非法 Base32 字符: \(c)"
        case .invalidOTPAuthURI: return "不是合法的 otpauth:// URI"
        case .missingSecret: return "缺少 secret"
        }
    }
}

public enum TOTPAlgorithm: String, Hashable, Sendable {
    case SHA1, SHA256, SHA512
}

public struct TOTPConfig: Hashable, Sendable {
    public var secret: Data
    public var algorithm: TOTPAlgorithm
    public var digits: Int
    public var period: Int
    public init(secret: Data, algorithm: TOTPAlgorithm, digits: Int, period: Int) {
        self.secret = secret; self.algorithm = algorithm; self.digits = digits; self.period = period
    }
}

public enum Base32 {
    public static func decode(_ input: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let cleaned = input.uppercased().filter { $0.isLetter || $0.isNumber }
        var bits = 0
        var value = 0
        var out = [UInt8]()
        for ch in cleaned {
            guard let idx = alphabet.firstIndex(of: ch) else {
                throw TOTPError.invalidBase32Character(ch)
            }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return Data(out)
    }
}

public struct TOTPGenerator: Sendable {
    public let config: TOTPConfig
    public init(config: TOTPConfig) { self.config = config }

    public func code(at date: Date = Date()) -> String {
        let counter = UInt64(date.timeIntervalSince1970 / Double(config.period))
        let mac = hmac(counter: counter)
        // RFC 4226 §5.3 动态截断：取低 4 位偏移处的 4 字节大端窗口
        let offset = Int(mac[mac.count - 1] & 0x0F)
        var truncated = (UInt32(mac[offset]) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        truncated &= 0x7FFF_FFFF
        let code = UInt64(truncated % UInt32(pow(10, Float(config.digits))))
        return String(format: "%0\(config.digits)llu", code)
    }

    public func remainingSeconds(at date: Date = Date()) -> Int {
        let t = Int(date.timeIntervalSince1970)
        let period = config.period
        return period - (t % period)
    }

    private func hmac(counter: UInt64) -> [UInt8] {
        var msg = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { msg[i] = UInt8((counter >> (56 - 8 * i)) & 0xFF) }
        let key = SymmetricKey(data: config.secret)
        switch config.algorithm {
        case .SHA1:
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(msg), using: key))
        case .SHA256:
            return Array(HMAC<SHA256>.authenticationCode(for: Data(msg), using: key))
        case .SHA512:
            return Array(HMAC<SHA512>.authenticationCode(for: Data(msg), using: key))
        }
    }
}

public enum OTPAuthParser {
    public static func parse(_ uri: String) throws -> TOTPConfig {
        guard let url = URL(string: uri),
              url.scheme?.lowercased() == "otpauth",
              url.host?.lowercased() == "totp",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TOTPError.invalidOTPAuthURI
        }
        let query = comps.queryItems ?? []
        func param(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value
        }
        guard let secretStr = param("secret"), let secret = try? Base32.decode(secretStr), !secret.isEmpty else {
            throw TOTPError.missingSecret
        }
        let algo = TOTPAlgorithm(rawValue: (param("algorithm") ?? "SHA1").uppercased()) ?? .SHA1
        let digits = Int(param("digits") ?? "") ?? 6
        let period = Int(param("period") ?? "") ?? 30
        return TOTPConfig(secret: secret, algorithm: algo, digits: digits, period: period)
    }
}
