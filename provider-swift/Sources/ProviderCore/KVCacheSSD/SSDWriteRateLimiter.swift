import Foundation

/// Continuous-refill admission budget, additionally fenced by the production
/// factories' persistent root-wide rolling-day write budget. A repeat reserve limits novel
/// writes through a second, smaller bucket. Both kinds still consume the same
/// total budget. Unlike a fixed balance floor, novel writes resume as their
/// share refills rather than waiting for the entire reserved balance to refill.
/// Speculative first-sight writes have a third, smallest allowance
/// (`consumeSpeculative`).
final class SSDWriteRateLimiter: @unchecked Sendable {
    enum Decision { case accepted, rateLimited, priorityLimited }
    private let capBytesPerDay: Double
    private let writeBudget: SSDWriteBudget?
    private let dailyByteLimit: Int
    private let novelCapBytesPerDay: Double
    private let speculativeHeadroomBytes: Double
    private let speculativeBudget: SSDWriteBudget?
    private var tokens: Double
    private var novelTokens: Double
    private var speculativeTokens: Double
    private var lastRefill: Double
    /// When a proven or novel write last found the total budget exhausted.
    private var lastTotalRefusal: Double?
    private let nowSeconds: @Sendable () -> Double
    private let lock = NSLock()

    init(capBytesPerDay: Int, repeatReserveFraction: Double = 0,
         speculativeHeadroomFraction: Double = 0,
         writeBudget: SSDWriteBudget? = nil, speculativeBudget: SSDWriteBudget? = nil,
         nowSeconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        let cap = Double(max(0, capBytesPerDay))
        let reserve = repeatReserveFraction.isFinite ? min(1, max(0, repeatReserveFraction)) : 0
        let headroom = speculativeHeadroomFraction.isFinite ? min(1, max(0, speculativeHeadroomFraction)) : 0
        self.capBytesPerDay = cap
        self.dailyByteLimit = max(0, capBytesPerDay)
        self.writeBudget = writeBudget
        self.novelCapBytesPerDay = cap * (1 - reserve)
        self.speculativeHeadroomBytes = (cap * headroom).rounded(.down)
        self.speculativeBudget = speculativeBudget
        self.tokens = cap
        self.novelTokens = cap * (1 - reserve)
        self.speculativeTokens = (cap * headroom).rounded(.down)
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
            speculativeTokens = refilledSpeculative(now: now)
            lastRefill = max(lastRefill, now)
            let result = decision(bytes: bytes, repeated: repeated, available: available)
            // Only a spent total budget pauses speculative writes; a busy or
            // failed ledger refuses this write without one.
            guard result == .accepted else {
                if result == .rateLimited { lastTotalRefusal = now }
                return result
            }
            let ledger = SSDSpeculativeLedgerGate.process.ordinary {
                writeBudget?.admission(bytes: bytes, capBytesPerDay: dailyByteLimit, now: now, consume: true)
            }
            switch ledger {
            case .overCap:
                lastTotalRefusal = now
                return .rateLimited
            case .unavailable:
                return .rateLimited
            case .admitted, nil:
                break
            }
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
            let admitted = SSDSpeculativeLedgerGate.process.ordinary {
                writeBudget?.admit(bytes: bytes, capBytesPerDay: dailyByteLimit, now: now, consume: false)
            }
            return admitted == false ? .rateLimited : .accepted
        }
    }

    /// Speculative (first-sight) writes spend only what the other classes
    /// leave, and never more than their own share (`headroom`, one TTL of the
    /// cap per day):
    /// - their own allowance refills at `headroom` per day, in memory and in
    ///   a separate persistent rolling-day ledger;
    /// - they still count in the shared bucket and root-wide ledger, so total
    ///   writes never exceed the cap, but never spend the last `headroom` of
    ///   either, which stays for proven and novel writes;
    /// - for a day after a proven or novel write found the total budget
    ///   exhausted, none: on a root whose own demand reaches the cap, every
    ///   speculative byte would displace one of those writes.
    /// An unlimited cap (0) or zero headroom admits none.
    func consumeSpeculative(bytes: Int) -> Decision {
        speculative(bytes: bytes, consume: true)
    }

    /// Advisory form of `consumeSpeculative`; the writer charges again.
    func speculativeAdmission(bytes: Int) -> Decision {
        speculative(bytes: bytes, consume: false)
    }

    static let speculativePauseSeconds: Double = 86_400

    private func speculative(bytes: Int, consume: Bool) -> Decision {
        guard bytes >= 0, capBytesPerDay > 0, speculativeHeadroomBytes > 0 else { return .priorityLimited }
        return lock.withLock {
            let now = nowSeconds()
            if let refused = lastTotalRefusal, now - refused < Self.speculativePauseSeconds {
                return .priorityLimited
            }
            let available = refilled(now: now)
            let speculativeAvailable = refilledSpeculative(now: now)
            let charge = Double(bytes)
            guard speculativeAvailable >= charge,
                available.total - charge >= speculativeHeadroomBytes,
                available.novel - charge >= speculativeHeadroomBytes
            else { return .priorityLimited }
            // The speculative ledger is charged first: if another writer wins
            // the shared ledger between check and charge, only the speculative
            // allowance is over-charged, never what proven writes rely on.
            let ledgers = [(speculativeBudget, Int(speculativeHeadroomBytes)),
                           (writeBudget, dailyByteLimit - Int(speculativeHeadroomBytes))]
            let charged = SSDSpeculativeLedgerGate.process.speculative { () -> Decision in
                for (budget, limit) in ledgers {
                    guard budget?.admit(bytes: bytes, capBytesPerDay: limit, now: now, consume: false) != false
                    else { return .priorityLimited }
                }
                guard consume else { return .accepted }
                for (budget, limit) in ledgers {
                    guard budget?.admit(bytes: bytes, capBytesPerDay: limit, now: now, consume: true) != false
                    else { return .priorityLimited }
                }
                return .accepted
            }
            guard consume, charged == .accepted else { return charged }
            tokens = available.total - charge
            novelTokens = available.novel - charge
            speculativeTokens = speculativeAvailable - charge
            lastRefill = max(lastRefill, now)
            return .accepted
        }
    }

    private func decision(bytes: Int, repeated: Bool, available: (total: Double, novel: Double)) -> Decision {
        guard available.total >= Double(bytes) else { return .rateLimited }
        guard repeated || available.novel >= Double(bytes) else { return .priorityLimited }
        return .accepted
    }

    private func refilledSpeculative(now: Double) -> Double {
        let elapsed = max(0, now - lastRefill)
        return min(speculativeHeadroomBytes, speculativeTokens + elapsed * speculativeHeadroomBytes / 86_400)
    }

    private func refilled(now: Double) -> (total: Double, novel: Double) {
        let elapsed = max(0, now - lastRefill)
        return (min(capBytesPerDay, tokens + elapsed * capBytesPerDay / 86_400),
                min(novelCapBytesPerDay, novelTokens + elapsed * novelCapBytesPerDay / 86_400))
    }
}

/// The root-wide ledger refuses a charge while another holds its file lock.
/// Within this process, ordinary charges share this gate and a speculative
/// charge holds it alone, so an ordinary charge waits out a speculative one
/// instead of being refused; ordinary charges never wait for each other.
final class SSDSpeculativeLedgerGate: @unchecked Sendable {
    static let process = SSDSpeculativeLedgerGate()
    private let rwlock: UnsafeMutablePointer<pthread_rwlock_t>

    private init() {
        rwlock = .allocate(capacity: 1)
        pthread_rwlock_init(rwlock, nil)
    }

    func ordinary<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        return try body()
    }

    func speculative<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        return try body()
    }
}
