import Foundation

/// Continuous-refill admission budget, additionally fenced by the production
/// factories' persistent root-wide rolling-day write budget. A repeat reserve limits novel
/// writes through a second, smaller bucket. Both kinds still consume the same
/// total budget. Unlike a fixed balance floor, novel writes resume as their
/// share refills rather than waiting for the entire reserved balance to refill.
final class SSDWriteRateLimiter: @unchecked Sendable {
    enum Decision { case accepted, rateLimited, priorityLimited }
    private let capBytesPerDay: Double
    private let writeBudget: SSDWriteBudget?
    private let dailyByteLimit: Int
    private let novelCapBytesPerDay: Double
    private var tokens: Double
    private var novelTokens: Double
    private var lastRefill: Double
    private let nowSeconds: @Sendable () -> Double
    private let lock = NSLock()

    init(capBytesPerDay: Int, repeatReserveFraction: Double = 0,
         writeBudget: SSDWriteBudget? = nil,
         nowSeconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        let cap = Double(max(0, capBytesPerDay))
        let reserve = repeatReserveFraction.isFinite ? min(1, max(0, repeatReserveFraction)) : 0
        self.capBytesPerDay = cap
        self.dailyByteLimit = max(0, capBytesPerDay)
        self.writeBudget = writeBudget
        self.novelCapBytesPerDay = cap * (1 - reserve)
        self.tokens = cap
        self.novelTokens = cap * (1 - reserve)
        self.nowSeconds = nowSeconds
        self.lastRefill = nowSeconds()
    }

    /// Existing attention-block callers retain their single-budget behavior.
    func tryConsume(bytes: Int, repeated: Bool = true) -> Bool {
        consume(bytes: bytes, repeated: repeated) == .accepted
    }

    func consume(bytes: Int, repeated: Bool) -> Decision {
        guard bytes >= 0 else { return .rateLimited }
        guard capBytesPerDay > 0 else { return .accepted }
        return lock.withLock {
            let now = nowSeconds()
            let available = refilled(now: now)
            tokens = available.total
            novelTokens = available.novel
            lastRefill = max(lastRefill, now)
            let result = decision(bytes: bytes, repeated: repeated, available: available)
            guard result == .accepted else { return result }
            guard writeBudget?.admit(bytes: bytes, capBytesPerDay: dailyByteLimit,
                                     now: now, consume: true) != false else { return .rateLimited }
            tokens -= Double(bytes)
            if !repeated { novelTokens -= Double(bytes) }
            return .accepted
        }
    }

    /// Admission is advisory; the consumer must charge again before writing.
    func mightAccept(bytes: Int, repeated: Bool = true) -> Bool {
        admission(bytes: bytes, repeated: repeated) == .accepted
    }

    func admission(bytes: Int, repeated: Bool) -> Decision {
        guard bytes >= 0 else { return .rateLimited }
        guard capBytesPerDay > 0 else { return .accepted }
        return lock.withLock {
            let now = nowSeconds()
            let result = decision(bytes: bytes, repeated: repeated, available: refilled(now: now))
            guard result == .accepted else { return result }
            return writeBudget?.admit(bytes: bytes, capBytesPerDay: dailyByteLimit,
                                      now: now, consume: false) == false ? .rateLimited : .accepted
        }
    }

    private func decision(bytes: Int, repeated: Bool, available: (total: Double, novel: Double)) -> Decision {
        guard available.total >= Double(bytes) else { return .rateLimited }
        guard repeated || available.novel >= Double(bytes) else { return .priorityLimited }
        return .accepted
    }

    private func refilled(now: Double) -> (total: Double, novel: Double) {
        let elapsed = max(0, now - lastRefill)
        return (min(capBytesPerDay, tokens + elapsed * capBytesPerDay / 86_400),
                min(novelCapBytesPerDay, novelTokens + elapsed * novelCapBytesPerDay / 86_400))
    }
}
