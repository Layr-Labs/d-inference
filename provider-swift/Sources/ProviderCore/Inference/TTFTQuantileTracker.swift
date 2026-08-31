// Copyright © 2026 Eigen Labs.
//
// Bounded end-to-end TTFT quantile tracking for capacity quotes (routing v2).
//
// The coordinator's TTFT estimates were stage-composed and stale-optimistic
// (v0.8.0 postmortem: TTFT p95 12.8s / p99 33s while heartbeats looked ~1.4%
// utilized). The quote contract therefore demands the real end-to-end
// distribution measured at the provider — dispatch-received to first content
// token — from COMPLETED real requests, never a sum of per-stage p95s and
// never wall-clock timestamps (clock skew across boxes).
//
// Design constraints, in order:
//   * Bounded memory: fixed-size sample rings per bucket, a hard cap on the
//     number of buckets (LRU-evicted), no unbounded history.
//   * Cheap recording: the hot path (request completion) is one unfair lock
//     plus one array-slot write; no sorting, no allocation after a ring fills.
//   * Sorting happens only at estimate time (the probe path, human-rate).

import Foundation

/// One process-wide tracker instance hangs off `ProviderState` so the
/// ProviderLoop (recording) and CoordinatorClient (quoting) share it without
/// an actor hop. `@unchecked Sendable`: all mutable state is guarded by the
/// single unfair lock, matching the `ProviderState` pattern.
public final class TTFTQuantileTracker: @unchecked Sendable {
    /// Bucket identity. `chip` is deliberately absent: this tracker lives on
    /// ONE provider, whose chip is a constant — the plan's "model+chip
    /// aggregate" fallback tier and the "model aggregate" tier coincide here,
    /// so the local chain is bucket → (model, warm) aggregate → model
    /// aggregate → caller-supplied floor.
    public struct Key: Hashable, Sendable {
        public let model: String
        /// Whether the model was resident when the dispatch arrived. Cold
        /// samples include the model-load latency and must never calibrate
        /// warm quotes (different distributions).
        public let warm: Bool
        /// Prompt tokens rounded UP to a multiple of
        /// `CoordinatorMessage.CapacityProbe.promptBucketTokens` — the same
        /// bucketing the probe's `prompt_tokens_bucket` uses, so probe and
        /// sample land in the same bucket by construction.
        public let promptBucket: Int
        /// Batch occupancy when the dispatch arrived, bucketed by
        /// ``batchBucket(forActiveRequests:)``.
        public let batchBucket: Int

        public init(model: String, warm: Bool, promptBucket: Int, batchBucket: Int) {
            self.model = model
            self.warm = warm
            self.promptBucket = promptBucket
            self.batchBucket = batchBucket
        }
    }

    public struct Estimate: Sendable, Equatable {
        public let p50Ms: Double
        public let p90Ms: Double
        public let confidence: CapacityQuoteConfidence
    }

    /// Samples retained per bucket. 64 doubles ≈ 512 B; enough for stable
    /// p90 (nearest-rank on 64 samples) while old regimes age out quickly.
    static let ringCapacity = 64
    /// Hard cap on distinct (model, warm, prompt, batch) buckets. With ≤3
    /// resident models, 2 warmth states, ~16 realistic prompt buckets and 5
    /// batch buckets this is not reached in practice; a hostile mix of prompt
    /// sizes evicts least-recently-updated buckets instead of growing.
    static let maxBuckets = 512
    /// Minimum samples in the EXACT bucket for `confidence == .high`.
    /// Aggregates and floors are always `.low`.
    static let highConfidenceMinSamples = 8

    /// Fixed-capacity overwrite ring. Value type: lives only inside the
    /// tracker's lock.
    private struct Ring {
        var samples: [Double] = []
        var next = 0
        /// Monotonic recency stamp for LRU eviction of whole buckets.
        var lastTouch: UInt64 = 0

        mutating func append(_ value: Double) {
            if samples.count < TTFTQuantileTracker.ringCapacity {
                samples.append(value)
            } else {
                samples[next] = value
                next = (next + 1) % TTFTQuantileTracker.ringCapacity
            }
        }
    }

