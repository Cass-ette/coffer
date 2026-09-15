import Foundation
import CryptoKit
import CommonCrypto

public enum VaultCrypto {
    public static let pbkdf2Iterations = 600_000
    public static let saltLength = 16

    public static func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return data
    }

    public static func pbkdf2(password: String, salt: Data,
                              iterations: Int = pbkdf2Iterations, length: Int = 32) -> Data {
        precondition(!password.isEmpty, "主密码不能为空")
        var derived = Data(repeating: 0, count: length)
        let pw = Data(password.utf8)
        let status = derived.withUnsafeMutableBytes { dPtr -> OSStatus in
            salt.withUnsafeBytes { sPtr -> OSStatus in
                pw.withUnsafeBytes { pPtr -> OSStatus in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pPtr.bindMemory(to: Int8.self).baseAddress!, pw.count,
                        sPtr.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(max(iterations, 1)),
                        dPtr.bindMemory(to: UInt8.self).baseAddress!, length
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    public static func generateDEK() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// 用 KEK（主密码派生密钥）包装 DEK，产出 AES-GCM combined（nonce+ct+tag）
    public static func wrap(_ dek: SymmetricKey, with kek: Data) throws -> Data {
        let dekData = dek.withUnsafeBytes { Data($0) }
        return try AES.GCM.seal(dekData, using: SymmetricKey(data: kek)).combined!
    }

    public static func unwrap(_ wrapped: Data, with kek: Data) throws -> SymmetricKey {
        let box = try AES.GCM.SealedBox(combined: wrapped)
        return SymmetricKey(data: try AES.GCM.open(box, using: SymmetricKey(data: kek)))
    }

    public static func encrypt(_ plaintext: Data, with dek: SymmetricKey) throws -> Data {
        try AES.GCM.seal(plaintext, using: dek).combined!
    }

    public static func decrypt(_ combined: Data, with dek: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: dek)
    }
}
