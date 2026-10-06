import Foundation

/// Which part of the endurance budget a write may spend.
enum SSDWriteClass: Sendable {
    /// The whole budget, including the repeat reserve.
    case repeated
    /// The novel share only.
    case novel
    /// Unproven demand: only the speculative headroom at the top of both buckets.
    case speculative
}

/// Continuous-refill endurance budget. A repeat reserve optionally limits novel
/// writes through a second, smaller bucket. Both kinds still consume the same
/// total budget. Unlike a fixed balance floor, novel writes resume as their
/// share refills rather than waiting for the entire reserved balance to refill.
///
/// Speculative writes are the deliberate exception and do wait for a floor:
/// one is accepted only while it leaves both buckets within the speculative
/// headroom of full. Below that, every byte and all refill belong to the other
/// classes. The guarantee is about balances: with the same other writes
/// accepted, each bucket holds at most the headroom less than it would hold
/// with no speculative write. It is not a bound on refused bytes. A write is
/// refused whole, so a shortfall of at most the headroom can refuse one file
/// that is larger than the headroom, once each time a bucket has refilled to
/// its floor and is drained again. Nor does the headroom bound how much
/// speculation writes in a day.
final class SSDWriteRateLimiter: @unchecked Sendable {
    enum Decision { case accepted, rateLimited, priorityLimited, speculativeLimited }
    private let capBytesPerDay: Double
    private let novelCapBytesPerDay: Double
    private let speculativeHeadroomBytes: Double
    private var tokens: Double
    private var novelTokens: Double
    private var lastRefill: Double
    private let nowSeconds: @Sendable () -> Double
    private let lock = NSLock()

    /// `speculativeHeadroomSeconds` is the speculative headroom expressed as
    /// that many seconds of refill at the cap's rate. The default of 0 accepts
    /// no speculative write of one byte or more.
    init(capBytesPerDay: Int, repeatReserveFraction: Double = 0, speculativeHeadroomSeconds: Double = 0,
         nowSeconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        let cap = Double(max(0, capBytesPerDay))
        let reserve = repeatReserveFraction.isFinite ? min(1, max(0, repeatReserveFraction)) : 0
        let headroomSeconds = speculativeHeadroomSeconds.isFinite ? max(0, speculativeHeadroomSeconds) : 0
        self.capBytesPerDay = cap
        self.novelCapBytesPerDay = cap * (1 - reserve)
        // Never more than the novel share, so neither floor drops below zero
        // and a speculative write cannot overdraw a bucket.
        self.speculativeHeadroomBytes = min(cap * (1 - reserve), headroomSeconds * cap / 86_400)
        self.tokens = cap
        self.novelTokens = cap * (1 - reserve)
        self.nowSeconds = nowSeconds
        self.lastRefill = nowSeconds()
    }

    /// Existing attention-block callers retain their single-budget behavior.
    func tryConsume(bytes: Int, repeated: Bool = true) -> Bool {
        consume(bytes: bytes, writeClass: repeated ? .repeated : .novel) == .accepted
    }

    func consume(bytes: Int, writeClass: SSDWriteClass) -> Decision {
        guard bytes >= 0 else { return .rateLimited }
        guard capBytesPerDay > 0 else { return .accepted }
        return lock.withLock {
            let now = nowSeconds()
            let available = refilled(now: now)
            tokens = available.total
            novelTokens = available.novel
            lastRefill = max(lastRefill, now)
            let result = decision(bytes: bytes, writeClass: writeClass, available: available)
            guard result == .accepted else { return result }
            tokens -= Double(bytes)
            if writeClass != .repeated { novelTokens -= Double(bytes) }
            return .accepted
        }
    }

    /// Admission is advisory; the consumer must charge again before writing.
    func mightAccept(bytes: Int, repeated: Bool = true) -> Bool {
        admission(bytes: bytes, writeClass: repeated ? .repeated : .novel) == .accepted
    }

    func admission(bytes: Int, writeClass: SSDWriteClass) -> Decision {
        guard bytes >= 0 else { return .rateLimited }
        guard capBytesPerDay > 0 else { return .accepted }
        return lock.withLock {
            decision(bytes: bytes, writeClass: writeClass, available: refilled(now: nowSeconds()))
        }
    }

    private func decision(
        bytes: Int, writeClass: SSDWriteClass, available: (total: Double, novel: Double)
    ) -> Decision {
        let bytes = Double(bytes)
        switch writeClass {
        case .repeated:
            return available.total >= bytes ? .accepted : .rateLimited
        case .novel:
            guard available.total >= bytes else { return .rateLimited }
            return available.novel >= bytes ? .accepted : .priorityLimited
        case .speculative:
            let staysWithinHeadroom =
                available.total - bytes >= capBytesPerDay - speculativeHeadroomBytes
                && available.novel - bytes >= novelCapBytesPerDay - speculativeHeadroomBytes
            return staysWithinHeadroom ? .accepted : .speculativeLimited
        }
    }

    private func refilled(now: Double) -> (total: Double, novel: Double) {
        let elapsed = max(0, now - lastRefill)
        return (min(capBytesPerDay, tokens + elapsed * capBytesPerDay / 86_400),
                min(novelCapBytesPerDay, novelTokens + elapsed * novelCapBytesPerDay / 86_400))
    }
}
