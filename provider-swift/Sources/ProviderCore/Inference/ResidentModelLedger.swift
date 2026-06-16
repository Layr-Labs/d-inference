import Foundation

/// Process-wide ledger of MEASURED resident weight bytes, keyed by model.
///
/// ⚠️ NOT WIRED INTO ENFORCEMENT (by design). The unified-memory policy enforces
/// the 90% cap using LIVE MLX counters (`MLX.GPU.activeMemory + cacheMemory`),
/// which already reflect every co-resident model's weights AND KV in real time —
/// see ``UnifiedMemoryCap/liveKVHeadroomBytes(...)`` and the load gate. Because
/// model loads are serialized (each completes, and its weights land in the MLX
/// counters, before the next begins), those live counters are an accurate Σ with
/// no separate bookkeeping, so this ledger is redundant for the cap and nothing
/// in the enforcement path calls it. It is retained as a ready-made, measured
/// per-model weight accounting for TELEMETRY / future use (e.g. reporting a
/// per-model footprint breakdown). Do not assume it gates anything — wire it in
/// explicitly if a future change actually needs an out-of-band Σ.
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
    /// loaded. A convenience for a future replacement-sizing caller (weigh a
    /// candidate against everything else, not itself). Not used by the current
    /// load gate, which reads live MLX counters (see the type-level note).
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
    /// a future per-model footprint breakdown). Not consulted by enforcement —
    /// the load gate and KV budgets use live MLX counters (see the type note).
    public func snapshot() -> [String: UInt64] {
        weights
    }
}
