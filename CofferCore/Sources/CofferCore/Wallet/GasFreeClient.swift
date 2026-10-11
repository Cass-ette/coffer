import Foundation
import CryptoKit

public struct GasFreeCredentials: Codable, Equatable {
    let key: String
    let secret: String
    public init(key: String, secret: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty, key.utf8.count <= 512, secret.utf8.count <= 1024,
              key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }),
              secret.utf8.allSatisfy({ (33...126).contains($0) }) else { throw GasFreeError.credentials }
        self.key = key; self.secret = secret
    }
}

struct GasFreeToken: Equatable {
    let activation: Int64
    let transfer: Int64
}

public struct GasFreeProvider: Equatable, Sendable {
    public let address: String
    public let name: String
    let minDeadline: Int64
    let maxDeadline: Int64
    let defaultDeadline: Int64
}

struct GasFreeAccount {
    let owner: String
    let address: String
    let active: Bool
    let nonce: Int64
    let allowSubmit: Bool
    let fees: GasFreeToken?
    let frozen: Int64
}

public struct GasFreeSnapshot: Equatable, Sendable {
    public let owner: String
    public let address: String
    public let active: Bool
    public let nonce: Int64
    public let allowSubmit: Bool
    public let balance: Int64
    public let frozen: Int64
    public let activationFee: Int64
    public let transferFee: Int64
    public let provider: GasFreeProvider
    public var available: Int64 { max(0, balance - frozen) }
}

public struct GasFreeQuote: Equatable, Sendable {
    public let snapshot: GasFreeSnapshot
    public let receiver: String
    public let value: Int64
    public let maxFee: Int64
    public let total: Int64
    public let quotedAt: Date
    public func isFresh(at now: Date = Date()) -> Bool { (0..<90).contains(now.timeIntervalSince(quotedAt)) }
}

/// Dedicated host and HMAC scope; never shares the TronGrid credential or retries a submit.
public final class GasFreeClient {
    private let credentials: GasFreeCredentials
    private let http: HTTPProviding
    private let now: () -> Date
    public init(credentials: GasFreeCredentials,
                http: HTTPProviding = URLSessionHTTP(base: URL(string: "https://open.gasfree.io")!),
                now: @escaping () -> Date = Date.init) {
        self.credentials = credentials; self.http = http; self.now = now
    }
    public func verifyCredentials() async throws {
        _ = try await token()
        _ = try await providers()
    }
    func request(_ suffix: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let path = "/tron/api/v1" + suffix
        let timestamp = String(Int64(now().timeIntervalSince1970))
        let method = body == nil ? "GET" : "POST"
        let signature = HMAC<SHA256>.authenticationCode(for: Data((method + path + timestamp).utf8),
                                                       using: SymmetricKey(data: Data(credentials.secret.utf8)))
        let headers = ["Timestamp": timestamp,
                       "Authorization": "ApiKey \(credentials.key):\(Data(signature).base64EncodedString())",
                       "Cache-Control": "no-cache"]
        let data: Data
        do {
            if let body { data = try await http.post(path, body: body, headers: headers) }
            else { data = try await http.get(path, headers: headers) }
        } catch TronGridError.http(let code) {
            if code == 401 || code == 403 { throw GasFreeError.authentication }
            throw GasFreeError.http(code)
        }
        guard let object = try? WalletJSON.object(data), let code = WalletJSON.integer(object["code"]) else {
            throw GasFreeError.invalidResponse
        }
        if code == 401 || code == 403 { throw GasFreeError.authentication }
        guard code == 200, let result = object["data"] as? [String: Any] else { throw GasFreeError.invalidResponse }
        return result
    }
    func token() async throws -> GasFreeToken {
        let data = try await request("/config/token/all")
        guard let tokens = data["tokens"] as? [[String: Any]] else { throw GasFreeError.invalidResponse }
        let matches = tokens.filter { $0["tokenAddress"] as? String == usdtContract }
        guard matches.count == 1, let token = matches.first,
              WalletJSON.bool(token["supported"]) == true, WalletJSON.integer(token["decimal"]) == 6 else {
            throw GasFreeError.invalidResponse
        }
        return try GasFreeToken(activation: GasFreeJSON.amount(token["activateFee"]), transfer: GasFreeJSON.amount(token["transferFee"]))
    }
    func providers() async throws -> [GasFreeProvider] {
        let data = try await request("/config/provider/all")
        guard let rows = data["providers"] as? [[String: Any]], !rows.isEmpty else { throw GasFreeError.unavailable }
        let result: [GasFreeProvider] = try rows.map { row in
            guard let address = row["address"] as? String, TronWalletService().validateAddress(address),
                  let name = row["name"] as? String, !name.isEmpty, name.count <= 120,
                  let config = row["config"] as? [String: Any] else { throw GasFreeError.invalidResponse }
            let minimum = try GasFreeJSON.amount(config["minDeadlineDuration"])
            let maximum = try GasFreeJSON.amount(config["maxDeadlineDuration"])
            let preferred = try GasFreeJSON.amount(config["defaultDeadlineDuration"])
            guard try GasFreeJSON.amount(config["maxPendingTransfer"]) >= 1,
                  minimum > 0, minimum <= preferred, preferred <= maximum, maximum <= 86400 else {
                throw GasFreeError.invalidResponse
            }
            return GasFreeProvider(address: address, name: name, minDeadline: minimum, maxDeadline: maximum, defaultDeadline: preferred)
        }
        guard Set(result.map(\.address)).count == result.count else { throw GasFreeError.invalidResponse }
        return result.sorted { $0.address < $1.address }
    }
    func account(owner: String) async throws -> GasFreeAccount {
        let expected = try GasFreeCrypto.address(owner: owner)
        let data = try await request("/address/" + owner)
        guard data["accountAddress"] as? String == owner, data["gasFreeAddress"] as? String == expected,
              let active = WalletJSON.bool(data["active"]),
              let allowSubmit = WalletJSON.bool(data["allow_submit"] ?? data["allowSubmit"]),
              let assets = data["assets"] as? [[String: Any]] else { throw GasFreeError.invalidResponse }
        if data["allow_submit"] != nil && data["allowSubmit"] != nil {
            guard WalletJSON.bool(data["allowSubmit"]) == allowSubmit else { throw GasFreeError.invalidResponse }
        }
        let nonce = try GasFreeJSON.amount(data["nonce"])
        let matches = assets.filter { $0["tokenAddress"] as? String == usdtContract }
        let fees: GasFreeToken?
        let frozen: Int64
        if matches.isEmpty && !active && nonce == 0 {
            fees = nil; frozen = 0
        } else {
            guard matches.count == 1, let asset = matches.first, WalletJSON.integer(asset["decimal"]) == 6 else {
                throw GasFreeError.invalidResponse
            }
            fees = try GasFreeToken(activation: GasFreeJSON.amount(asset["activateFee"]), transfer: GasFreeJSON.amount(asset["transferFee"]))
            frozen = try GasFreeJSON.amount(asset["frozen"])
        }
        return GasFreeAccount(owner: owner, address: expected, active: active, nonce: nonce,
                              allowSubmit: allowSubmit, fees: fees, frozen: frozen)
    }
}

