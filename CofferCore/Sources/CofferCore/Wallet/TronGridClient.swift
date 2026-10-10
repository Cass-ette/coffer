import Foundation
import TronKit

public protocol HTTPProviding {
    func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> Data
    func get(_ path: String, headers: [String: String]) async throws -> Data
}

public final class URLSessionHTTP: HTTPProviding {
    private let base: URL
    private let session: URLSession
    public init(base: URL = URL(string: "https://api.trongrid.io")!, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await run(request)
    }

    public func get(_ path: String, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await run(request)
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TronGridError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}

public struct TronBalances: Equatable, Sendable {
    public let trxBalance: Int64
    public let usdtSun: Int64
    public init(trxBalance: Int64, usdtSun: Int64) {
        self.trxBalance = trxBalance
        self.usdtSun = usdtSun
    }
}

public struct CachedTronBalances: Equatable, Sendable {
    public let balances: TronBalances
    public let updatedAt: Date
    public init(balances: TronBalances, updatedAt: Date) {
        self.balances = balances
        self.updatedAt = updatedAt
    }
    public func isFresh(at date: Date = Date(), maxAge: TimeInterval) -> Bool {
        let age = date.timeIntervalSince(updatedAt)
        return age >= 0 && age < maxAge
    }
}

public enum TronGridError: LocalizedError, Equatable {
    case http(Int), badResponse, invalidAddress
    public var errorDescription: String? {
        switch self {
        case .http(429): return "TronGrid 请求过于频繁，请稍后重试或在设置中填写 API key"
        case .http(let code): return "TronGrid 请求失败（HTTP \(code)），请稍后重试"
        case .badResponse: return "TronGrid 返回的数据无效，请稍后重试"
        case .invalidAddress: return "Tron 地址或校验位无效"
        }
    }
}

public let usdtContract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

public final class TronGridClient {
    private let http: HTTPProviding
    private let headers: [String: String]
    public init(http: HTTPProviding, apiKey: String = "") {
        self.http = http
        self.headers = apiKey.isEmpty ? [:] : ["TRON-PRO-API-KEY": apiKey]
    }

    public func balances(address: String) async throws -> TronBalances {
        guard TronWalletService().validateAddress(address),
              let parsed = try? Address(address: address) else { throw TronGridError.invalidAddress }
        let data = try await http.get("/v1/accounts/\(address)", headers: headers)
        struct Account: Decodable {
            let balance: Int64?
        }
        struct Response: Decodable {
            let success: Bool
            let data: [Account]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.success else {
            throw TronGridError.badResponse
        }
        let trx = response.data.first?.balance ?? 0
        guard trx >= 0 else { throw TronGridError.badResponse }

        // An unactivated account can receive USDT while /v1/accounts still returns data: [].
        // Read the token contract even when the native account is absent; its index can also lag.
        let addressHex = parsed.nonPrefixed.map { String(format: "%02x", $0) }.joined()
        let tokenData = try await http.post("/wallet/triggerconstantcontract", body: [
            "owner_address": address,
            "contract_address": usdtContract,
            "function_selector": "balanceOf(address)",
            "parameter": String(repeating: "0", count: 24) + addressHex,
            "visible": true
        ], headers: headers)
        struct ConstantResponse: Decodable {
            struct Result: Decodable { let result: Bool }
            let result: Result
            let constant_result: [String]
        }
        guard let token = try? JSONDecoder().decode(ConstantResponse.self, from: tokenData),
              token.result.result, token.constant_result.count == 1,
              let word = token.constant_result.first, word.utf8.count == 64,
              word.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let usdt = Int64(word, radix: 16), usdt >= 0 else {
            throw TronGridError.badResponse
        }
        return TronBalances(trxBalance: trx, usdtSun: usdt)
    }

    /// Exact unsigned decimal input; all chain amounts remain Int64, never Double.
    public static func parseSun(_ input: String) -> Int64? {
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let whole = Int64(parts[0]) else { return nil }
        let (base, multipliedOverflow) = whole.multipliedReportingOverflow(by: 1_000_000)
        guard !multipliedOverflow else { return nil }
        var fraction: Int64 = 0
        if parts.count == 2 {
            let digits = parts[1]
            guard (1...6).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int64(digits) else { return nil }
            fraction = value
            for _ in digits.count..<6 { fraction *= 10 }
        }
        let (amount, overflow) = base.addingReportingOverflow(fraction)
        return overflow ? nil : amount
    }

    public static func formatUSDT(_ sun: Int64) -> String {
        let magnitude = sun.magnitude
        let fraction = String(magnitude % 1_000_000)
        return "\(sun < 0 ? "-" : "")\(magnitude / 1_000_000).\(String(repeating: "0", count: 6 - fraction.count))\(fraction)"
    }
}
