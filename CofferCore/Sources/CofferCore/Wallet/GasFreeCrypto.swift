import Foundation
import TronKit
import HsCryptoKit

public enum GasFreeError: LocalizedError, Equatable {
    case invalidResponse, credentials, authentication, unavailable, insufficientBalance, quoteChanged, pending, storage
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GasFree 返回的数据未通过核对，请刷新或稍后重试"
        case .credentials: return "请先在设置中配置官方 GasFree API Key 和 API Secret"
        case .authentication: return "GasFree 凭证验证失败，请核对 API Key、Secret、主网权限及系统时间"
        case .unavailable: return "GasFree 当前不允许提交，请等待已有交易完成后刷新"
        case .insufficientBalance: return "GasFree 独立钱包可用 USDT 不足以支付转账金额和手续费"
        case .quoteChanged: return "GasFree 报价过期或费用、账户状态已变化，请重新查看并确认"
        case .pending: return "GasFree 上一笔授权仍待确认，请先查询结果，不要重复付款"
        case .storage: return "GasFree 转账记录无法读取或已被其他窗口更新，已暂停新付款"
        case .http(let code): return "GasFree 请求失败（HTTP \(code)），请稍后重试"
        }
    }
}

/// Fixed PermitTransfer schema. No arbitrary contract calls or typed-data signing.
public struct GasFreePermit: Codable, Equatable, Sendable {
    public let owner: String
    public let receiver: String
    public let provider: String
    public let value: Int64
    public let maxFee: Int64
    public let deadline: Int64
    public let nonce: Int64
}

public enum GasFreeCrypto {
    public static let controller = "TFFAMQLZybALaLb4uxHA9RBE7pxhUAjF3U"
    static let beacon = "TSP9UW6FQhT76XD2jWA6ipGMx3yGbjDffP"
    static let chainID: Int64 = 728126428

    public static func address(owner: String) throws -> String {
        let salt = try addressWord(owner)
        let initialize = Crypto.sha3(Data("initialize(address)".utf8)).prefix(4) + salt
        // ABI.encode(address beacon, bytes initializeData): 2-word head + length + padded bytes.
        let arguments = try addressWord(beacon) + word(64) + word(36) + initialize + Data(repeating: 0, count: 28)
        let bytecodeHash = Crypto.sha3(creationCode + arguments)
        let payload = try Data([0x41]) + Address(address: controller).nonPrefixed + salt + bytecodeHash
        return try Address(raw: Data(Crypto.sha3(payload).suffix(20))).base58
    }

    static func hash(_ permit: GasFreePermit, token: String = usdtContract,
                     chainID: Int64 = chainID, controller: String = controller) throws -> Data {
        guard permit.value > 0, permit.maxFee >= 0, permit.deadline > 0, permit.nonce >= 0 else {
            throw GasFreeError.invalidResponse
        }
        let domainType = Crypto.sha3(Data("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8))
        let domain = try domainType + Crypto.sha3(Data("GasFreeController".utf8))
            + Crypto.sha3(Data("V1.0.0".utf8)) + word(chainID) + addressWord(controller)
        let typeHash = Crypto.sha3(Data("PermitTransfer(address token,address serviceProvider,address user,address receiver,uint256 value,uint256 maxFee,uint256 deadline,uint256 version,uint256 nonce)".utf8))
        let addresses = try addressWord(token) + addressWord(permit.provider) + addressWord(permit.owner) + addressWord(permit.receiver)
        let values = word(permit.value) + word(permit.maxFee) + word(permit.deadline) + word(1) + word(permit.nonce)
        return Crypto.sha3(Data([0x19, 0x01]) + Crypto.sha3(domain) + Crypto.sha3(typeHash + addresses + values))
    }

    static func sign(_ permit: GasFreePermit, key: Data) throws -> Data {
        guard TronWalletService().isValidPrivateKeyData(key),
              try Signer.address(privateKey: key).base58 == permit.owner else {
            throw TransferValidationError.privateKeyMismatch
        }
        var signature = try Signer.sign(hash: hash(permit), privateKey: key)
        guard signature.count == 65, signature[64] <= 1 else { throw GasFreeError.invalidResponse }
        signature[64] += 27
        return signature
    }

    static func addressWord(_ address: String) throws -> Data {
        guard TronWalletService().validateAddress(address) else { throw TronGridError.invalidAddress }
        return try Data(repeating: 0, count: 12) + Address(address: address).nonPrefixed
    }
    static func word(_ value: Int64) -> Data {
        var bigEndian = UInt64(value).bigEndian
        return Data(repeating: 0, count: 24) + withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
