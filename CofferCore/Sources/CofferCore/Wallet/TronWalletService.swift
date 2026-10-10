import Foundation
import Security
import TronKit
import HdWalletKit

/// Stateless Tron derivation through the vendored library's public API.
public final class TronWalletService {
    public static let derivationPath = "m/44'/195'/0'/0/0"
    public init() {}

    public func validateAddress(_ address: String) -> Bool {
        guard address.utf8.count == 34, address.hasPrefix("T"),
              let parsed = try? Address(address: address) else { return false }
        return parsed.base58 == address
    }

    public static func normalizedMnemonic(_ mnemonic: String) -> String {
        mnemonic.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    public func address(fromMnemonic mnemonic: String) throws -> String {
        var key = try privateKeyData(fromMnemonic: mnemonic)
        defer { key.resetBytes(in: 0..<key.count) }
        return try Signer.address(privateKey: key).base58
    }

    public func privateKey(fromMnemonic mnemonic: String) throws -> String {
        var key = try privateKeyData(fromMnemonic: mnemonic)
        defer { key.resetBytes(in: 0..<key.count) }
        return key.map { String(format: "%02x", $0) }.joined()
    }

    public func privateKeyData(fromMnemonic mnemonic: String) throws -> Data {
        let words = Self.normalizedMnemonic(mnemonic).split(separator: " ").map(String.init)
        guard words.count == 12 || words.count == 24 else { throw TronWalletError.badMnemonic }
        do { try Mnemonic.validate(words: words) }
        catch { throw TronWalletError.badMnemonic }
        guard var seed = Mnemonic.seed(mnemonic: words) else { throw TronWalletError.badMnemonic }
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try Signer.privateKey(seed: seed)
    }

    public func privateKeyData(fromPrivateKey hex: String) throws -> Data {
        let normalized = hex.lowercased()
        // Signer.privateKey(string:) checks length only. Reject invalid scalars
        // before the upstream public-key routine (which assumes a valid scalar).
        let order = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              normalized != String(repeating: "0", count: 64), normalized < order else {
            throw TronWalletError.badPrivateKey
        }
        let key = try Signer.privateKey(string: normalized)
        guard isValidPrivateKeyData(key) else { throw TronWalletError.badPrivateKey }
        return key
    }

    /// Check a secp256k1 scalar before passing Data to TronKit's public-key routine.
    public func isValidPrivateKeyData(_ key: Data) -> Bool {
        let order = Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                          0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
                          0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
                          0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41])
        return key.count == 32 && key.contains(where: { $0 != 0 })
            && key.lexicographicallyPrecedes(order)
    }

    public func address(fromPrivateKey hex: String) throws -> String {
        var key = try privateKeyData(fromPrivateKey: hex)
        defer { key.resetBytes(in: 0..<key.count) }
        return try Signer.address(privateKey: key).base58
    }

    public func generateMnemonic(entropy: Data? = nil) throws -> [String] {
        if let entropy {
            guard entropy.count == 16 else { throw TronWalletError.badEntropy }
            return Mnemonic.generate(entropy: entropy)
        }
        var bytes = Data(count: 16)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw TronWalletError.randomFailed }
        return Mnemonic.generate(entropy: bytes)
    }
}

public enum TronWalletError: LocalizedError, Equatable {
    case badMnemonic, badPrivateKey, badEntropy, randomFailed

    public var errorDescription: String? {
        switch self {
        case .badMnemonic: return "助记词无效：需要 12 或 24 个有效单词且校验位正确"
        case .badPrivateKey: return "私钥无效：需要有效的 64 位十六进制私钥"
        case .badEntropy: return "生成 12 词助记词需要 16 字节熵"
        case .randomFailed: return "系统安全随机数生成失败，请重试"
        }
    }
}
