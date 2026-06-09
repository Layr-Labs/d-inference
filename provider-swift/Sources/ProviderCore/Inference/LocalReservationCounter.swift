import Foundation

/// Per-model count of in-flight requests from the LOCAL HTTP endpoint in unified
/// mode (`darkbloom start --local-endpoint`).
///
/// Local requests aren't tracked in `ProviderLoop`'s coordinator-request
/// bookkeeping (`requestToModel`), so this is what keeps the idle monitor and
/// load-gate eviction from pulling a model out from under a local stream. Kept
/// as a small value type so the increment/decrement/remove-at-zero semantics are
/// unit-testable without standing up a full `ProviderLoop` + MLX engine.
struct LocalReservationCounter: Sendable, Equatable {
    private var counts: [String: Int] = [:]

    /// Record one new in-flight local request for `modelId`.
    mutating func reserve(_ modelId: String) {
        counts[modelId, default: 0] += 1
    }

    /// Drop one in-flight local request for `modelId`. Removes the key at zero so
    /// `isReserved` and the eviction filters see no stale entry. A release with
    /// no matching reservation is a no-op (never goes negative).
    mutating func release(_ modelId: String) {
        guard let n = counts[modelId] else { return }
        if n <= 1 {
            counts.removeValue(forKey: modelId)
        } else {
            counts[modelId] = n - 1
        }
    }

    /// Whether `modelId` currently has at least one local request in flight.
    func isReserved(_ modelId: String) -> Bool {
        (counts[modelId] ?? 0) > 0
    }

    /// Current in-flight local count for `modelId` (0 when none).
    func count(_ modelId: String) -> Int {
        counts[modelId] ?? 0
    }

    /// Total in-flight local requests across all models.
    var totalInFlight: Int {
        counts.values.reduce(0, +)
    }

    /// Whether any local request is currently in flight. Used by drain logic
    /// (shutdown and update hot-swap) so a local stream is never cut off.
    var hasAny: Bool {
        !counts.isEmpty
    }
}
