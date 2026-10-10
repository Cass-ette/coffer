import Foundation
import CryptoKit
import TronKit
import CoreFoundation

public enum TransferValidationError: LocalizedError, Equatable {
    case invalidAddress, invalidAmount, insufficientUSDT, privateKeyMismatch
    case insufficientTRXForFee(neededSun: Int64, haveSun: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Tron 地址或校验位无效"
        case .invalidAmount: return "转账金额必须大于零，且最多六位小数"
        case .insufficientUSDT: return "USDT 余额不足"
        case .privateKeyMismatch: return "钱包凭证派生地址与转出地址不一致，已停止签名"
        case .insufficientTRXForFee(let needed, let have):
            return "TRX 不足以支付预估手续费：需要约 \(TronGridClient.formatUSDT(needed)) TRX，当前 \(TronGridClient.formatUSDT(have)) TRX"
        }
    }
}

public enum BroadcastError: LocalizedError, Equatable {
    case rejected(String)
    case uncertain(String)

    public var errorDescription: String? {
        switch self {
        case .uncertain(let hash):
            return "广播结果未知。请先用交易哈希 \(hash) 在 Tronscan 查询，勿立即重复转账。"
        case .rejected(let code):
            if code.contains("DUPLICATE") { return "重复交易，请先在 Tronscan 核对是否已受理" }
            if code.contains("ENERGY") || code.contains("BANDWIDTH") { return "能量、带宽或 TRX 不足，交易未被节点受理" }
            if code.contains("SIG") { return "签名校验失败，交易未被节点受理" }
            return "节点拒绝交易：\(code)"
        }
    }
}

public struct TronFee: Equatable, Sendable {
    public let energy: Int64
    public let energyPrice: Int64
    public let bandwidthBurned: Int64
    public let bandwidthPrice: Int64
    public let feeSun: Int64

    public init(energy: Int64, energyPrice: Int64, bandwidthBurned: Int64,
                bandwidthPrice: Int64) throws {
        guard energy > 0, energyPrice > 0, bandwidthBurned >= 0, bandwidthPrice > 0 else {
            throw TronGridError.badResponse
        }
        let (energyFee, energyOverflow) = energy.multipliedReportingOverflow(by: energyPrice)
        let (bandwidthFee, bandwidthOverflow) = bandwidthBurned.multipliedReportingOverflow(by: bandwidthPrice)
        let (total, totalOverflow) = energyFee.addingReportingOverflow(bandwidthFee)
        guard !energyOverflow, !bandwidthOverflow, !totalOverflow else { throw TronGridError.badResponse }
        self.energy = energy
        self.energyPrice = energyPrice
        self.bandwidthBurned = bandwidthBurned
        self.bandwidthPrice = bandwidthPrice
        self.feeSun = total
    }
}

public struct TronTransferQuote: Equatable, Sendable {
    public let balances: TronBalances
    public let fee: TronFee
    public init(balances: TronBalances, fee: TronFee) {
        self.balances = balances
        self.fee = fee
    }
}

public struct TransferReceipt: Equatable, Sendable {
    public let txHash: String
    public var tronscanURL: URL { URL(string: "https://tronscan.org/#/transaction/\(txHash)")! }
    public init(txHash: String) { self.txHash = txHash }
}

public final class TronTransferService {
    public static let usdtContractHex = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c"
    private let http: HTTPProviding
    private let headers: [String: String]
    public init(http: HTTPProviding, apiKey: String = "") {
        self.http = http
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = trimmed.isEmpty ? [:] : ["TRON-PRO-API-KEY": trimmed]
    }

    public func validateTransfer(from: String, to: String, usdtSun: Int64) async throws -> TronFee {
        try await quote(from: from, to: to, usdtSun: usdtSun).fee
    }

    public func quote(from: String, to: String, usdtSun: Int64) async throws -> TronTransferQuote {
        try Self.validateInputs(from: from, to: to, amount: usdtSun)
        let balances = try await TronGridClient(http: http, apiKey: headers["TRON-PRO-API-KEY"] ?? "")
            .balances(address: from)
        guard balances.usdtSun >= usdtSun else { throw TransferValidationError.insufficientUSDT }
        let fee = try await estimateFee(from: from, to: to, usdtSun: usdtSun)
        guard balances.trxBalance >= fee.feeSun else {
            throw TransferValidationError.insufficientTRXForFee(neededSun: fee.feeSun, haveSun: balances.trxBalance)
        }
        return TronTransferQuote(balances: balances, fee: fee)
    }

