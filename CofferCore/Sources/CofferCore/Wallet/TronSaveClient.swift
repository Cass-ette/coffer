import Foundation

public enum RentalError: LocalizedError, Equatable {
    case unavailable, expired, paymentMismatch, uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法取得可完整成交的租赁报价；可刷新报价或选择直接付费"
        case .expired: return "租赁报价已过期，请重新查看费用并确认"
        case .paymentMismatch: return "租赁付款与已确认的收款人或金额不一致，已停止"
        case .uncertain(let hash): return "租赁付款状态待确认，请查询交易 \(hash)，不要重复购买"
        }
    }
}

public struct TronRentalQuote: Equatable, Sendable {
    public let address: String
    public let energy: Int64
    public let durationSeconds: Int
    public let unitPrice: Decimal
    public let rentSun: Int64
    public let quotedAt: Date
    public func isFresh(at now: Date = Date()) -> Bool {
        (0..<90).contains(now.timeIntervalSince(quotedAt))
    }
}

public struct TronRentalPlan: Equatable, Sendable {
    /// Conservative size for a single-signature, memo-free TRX payment to an activated account.
    public static let paymentBandwidth: Int64 = 300
    public let quote: TronRentalQuote
    public let paymentFeeSun: Int64
    public let transferFeeSun: Int64
    public let totalSun: Int64
    public let maximumTotalSun: Int64
    public let savingsSun: Int64

    public init(quote: TronRentalQuote, directFee: TronFee) throws {
        guard directFee.energyBurned > 0, quote.energy >= directFee.energyBurned else {
            throw RentalError.unavailable
        }
        let payment = try directFee.resources.consumingBandwidth(Self.paymentBandwidth)
        let transfer = try payment.remaining.consumingBandwidth(directFee.bandwidthRequired)
        self.quote = quote
        self.paymentFeeSun = try WalletJSON.multiply(payment.burned, directFee.bandwidthPrice)
        self.transferFeeSun = try WalletJSON.multiply(transfer.burned, directFee.bandwidthPrice)
        self.totalSun = try WalletJSON.add(quote.rentSun, WalletJSON.add(paymentFeeSun, transferFeeSun))
        let energyHeadroom = directFee.feeLimitSun - (try WalletJSON.multiply(directFee.energy, directFee.energyPrice))
        self.maximumTotalSun = try WalletJSON.add(totalSun, energyHeadroom)
        self.savingsSun = directFee.feeSun - totalSun
    }
}

public struct SignedTronRentalPayment: Sendable {
    public let txHash: String
    public let payload: Data
    public let from: String
    public let amountSun: Int64
    public let expiration: Date
    public let bandwidth: Int64
}

/// Per-order payment, no hosted balance and no API key. Never sends a private key to a provider.
public final class TronSaveClient {
    public static let baseURL = URL(string: "https://api.tronsave.io")!
    // Official mainnet signed-transaction example; never substituted by an API response.
    public static let paymentAddress = "TWZEhq5JuUVvGtutNgnRBATbF8BnHGyn4S"
    private let http: HTTPProviding
    public init(http: HTTPProviding = URLSessionHTTP(base: TronSaveClient.baseURL)) { self.http = http }

    public func quote(address: String, energy: Int64, now: Date = Date()) async throws -> TronRentalQuote {
        guard TronWalletService().validateAddress(address), energy > 0 else { throw RentalError.unavailable }
        let data = try await http.post("/v2/estimate-buy-resource", body: [
            "resourceType": "ENERGY", "resourceAmount": energy, "durationSec": 3600,
            "unitPrice": "MEDIUM", "requester": address, "receiver": address,
            "options": ["allowPartialFill": false]
        ], headers: [:])
        struct Response: Decodable {
            struct Quote: Decodable {
                let unitPrice: Decimal
                let durationSec: Int
                let estimateTrx: Int64
                let availableResource: Int64
            }
            let error: Bool
            let data: Quote?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.error,
              let result = response.data, result.durationSec == 3600,
              result.availableResource >= energy, result.estimateTrx > 0,
              !result.unitPrice.isNaN, result.unitPrice > 0 else { throw RentalError.unavailable }
        // This one-hour product quotes SUN per requested unit. Reject unitemized extra charges.
        var cost = Decimal(energy) * result.unitPrice
        var rounded = Decimal()
        // TronSave's mainnet estimate truncates fractional SUN (e.g. 130285 × 67.25 =
        // 8761666.25 SUN, returned as 8761666). Only accept that exact rounding rule.
        NSDecimalRound(&rounded, &cost, 0, .down)
        guard rounded == Decimal(result.estimateTrx) else { throw RentalError.unavailable }
        return TronRentalQuote(address: address, energy: energy, durationSeconds: 3600,
                               unitPrice: result.unitPrice, rentSun: result.estimateTrx, quotedAt: now)
    }

    public func buy(quote: TronRentalQuote, payment: SignedTronRentalPayment,
                    now: Date = Date()) async throws -> String {
        guard quote.isFresh(at: now), payment.expiration.timeIntervalSince(now) > 5 else { throw RentalError.expired }
        guard payment.from == quote.address, payment.amountSun == quote.rentSun else { throw RentalError.paymentMismatch }
        let signed = try WalletJSON.object(payment.payload)
        try Task.checkCancellation()
        do {
            let data = try await http.post("/v2/buy-resource", body: [
                "resourceType": "ENERGY", "resourceAmount": quote.energy, "durationSec": quote.durationSeconds,
                "receiver": quote.address, "unitPrice": NSDecimalNumber(decimal: quote.unitPrice),
                "signedTx": signed,
                "options": ["allowPartialFill": false, "onlyCreateWhenFulfilled": true,
                            "preventDuplicateIncompleteOrders": true,
                            "maxPriceAccepted": NSDecimalNumber(decimal: quote.unitPrice)]
            ], headers: [:])
            let response = try WalletJSON.object(data)
            guard WalletJSON.bool(response["error"]) == false,
                  let value = response["data"] as? [String: Any],
                  let order = value["orderId"] as? String, !order.isEmpty, order.count <= 128 else {
                throw RentalError.uncertain(payment.txHash)
            }
            return order
        } catch {
            // Once submitted, even an error response does not prove the TRX payment was not broadcast.
            throw RentalError.uncertain(payment.txHash)
        }
    }
}
