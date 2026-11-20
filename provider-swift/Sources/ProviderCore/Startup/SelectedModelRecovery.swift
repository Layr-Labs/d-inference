import Foundation

/// Selected models the provider keeps trying to make resident after memory,
/// not the operator, kept them out (`ProviderLoop+SelectedModelRecovery`).
/// Each entry is checked when it is due. A check that does not load it backs
/// off; an unload or a configuration change makes every entry due at once.
/// After `postLoadRefusalLimit` memory refusals that came after the weights
/// loaded, an entry is checked only when one of those makes it due.
struct SelectedModelRecovery: Sendable {
    /// Delays after each check that did not load a model; the last repeats.
    static let checkBackoff: [Duration] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600),
    ]
    /// Memory refusals after the weights loaded (the KV headroom guards, the
    /// re-slice checks, MiMo's grant) after which a model waits for an
    /// unload or a configuration change instead of the backoff: each such
    /// check loads the whole model only to unload it. A policy value; the
    /// owner may change it.
    static let postLoadRefusalLimit = 3
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
        /// Memory refusals after the weights loaded since the entry was
        /// queued or an unload or a configuration change last made it due.
        var postLoadRefusals = 0

        /// Checked again only after an unload or a configuration change.
        var waitsForChange: Bool { postLoadRefusals >= SelectedModelRecovery.postLoadRefusalLimit }
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
    /// next backoff step, or sooner when what blocked it ends first
    /// (`retryAt`: a hold's expiry, an idle threshold).
    mutating func deferCheck(_ id: String, blocker: String, now: ContinuousClock.Instant,
                             retryAt: ContinuousClock.Instant? = nil) {
        guard var entry = entries[id] else { return }
        let backoff = now.advanced(by: Self.checkBackoff[min(entry.checks, Self.checkBackoff.count - 1)])
        entry.checks += 1
        entry.blocker = blocker
        entry.nextCheckAt = retryAt.map { max(now, min($0, backoff)) } ?? backoff
        entries[id] = entry
    }

    /// Records a memory refusal that came after the weights loaded: a check
    /// that did not load `id`, and at `postLoadRefusalLimit` the last one
    /// until an unload or a configuration change (`makeAllDue`).
    mutating func deferAfterPostLoadRefusal(_ id: String, blocker: String, now: ContinuousClock.Instant) {
        deferCheck(id, blocker: blocker, now: now)
        guard var entry = entries[id] else { return }
        entry.postLoadRefusals += 1
        if entry.waitsForChange {
            entry.blocker = blocker + "; stopped after \(Self.postLoadRefusalLimit) memory refusals after loading"
        }
        entries[id] = entry
    }

    /// Another residency change is in progress: check again shortly, without
    /// advancing the backoff.
    mutating func pause(_ id: String, blocker: String, now: ContinuousClock.Instant) {
        entries[id]?.blocker = blocker
        entries[id]?.nextCheckAt = now.advanced(by: Self.pauseRecheck)
    }

    /// Memory was freed or the configuration changed: every entry is due now,
    /// and counts its refusals after loading afresh.
    mutating func makeAllDue(now: ContinuousClock.Instant) {
        for id in entries.keys {
            entries[id]?.nextCheckAt = now
            entries[id]?.postLoadRefusals = 0
        }
    }

    /// The due entry waiting longest, if any. An entry that waits for an
    /// unload or a configuration change is never due.
    func nextDue(now: ContinuousClock.Instant) -> String? {
        entries.filter { !$0.value.waitsForChange && $0.value.nextCheckAt <= now }
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
        /// Unix seconds of the next check; nil while it is loading, and while
        /// it waits for an unload or a configuration change after repeated
        /// memory refusals after loading.
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