    public func estimateFee(from: String, to: String, usdtSun: Int64) async throws -> TronFee {
        try Self.validateInputs(from: from, to: to, amount: usdtSun)
        let simulation = try await http.post("/wallet/triggerconstantcontract", body: [
            "owner_address": Self.hex41(from)!, "contract_address": Self.usdtContractHex,
            "function_selector": "transfer(address,uint256)",
            "parameter": Self.abiEncode(to: to, amount: usdtSun)!, "visible": false
        ], headers: headers)
        let sim = try Self.jsonObject(simulation)
        guard Self.truth((sim["result"] as? [String: Any])?["result"]),
              let energy = Self.integer(sim["energy_used"]), energy > 0 else {
            throw TronGridError.badResponse
        }
        if let results = sim["constant_result"] as? [String], let result = results.first,
           !result.isEmpty, Int(result, radix: 16) == 0 {
            throw BroadcastError.rejected("CONTRACT_REVERT")
        }

        let paramData = try await http.post("/wallet/getchainparameters", body: [:], headers: headers)
        let params = try Self.jsonObject(paramData)
        guard let rows = params["chainParameter"] as? [[String: Any]],
              let energyPrice = rows.first(where: { $0["key"] as? String == "getEnergyFee" })
                .flatMap({ Self.integer($0["value"]) }),
              let bandwidthPrice = rows.first(where: { $0["key"] as? String == "getTransactionFee" })
                .flatMap({ Self.integer($0["value"]) }),
              energyPrice > 0, bandwidthPrice > 0 else {
            throw TronGridError.badResponse
        }

        let accountData = try await http.post("/wallet/getaccountresource", body: [
            "address": from, "visible": true
        ], headers: headers)
        let account = try Self.jsonObject(accountData)
        guard let freeLimit = Self.integer(account["freeNetLimit"]),
              account["freeNetUsed"] == nil || Self.integer(account["freeNetUsed"]) != nil else {
            throw TronGridError.badResponse
        }
        let freeUsed = Self.integer(account["freeNetUsed"]) ?? 0
        guard (0...1_000_000_000).contains(freeLimit), (0...1_000_000_000).contains(freeUsed) else {
            throw TronGridError.badResponse
        }
        // TRC-20 transfer is about 345 bandwidth points. Stake management is outside this release.
        let free = max(0, freeLimit - freeUsed)
        // TRON requires the free allowance to cover the entire transaction; otherwise all bytes burn TRX.
        let burned: Int64 = free >= 345 ? 0 : 345
        return try TronFee(energy: energy, energyPrice: energyPrice,
                           bandwidthBurned: burned, bandwidthPrice: bandwidthPrice)
    }

    public func sendUSDT(from: String, to: String, usdtSun: Int64,
                         privateKeyHex: String, feeLimitSun: Int64) async throws -> TransferReceipt {
        try await sendUSDT(from: from, to: to, usdtSun: usdtSun, feeLimitSun: feeLimitSun,
                           signingKey: { try TronWalletService().privateKeyData(fromPrivateKey: privateKeyHex) })
    }