enum GasFreeJSON {
    static func amount(_ value: Any?) throws -> Int64 {
        if let number = WalletJSON.integer(value), number >= 0 { return number }
        if let text = value as? String, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
           let number = Int64(text) { return number }
        throw GasFreeError.invalidResponse
    }
}

public final class GasFreeService {
    let client: GasFreeClient
    let chain: HTTPProviding
    let chainKey: String
    public init(client: GasFreeClient, chain: HTTPProviding = URLSessionHTTP(), tronGridKey: String = "") {
        self.client = client; self.chain = chain; self.chainKey = tronGridKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func snapshot(owner: String) async throws -> GasFreeSnapshot {
        let token = try await client.token()
        let providers = try await client.providers()
        let account = try await client.account(owner: owner)
        // Do not silently pick between inconsistent configuration and address-specific fees.
        guard account.fees == nil || account.fees == token else { throw GasFreeError.quoteChanged }
        let balances = try await TronGridClient(http: chain, apiKey: chainKey).balances(address: account.address)
        return GasFreeSnapshot(owner: owner, address: account.address, active: account.active, nonce: account.nonce,
            allowSubmit: account.allowSubmit, balance: balances.usdtSun, frozen: account.frozen,
            activationFee: account.active ? 0 : token.activation, transferFee: token.transfer, provider: providers[0])
    }
    public func quote(owner: String, receiver: String, value: Int64, now: Date = Date()) async throws -> GasFreeQuote {
        guard TronWalletService().validateAddress(receiver) else { throw TronGridError.invalidAddress }
        guard value > 0 else { throw TransferValidationError.invalidAmount }
        let snapshot = try await snapshot(owner: owner)
        guard receiver != snapshot.address else { throw TransferValidationError.invalidAddress }
        guard snapshot.allowSubmit else { throw GasFreeError.unavailable }
        let maxFee = try WalletJSON.add(snapshot.activationFee, snapshot.transferFee)
        let total = try WalletJSON.add(value, maxFee)
        guard snapshot.available >= total else { throw GasFreeError.insufficientBalance }
        return GasFreeQuote(snapshot: snapshot, receiver: receiver, value: value, maxFee: maxFee, total: total, quotedAt: now)
    }
}
