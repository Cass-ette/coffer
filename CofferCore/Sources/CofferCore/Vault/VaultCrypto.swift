import Foundation
import CryptoKit
import CommonCrypto

public enum CryptoError: Error, Equatable {
    case randomGenerationFailed(OSStatus)
    case emptyPassword
    case keyDerivationFailed(OSStatus)
    case sealFailed
    case invalidIterationCount(Int)
    case invalidParameter
}

public enum VaultCrypto {
    public static let pbkdf2Iterations = 600_000
    public static let saltLength = 16

    public static func randomData(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw CryptoError.randomGenerationFailed(status)
        }
        return data
    }

    public static func pbkdf2(password: String, salt: Data,
                              iterations: Int = pbkdf2Iterations, length: Int = 32) throws -> Data {
        guard !password.isEmpty else {
            throw CryptoError.emptyPassword
        }
        guard iterations > 0 else {
            throw CryptoError.invalidIterationCount(iterations)
        }

        var derived = Data(repeating: 0, count: length)

        // Use utf8.withContiguousStorageIfAvailable to avoid allocating intermediate Data for password
        // This reduces the window where password bytes persist in memory
        let status: OSStatus = derived.withUnsafeMutableBytes { dPtr -> OSStatus in
            salt.withUnsafeBytes { sPtr -> OSStatus in
                password.utf8.withContiguousStorageIfAvailable { pBuffer -> OSStatus in
                    guard let derivedBase = dPtr.bindMemory(to: UInt8.self).baseAddress else {
                        return OSStatus(errSecParam)
                    }
                    guard let saltBase = sPtr.bindMemory(to: UInt8.self).baseAddress else {
                        return OSStatus(errSecParam)
                    }
                    guard let pwBase = pBuffer.baseAddress else {
                        return OSStatus(errSecParam)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBase, pBuffer.count,
                        saltBase, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBase, length
                    )
                } ?? {
                    // Fallback for non-contiguous UTF-8 (rare edge case: grapheme clusters, extended characters)
                    // Note: This allocates Data temporarily; password bytes may persist in memory until GC
                    let pw = Data(password.utf8)
                    return pw.withUnsafeBytes { pPtr -> OSStatus in
                        guard let derivedBase = dPtr.bindMemory(to: UInt8.self).baseAddress else {
                            return OSStatus(errSecParam)
                        }
                        guard let saltBase = sPtr.bindMemory(to: UInt8.self).baseAddress else {
                            return OSStatus(errSecParam)
                        }
                        guard let pwBase = pPtr.bindMemory(to: Int8.self).baseAddress else {
                            return OSStatus(errSecParam)
                        }
                        return CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            pwBase, pw.count,
                            saltBase, salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            UInt32(iterations),
                            derivedBase, length
                        )
                    }
                }()
            }
        }

        guard status == kCCSuccess else {
            if status == OSStatus(errSecParam) {
                throw CryptoError.invalidParameter
            }
            throw CryptoError.keyDerivationFailed(status)
        }
        return derived
    }

    public static func generateDEK() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// 用 KEK（主密码派生密钥）包装 DEK，产出 AES-GCM combined（nonce+ct+tag）
    public static func wrap(_ dek: SymmetricKey, with kek: Data) throws -> Data {
        let dekData = dek.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(dekData, using: SymmetricKey(data: kek))
        guard let combined = sealed.combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    public static func unwrap(_ wrapped: Data, with kek: Data) throws -> SymmetricKey {
        let box = try AES.GCM.SealedBox(combined: wrapped)
        return SymmetricKey(data: try AES.GCM.open(box, using: SymmetricKey(data: kek)))
    }

    public static func encrypt(_ plaintext: Data, with dek: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: dek)
        guard let combined = sealed.combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    public static func decrypt(_ combined: Data, with dek: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: dek)
    }
}
