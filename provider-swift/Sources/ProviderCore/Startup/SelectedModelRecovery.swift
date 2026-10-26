import Foundation

/// Selected models the provider keeps trying to make resident after memory,
/// not the operator, kept them out (`ProviderLoop+SelectedModelRecovery`).
/// Each entry is checked when it is due. A check that does not load it backs
/// off; an unload makes every entry due at once.
struct SelectedModelRecovery: Sendable {
    /// Delays after each check that did not load a model; the last repeats.
    static let checkBackoff: [Duration] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600),
    ]
    /// How long an unselected model must have been idle before a recovery
    /// evicts it, so a gap between its requests is never mistaken for idle.
    static let victimMinimumIdle: Duration = .seconds(120)
    /// The delay before rechecking a model whose check found another
    /// residency change in progress (a load, an operation, a switch).
    static let pauseRecheck: Duration = .seconds(15)

    struct Entry: Sendable, Equatable {
        let since: ContinuousClock.Instant
        /// Unix seconds of `since`, for the daemon state.
        let sinceEpoch: Double
        var checks = 0
        var nextCheckAt: ContinuousClock.Instant
        /// Why the last check did not load the model.
        var blocker: String?
    }

    private(set) var entries: [String: Entry] = [:]
    /// The attempt in progress (evictions, then the load), off the
    /// capacity tick; cancelled at shutdown.
    var attempt: (model: String, task: Task<Void, Never>)?

    var isEmpty: Bool { entries.isEmpty }

    mutating func enqueue(_ id: String, now: ContinuousClock.Instant, nowEpoch: Double) {
        guard entries[id] == nil else { return }
        entries[id] = Entry(since: now, sinceEpoch: nowEpoch, nextCheckAt: now)
    }

    mutating func remove(_ id: String) {
        entries.removeValue(forKey: id)
    }

    /// Records a check that did not load `id`. The next one is due after the
    /// next backoff step, or when what blocked it ends (`retryAt`: a hold's
    /// expiry, an idle threshold), at most the longest step away.
    mutating func deferCheck(_ id: String, blocker: String, now: ContinuousClock.Instant,
                             retryAt: ContinuousClock.Instant? = nil) {
        guard var entry = entries[id] else { return }
        let step = Self.checkBackoff[min(entry.checks, Self.checkBackoff.count - 1)]
        let longest = now.advanced(by: Self.checkBackoff[Self.checkBackoff.count - 1])
        entry.checks += 1
        entry.blocker = blocker
        entry.nextCheckAt = retryAt.map { max(now, min($0, longest)) } ?? now.advanced(by: step)
        entries[id] = entry
    }

    /// Another residency change is in progress: check again shortly, without
    /// advancing the backoff.
    mutating func pause(_ id: String, blocker: String, now: ContinuousClock.Instant) {
        entries[id]?.blocker = blocker
        entries[id]?.nextCheckAt = now.advanced(by: Self.pauseRecheck)
    }

    /// Memory was freed: every entry is due now.
    mutating func makeAllDue(now: ContinuousClock.Instant) {
        for id in entries.keys { entries[id]?.nextCheckAt = now }
    }

    /// The due entry waiting longest, if any.
    func nextDue(now: ContinuousClock.Instant) -> String? {
        entries.filter { $0.value.nextCheckAt <= now }
            .min { ($0.value.since, $0.key) < ($1.value.since, $1.key) }?.key
    }
}

extension DaemonState {
    /// A selected model the daemon keeps trying to load
    /// (`ProviderLoop.selectedModelRecovery`).
    public struct SelectedModelRecoveryEntry: Codable, Sendable, Equatable {
        public var model: String
        /// Unix seconds since which it has been waiting.
        public var waitingSince: Double
        /// Unix seconds of the next check; nil while it is loading.
        public var nextCheckAt: Double?
        public var checks: Int
        /// Why the last check did not load it.
        public var blocker: String?
        public var loading: Bool?

        public init(model: String, waitingSince: Double, nextCheckAt: Double?, checks: Int,
                    blocker: String? = nil, loading: Bool? = nil) {
            self.model = model
            self.waitingSince = waitingSince
            self.nextCheckAt = nextCheckAt
            self.checks = checks
            self.blocker = blocker
            self.loading = loading
        }
    }
}
