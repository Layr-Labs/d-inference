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
//   * Bounded memory: fixed-size sample rings per bucket AND per fallback
//     tier, a hard cap on the number of buckets (LRU-evicted), no unbounded
//     history.
//   * Cheap recording: the hot path (request completion) is one unfair lock
//     plus O(1) ring-slot writes (exact bucket + the two fallback tiers); no
//     sorting, no allocation after a ring fills.
//   * Cheap probing: every estimate tier is a single dictionary lookup into a
//     precomputed ring; sorting happens only at estimate time and only over
//     one ring's ≤ 64 samples — probe cost never scales with bucket count.

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

    /// Fallback-tier identity for the (model, warm) aggregate ring.
    private struct ModelWarmKey: Hashable {
        let model: String
        let warm: Bool
    }

    private let lock = OSAllocatedUnfairLock()
    private var buckets: [Key: Ring] = [:]
    /// Precomputed fallback tiers, appended on the record path (O(1) each)
    /// instead of rebuilt per probe. The probe path previously copied every
    /// matching bucket's samples into both aggregate arrays under the lock —
    /// up to `maxBuckets × ringCapacity` (32,768) doubles gathered and sorted
    /// synchronously on the coordinator-client actor, delaying frame decode
    /// behind sustained probe traffic. A bounded ring per tier keeps probes
    /// O(ringCapacity) worst-case: nearest-rank over the freshest ≤ 64
    /// samples, the same estimator quality every other tier gets.
    private var modelWarmAggregates: [ModelWarmKey: Ring] = [:]
    private var modelAggregates: [String: Ring] = [:]
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
        let tierKey = ModelWarmKey(model: model, warm: warm)
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
            // Feed the fallback tiers on the same O(1) write path. The
            // aggregate key spaces (models × warmth, models) are strictly
            // smaller than the bucket key space, but cap them identically so
            // a hostile model-id mix can never outgrow the bucket bound.
            appendToAggregate(&modelWarmAggregates, key: tierKey, value: ttftMs)
            appendToAggregate(&modelAggregates, key: model, value: ttftMs)
        }
    }

    /// Append one sample to a fallback-tier ring, LRU-evicting whole tiers at
    /// the same ``maxBuckets`` cap the exact buckets use. Must run under the
    /// lock (shares `touchCounter`).
    private func appendToAggregate<K: Hashable>(
        _ aggregates: inout [K: Ring],
        key: K,
        value: Double
    ) {
        var ring = aggregates[key] ?? Ring()
        ring.append(value)
        ring.lastTouch = touchCounter
        if aggregates[key] == nil, aggregates.count >= Self.maxBuckets {
            if let victim = aggregates.min(by: { $0.value.lastTouch < $1.value.lastTouch })?.key {
                aggregates.removeValue(forKey: victim)
            }
        }
        aggregates[key] = ring
    }

    /// Quantile estimate with the documented fallback chain:
    /// exact bucket (high confidence at ≥ ``highConfidenceMinSamples``) →
    /// (model, warm) aggregate → model aggregate (both `.low`) → nil, in
    /// which case the caller quotes its benchmark/manifest-derived floor with
    /// `confidence = .low`.
    ///
    /// Every tier is a single dictionary lookup against a precomputed ring —
    /// an exact-bucket hit copies only its own ≤ ``ringCapacity`` samples and
    /// never touches the fallback tiers, so probe cost is independent of how
    /// many buckets the model has accumulated.
    public func estimate(
        model: String,
        warm: Bool,
        promptBucket: Int,
        batchBucket: Int
    ) -> Estimate? {
        let key = Key(
            model: model, warm: warm,
            promptBucket: promptBucket, batchBucket: batchBucket)
        let resolved = lock.withLock {
            () -> ([Double], CapacityQuoteConfidence)? in
            if let ring = buckets[key], !ring.samples.isEmpty {
                let confidence: CapacityQuoteConfidence =
                    ring.samples.count >= Self.highConfidenceMinSamples ? .high : .low
                return (ring.samples, confidence)
            }
            if let ring = modelWarmAggregates[ModelWarmKey(model: model, warm: warm)],
                !ring.samples.isEmpty
            {
                return (ring.samples, .low)
            }
            if let ring = modelAggregates[model], !ring.samples.isEmpty {
                return (ring.samples, .low)
            }
            return nil
        }
        guard let (samples, confidence) = resolved else { return nil }
        return Self.quantiles(samples, confidence: confidence)
    }

    /// Test seam for the boundedness contract: the sample count currently
    /// held by each fallback tier for `model`. Lets tests assert a probe can
    /// only ever touch bounded work (≤ ``ringCapacity`` per tier) without
    /// timing assertions.
    func aggregateSampleCounts(model: String, warm: Bool) -> (modelWarm: Int, model: Int) {
        lock.withLock {
            (modelWarmAggregates[ModelWarmKey(model: model, warm: warm)]?.samples.count ?? 0,
             modelAggregates[model]?.samples.count ?? 0)
        }
    }

    /// Nearest-rank quantiles over a copy of the samples. Every tier is a
    /// bounded ring, so this sorts ≤ ``ringCapacity`` doubles per probe;
    /// recording stays O(1).
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
