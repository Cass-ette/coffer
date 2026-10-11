import Foundation

/// Shared by all wallet screens so separate clients cannot burst against the same provider.
actor TronGridRequestCoordinator {
    static let shared = TronGridRequestCoordinator()
    private let minimumInterval: TimeInterval
    private let keyedInterval: TimeInterval
    private let initialCooldown: TimeInterval
    private let repeatedCooldown: TimeInterval
    private let maximumAutomaticWait: TimeInterval
    private let chainParametersTTL: TimeInterval
    private var nextRequest: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    private var chainParameters: (data: Data, storedAt: TimeInterval)?

    init(minimumInterval: TimeInterval = 1.1, keyedInterval: TimeInterval = 0.25,
         initialCooldown: TimeInterval = 3, repeatedCooldown: TimeInterval = 30,
         maximumAutomaticWait: TimeInterval = 10, chainParametersTTL: TimeInterval = 15) {
        self.minimumInterval = minimumInterval
        self.keyedInterval = keyedInterval
        self.initialCooldown = initialCooldown
        self.repeatedCooldown = repeatedCooldown
        self.maximumAutomaticWait = maximumAutomaticWait
        self.chainParametersTTL = chainParametersTTL
    }

    func cachedChainParameters() -> Data? {
        guard let cached = chainParameters,
              ProcessInfo.processInfo.systemUptime - cached.storedAt < chainParametersTTL else { return nil }
        return cached.data
    }

    func cacheChainParameters(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["chainParameter"] as? [[String: Any]],
              let energy = rows.first(where: { $0["key"] as? String == "getEnergyFee" })
                .flatMap({ WalletJSON.integer($0["value"]) }),
              let bandwidth = rows.first(where: { $0["key"] as? String == "getTransactionFee" })
                .flatMap({ WalletJSON.integer($0["value"]) }), energy > 0, bandwidth > 0 else { return }
        chainParameters = (data, ProcessInfo.processInfo.systemUptime)
    }

    func wait(authenticated: Bool) async throws {
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let cooldown = cooldownUntil - now
            guard cooldown <= maximumAutomaticWait else {
                throw TronGridError.rateLimited(retryAfterSeconds: Self.seconds(cooldown))
            }
            let delay = max(nextRequest, cooldownUntil) - now
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
                // Actor reentrancy: recheck after sleeping, another caller may have acquired the slot.
                continue
            }
            nextRequest = now + (authenticated ? keyedInterval : minimumInterval)
            return
        }
    }

    func rateLimited(retryAfter: String?, alreadyRetried: Bool) -> (retry: Bool, seconds: Int) {
        let baseline = alreadyRetried ? repeatedCooldown : initialCooldown
        let delay = max(baseline, Self.retryDelay(retryAfter) ?? 0)
        let now = ProcessInfo.processInfo.systemUptime
        cooldownUntil = max(cooldownUntil, now + delay)
        let remaining = cooldownUntil - now
        return (!alreadyRetried && remaining <= maximumAutomaticWait, Self.seconds(remaining))
    }

    private static func seconds(_ interval: TimeInterval) -> Int {
        // Retry-After is untrusted input; avoid trapping on nonfinite or enormous numbers.
        Int(min(Double(Int32.max), max(1, ceil(interval))))
    }

    private static func retryDelay(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return min(seconds, Double(Int32.max))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