    /// Reads the key only after the unsigned transaction has been built and checked.
    /// The caller's provider should fetch it from the unlocked vault after a fresh authentication.
    public func sendUSDT(from: String, to: String, usdtSun: Int64, feeLimitSun: Int64,
                         signingKey: @MainActor () throws -> Data) async throws -> TransferReceipt {
        try Self.validateInputs(from: from, to: to, amount: usdtSun)
        guard feeLimitSun > 0 else { throw TransferValidationError.invalidAmount }
        let builtData = try await http.post("/wallet/triggersmartcontract", body: [
            "owner_address": Self.hex41(from)!, "contract_address": Self.usdtContractHex,
            "function_selector": "transfer(address,uint256)",
            "parameter": Self.abiEncode(to: to, amount: usdtSun)!,
            "fee_limit": feeLimitSun, "visible": false
        ], headers: headers)
        let built = try Self.jsonObject(builtData)
        guard Self.truth((built["result"] as? [String: Any])?["result"]),
              let transaction = built["transaction"] as? [String: Any],
              let hash = transaction["txID"] as? String,
              let hashData = Self.hexData(hash), hashData.count == 32,
              let rawHex = transaction["raw_data_hex"] as? String,
              let rawData = Self.hexData(rawHex), !rawData.isEmpty,
              Data(SHA256.hash(data: rawData)) == hashData,
              Self.matchesTransaction(transaction, from: from, to: to,
                                      amount: usdtSun, feeLimitSun: feeLimitSun),
              let owner = try? Address(address: from),
              let contract = try? Address(address: usdtContract),
              let callData = Self.hexData("a9059cbb" + (Self.abiEncode(to: to, amount: usdtSun) ?? "")),
              TransactionVerifier.matchesTriggerSmartContract(
                  rawData: rawData, owner: owner, contract: contract,
                  callData: callData, feeLimit: feeLimitSun) else {
            throw TronGridError.badResponse
        }

        try Task.checkCancellation()
        var key = try await signingKey()
        defer { key.resetBytes(in: 0..<key.count) }
        guard TronWalletService().isValidPrivateKeyData(key) else { throw TronWalletError.badPrivateKey }
        guard try Signer.address(privateKey: key).base58 == from else {
            throw TransferValidationError.privateKeyMismatch
        }
        let signature = try Signer.sign(hash: hashData, privateKey: key)
        guard signature.count == 65 else { throw TronGridError.badResponse }
        key.resetBytes(in: 0..<key.count)

        var body = transaction
        body["signature"] = [Self.hexString(signature)]
        try Task.checkCancellation()
        let broadcastData: Data
        do {
            broadcastData = try await http.post("/wallet/broadcasttransaction", body: body, headers: headers)
        } catch {
            throw BroadcastError.uncertain(hash)
        }
        // An absent or malformed acknowledgment is also uncertain: never invite a blind retry.
        guard let response = try? Self.jsonObject(broadcastData) else {
            throw BroadcastError.uncertain(hash)
        }
        if Self.truth(response["result"]) { return TransferReceipt(txHash: hash) }
        if let code = response["code"] as? String { throw BroadcastError.rejected(code) }
        if let code = response["result"] as? String { throw BroadcastError.rejected(code) }
        if response["result"] != nil { throw BroadcastError.rejected("NODE_REJECTED") }
        throw BroadcastError.uncertain(hash)
    }

    private static func validateInputs(from: String, to: String, amount: Int64) throws {
        let wallet = TronWalletService()
        guard wallet.validateAddress(from), wallet.validateAddress(to) else {
            throw TransferValidationError.invalidAddress
        }
        guard amount > 0 else { throw TransferValidationError.invalidAmount }
    }

    private static func matchesTransaction(_ transaction: [String: Any], from: String, to: String,
                                            amount: Int64, feeLimitSun: Int64) -> Bool {
        guard let raw = transaction["raw_data"] as? [String: Any],
              integer(raw["fee_limit"]) == feeLimitSun,
              let contracts = raw["contract"] as? [[String: Any]], contracts.count == 1,
              contracts[0]["type"] as? String == "TriggerSmartContract",
              let parameter = contracts[0]["parameter"] as? [String: Any],
              let value = parameter["value"] as? [String: Any],
              (value["owner_address"] as? String)?.lowercased() == hex41(from),
              (value["contract_address"] as? String)?.lowercased() == usdtContractHex,
              (value["data"] as? String)?.lowercased() == "a9059cbb" + (abiEncode(to: to, amount: amount) ?? ""),
              (integer(value["call_value"]) ?? 0) == 0,
              (integer(value["call_token_value"]) ?? 0) == 0,
              (integer(value["token_id"]) ?? 0) == 0 else { return false }
        return true
    }

    static func hex41(_ address: String) -> String? {
        guard let parsed = try? Address(address: address) else { return nil }
        return hexString(parsed.raw)
    }

    static func abiEncode(to address: String, amount: Int64) -> String? {
        guard amount > 0, let parsed = try? Address(address: address) else { return nil }
        let addressHex = hexString(parsed.nonPrefixed)
        let amountHex = String(amount, radix: 16)
        return String(repeating: "0", count: 24) + addressHex
            + String(repeating: "0", count: 64 - amountHex.count) + amountHex
    }

    private static func hexData(_ text: String) -> Data? {
        guard text.utf8.count.isMultiple(of: 2),
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        var data = Data()
        let bytes = Array(text.utf8)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[index...index+1], as: UTF8.self), radix: 16) else { return nil }
            data.append(value)
        }
        return data
    }
    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TronGridError.badResponse
        }
        return json
    }
    private static func truth(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }
}
