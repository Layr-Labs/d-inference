import Foundation

/// Process-wide ledger of MEASURED resident weight bytes, keyed by model.
///
/// The unified-memory policy (``UnifiedMemoryCap``) budgets KV cache as
/// `cap − Σ(resident weights) − activations`. That Σ must cover EVERY currently
/// loaded model, but each model's `BatchScheduler` only knows its own weights —
/// so this single shared actor holds the per-model figures and sums them. It is
/// the one place that answers "how much weight memory is resident right now?"
/// across all co-resident models, with no assumption about how many there are.
///
/// "Measured" means the bytes are recorded AFTER a model is in memory (the
/// caller passes the post-load residency it observed), not an a-priori
/// file-size estimate. Entries are added on load and removed on unload, so the
/// total tracks reality across load/evict/swap transitions.
public actor ResidentModelLedger {
    /// modelKey → measured resident weight bytes.
    private var weights: [String: UInt64] = [:]

    public init() {}

    /// Record (or overwrite) a model's measured resident weight bytes. Call once
    /// the model is loaded and its footprint observed. Overwrite is intentional:
    /// a reload re-measures rather than double-counting.
    public func record(modelKey: String, weightBytes: UInt64) {
        weights[modelKey] = weightBytes
    }

    /// Drop a model from the ledger on unload/eviction. No-op if unknown.
    public func remove(modelKey: String) {
        weights.removeValue(forKey: modelKey)
    }

    /// Total measured resident weight bytes across all loaded models (saturating).
    public func totalResidentWeightBytes() -> UInt64 {
        weights.values.reduce(UInt64(0)) { partial, v in
            let (sum, overflow) = partial.addingReportingOverflow(v)
            return overflow ? UInt64.max : sum
        }
    }

    /// Total EXCLUDING one model — what would be resident if `modelKey` were not
    /// loaded. Used by the load gate to evaluate admitting a replacement: the
    /// candidate is weighed against everything else, not against itself.
    public func totalResidentWeightBytes(excluding modelKey: String) -> UInt64 {
        weights.reduce(UInt64(0)) { partial, entry in
            guard entry.key != modelKey else { return partial }
            let (sum, overflow) = partial.addingReportingOverflow(entry.value)
            return overflow ? UInt64.max : sum
        }
    }

    /// Measured weight bytes for one model, or nil if not resident.
    public func weightBytes(modelKey: String) -> UInt64? {
        weights[modelKey]
    }

    /// Number of models currently recorded as resident.
    public func count() -> Int {
        weights.count
    }

    /// Snapshot of all resident models and their weight bytes (for telemetry /
    /// the load-admission decision, which may need per-model figures to choose
    /// an eviction victim).
    public func snapshot() -> [String: UInt64] {
        weights
    }
}