    private let lock = OSAllocatedUnfairLock()
    private var buckets: [Key: Ring] = [:]
    private var touchCounter: UInt64 = 0

    public init() {}

    /// Round prompt tokens UP to the probe's bucket size (minimum one bucket,
    /// mirroring the coordinator's rounding of its estimate).
    public static func promptBucket(forPromptTokens tokens: Int) -> Int {
        let bucket = CoordinatorMessage.CapacityProbe.promptBucketTokens
        let clamped = max(1, tokens)
        return ((clamped + bucket - 1) / bucket) * bucket
    }

    /// Bucket batch occupancy (requests already running at dispatch): 0, 1,
    /// 2, 3, then 4+ folded together — TTFT differences flatten out once the
    /// batch is saturated, and folding keeps the key space bounded.
    public static func batchBucket(forActiveRequests active: Int) -> Int {
        min(max(0, active), 4)
    }

    /// Record one completed request's end-to-end TTFT (dispatch-received →
    /// first content token, milliseconds). Callers must only feed completed
    /// real requests — never synthetic probes, never cancelled-before-output
    /// attempts.
    public func record(
        model: String,
        warm: Bool,
        promptTokens: Int,
        activeRequestsAtDispatch: Int,
        ttftMs: Double
    ) {
        guard ttftMs.isFinite, ttftMs >= 0 else { return }
        let key = Key(
            model: model,
            warm: warm,
            promptBucket: Self.promptBucket(forPromptTokens: promptTokens),
            batchBucket: Self.batchBucket(forActiveRequests: activeRequestsAtDispatch))
        lock.withLock {
            touchCounter &+= 1
            var ring = buckets[key] ?? Ring()
            ring.append(ttftMs)
            ring.lastTouch = touchCounter
            if buckets[key] == nil, buckets.count >= Self.maxBuckets {
                // Evict the least-recently-updated bucket to stay bounded.
                if let victim = buckets.min(by: { $0.value.lastTouch < $1.value.lastTouch })?.key {
                    buckets.removeValue(forKey: victim)
                }
            }
            buckets[key] = ring
        }
    }

    /// Quantile estimate with the documented fallback chain:
    /// exact bucket (high confidence at ≥ ``highConfidenceMinSamples``) →
    /// (model, warm) aggregate → model aggregate (both `.low`) → nil, in
    /// which case the caller quotes its benchmark/manifest-derived floor with
    /// `confidence = .low`.
    public func estimate(
        model: String,
        warm: Bool,
        promptBucket: Int,
        batchBucket: Int
    ) -> Estimate? {
        let (exact, modelWarm, modelAny) = lock.withLock {
            () -> ([Double], [Double], [Double]) in
            var exact: [Double] = []
            var modelWarm: [Double] = []
            var modelAny: [Double] = []
            for (key, ring) in buckets where key.model == model {
                modelAny.append(contentsOf: ring.samples)
                guard key.warm == warm else { continue }
                modelWarm.append(contentsOf: ring.samples)
                if key.promptBucket == promptBucket, key.batchBucket == batchBucket {
                    exact = ring.samples
                }
            }
            return (exact, modelWarm, modelAny)
        }
        if exact.count >= Self.highConfidenceMinSamples {
            return Self.quantiles(exact, confidence: .high)
        }
        if !exact.isEmpty {
            return Self.quantiles(exact, confidence: .low)
        }
        if !modelWarm.isEmpty {
            return Self.quantiles(modelWarm, confidence: .low)
        }
        if !modelAny.isEmpty {
            return Self.quantiles(modelAny, confidence: .low)
        }
        return nil
    }

    /// Nearest-rank quantiles over a copy of the samples. Sorting ≤ a few
    /// hundred doubles at probe rate is noise; recording stays O(1).
    private static func quantiles(
        _ samples: [Double],
        confidence: CapacityQuoteConfidence
    ) -> Estimate {
        let sorted = samples.sorted()
        return Estimate(
            p50Ms: nearestRank(sorted, 0.50),
            p90Ms: nearestRank(sorted, 0.90),
            confidence: confidence)
    }

    private static func nearestRank(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
