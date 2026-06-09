import Foundation

/// Thread-safe, mutable holder for the provider's advertised model list.
///
/// The advertised list is fixed at startup from the disk scan ∩ `enabledModels`,
/// but background prefetch (Layer 3) can make a NEW build available on disk at
/// runtime. When that happens the provider must start advertising the new build
/// WITHOUT dropping the model it is currently serving — so the set is a union of
/// the startup models plus anything added at runtime, deduplicated by model id.
///
/// Registration reads this holder (instead of a captured immutable array) so a
/// re-registration after a verified prefetch carries the updated `Models` list.
/// The currently-served model is never removed here, satisfying the
/// "advertise BOTH old and new during the transition" requirement.
///
/// A lock (matching `OutboundRouter`/`PongTracker`) is used rather than actor
/// isolation so the synchronous registration encoder can read it without an
/// `await`, and so a re-advertise from the `ProviderLoop` actor can update it
/// without hopping onto the `CoordinatorClient` actor.
final class AdvertisedModelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: ModelInfo]
    /// Preserves first-seen ordering so the advertised list is stable across
    /// reads (startup models first, in their original order, then runtime
    /// additions in the order they were verified).
    private var order: [String]

    init(_ initial: [ModelInfo]) {
        var map: [String: ModelInfo] = [:]
        var ord: [String] = []
        for model in initial where map[model.id] == nil {
            map[model.id] = model
            ord.append(model.id)
        }
        self.byID = map
        self.order = ord
    }

    /// Current advertised models, in stable order.
    var models: [ModelInfo] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { byID[$0] }
    }

    /// Whether a model id is already advertised.
    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byID[id] != nil
    }

    /// Look up the advertised info for a model id.
    func model(id: String) -> ModelInfo? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }

    /// Sorted advertised model ids (used by the local `/v1/models` catalog).
    func sortedIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return byID.keys.sorted()
    }

    /// Add (or update) a runtime-discovered model. Returns true when the id was
    /// newly added — false when it was already advertised (info refreshed in
    /// place either way). Never removes an existing entry, so the
    /// currently-served build is always retained during a transition.
    @discardableResult
    func add(_ model: ModelInfo) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let isNew = byID[model.id] == nil
        if isNew { order.append(model.id) }
        byID[model.id] = model
        return isNew
    }

    /// Retire a build from the advertised set (a hard swap: once the desired build
    /// is serving, the superseded build is dropped so the next register no longer
    /// announces it). No-op when absent; returns true when an entry was removed.
    @discardableResult
    func remove(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard byID[id] != nil else { return false }
        byID[id] = nil
        order.removeAll { $0 == id }
        return true
    }
}
