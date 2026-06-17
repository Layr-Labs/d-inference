import Foundation

/// Pure, dependency-free memory-bandwidth model for autoregressive *decode* on
/// Apple Silicon unified memory.
///
/// Single-stream (batch ≈ 1) decode on Apple Silicon is almost entirely
/// **memory-bandwidth-bound on the model weights that are read for each token**,
/// not compute-bound. One decode step does a handful of matrix-vector products,
/// so the GPU spends its time streaming weight bytes out of unified memory:
///
///     read_bytes_per_token ≈ active_params × bytes_per_param
///     decode_tok_s         ≈ (bandwidth_GBps × efficiency) / read_GB_per_token
///
/// For a **dense** model every weight is active for every token, so
/// `active_params == total_params`. For a **Mixture-of-Experts (MoE)** model
/// only the shared trunk plus the routed top-K experts are read per token, so
/// `active_params` is a small fraction of `total_params`.
///
/// This lets the throughput benchmark invert a *measured* decode tok/s into the
/// **implied bytes-per-token / active-param count** the hardware must have
/// moved, and compare that against the dense-total and 4B-active references —
/// i.e. answer "is this MoE actually decoding sparsely, or as if it were
/// dense?". See `docs/gemma-decode-bandwidth-analysis.md`.
///
/// Everything here is pure arithmetic (Foundation only, no MLX) so it is unit
/// testable without a GPU or model weights.
public enum DecodeBandwidthModel {

    // MARK: - Bytes per parameter

    /// Effective bytes per weight element for 4-bit group quantization.
    /// 4 bits of payload + per-group scale (and optional zero/bias): for a
    /// 16-bit scale over a group of 64 that is `4 + 16/64 = 4.25` bits; with a
    /// zero-point it rises toward ~4.5–4.8 bits. 4.5 bits = 0.5625 bytes is a
    /// reasonable midpoint of the commonly quoted 0.50–0.60 B/param range.
    public static let fourBitBytesPerParam = 0.5625
    /// Effective bytes per weight element for 8-bit group quantization
    /// (8 bits + ~0.5 bits of group scale ≈ 8.5 bits).
    public static let eightBitBytesPerParam = 1.0625
    /// bf16 / fp16 weights.
    public static let halfBytesPerParam = 2.0

    /// Map a quantization bit width to effective bytes-per-param. `nil` (or an
    /// unrecognized width) falls back to 4-bit, the Darkbloom production case.
    public static func bytesPerParam(forQuantBits bits: Int?) -> Double {
        switch bits {
        case 4: return fourBitBytesPerParam
        case 8: return eightBitBytesPerParam
        case 16: return halfBytesPerParam
        default: return fourBitBytesPerParam
        }
    }

    // MARK: - Efficiency

    /// Fraction of *peak* unified-memory bandwidth that a well-pipelined MLX
    /// decode loop actually sustains. Empirically ~0.70–0.85 on Apple Silicon
    /// (the rest is lost to launch latency, non-weight traffic, and imperfect
    /// overlap). 0.80 is a defensible default for interpreting a measurement.
    public static let defaultBandwidthEfficiency = 0.80

    // MARK: - Forward model (params → tok/s)

    /// Weight bytes that must be read per generated token, in GB (1e9 bytes).
    public static func readGBPerToken(activeParams: Double, bytesPerParam: Double) -> Double {
        guard activeParams > 0, bytesPerParam > 0 else { return 0 }
        return activeParams * bytesPerParam / 1e9
    }

    /// Predicted single-stream decode tok/s for a given active-param count.
    public static func expectedDecodeTokensPerSecond(
        activeParams: Double,
        bytesPerParam: Double = fourBitBytesPerParam,
        bandwidthGBps: Double,
        efficiency: Double = defaultBandwidthEfficiency
    ) -> Double {
        let readGB = readGBPerToken(activeParams: activeParams, bytesPerParam: bytesPerParam)
        guard readGB > 0 else { return 0 }
        return bandwidthGBps * efficiency / readGB
    }

    // MARK: - Inverse model (measured tok/s → implied bytes / params)

    /// Invert a measured decode tok/s into the per-token weight read (GB) the
    /// hardware must have moved, given an assumed sustained-bandwidth
    /// efficiency. This is the headline discriminator: compare it to the
    /// model's *total* weight GB (dense ⇒ ≈ total) and to the 4B-active
    /// reference (sparse ⇒ ≈ that).
    public static func impliedReadGBPerToken(
        decodeTokensPerSecond: Double,
        bandwidthGBps: Double,
        efficiency: Double = defaultBandwidthEfficiency
    ) -> Double {
        guard decodeTokensPerSecond > 0, bandwidthGBps > 0 else { return 0 }
        return bandwidthGBps * efficiency / decodeTokensPerSecond
    }

    /// Invert a measured decode tok/s into the implied number of active weight
    /// *elements* read per token (`impliedReadBytes / bytesPerParam`).
    public static func impliedActiveParams(
        decodeTokensPerSecond: Double,
        bandwidthGBps: Double,
        bytesPerParam: Double = fourBitBytesPerParam,
        efficiency: Double = defaultBandwidthEfficiency
    ) -> Double {
        guard bytesPerParam > 0 else { return 0 }
        let readGB = impliedReadGBPerToken(
            decodeTokensPerSecond: decodeTokensPerSecond,
            bandwidthGBps: bandwidthGBps,
            efficiency: efficiency
        )
        return readGB * 1e9 / bytesPerParam
    }

    // MARK: - Regime classification

    /// Whether the implied per-token read looks like the model is reading all
    /// of its weights (`dense`) or only a small slice (`sparse`).
    public enum DecodeRegime: String, Codable, Sendable {
        /// Per-token read ≈ the model's full weight footprint — the MoE is
        /// behaving as if it were a dense model of the same total size.
        case dense
        /// Per-token read ≪ the full footprint — expert sparsity is exploited.
        case sparse
        /// Between the two thresholds — heavier than ideal-sparse but not
        /// reading the entire model.
        case intermediate
    }

    /// Classify by the fraction `implied_read / total_weight`.
    /// ≥ `denseThreshold` ⇒ `.dense`; ≤ `sparseThreshold` ⇒ `.sparse`.
    public static func classifyRegime(
        impliedReadGB: Double,
        totalWeightGB: Double,
        denseThreshold: Double = 0.6,
        sparseThreshold: Double = 0.3
    ) -> DecodeRegime {
        guard totalWeightGB > 0, impliedReadGB > 0 else { return .intermediate }
        let frac = impliedReadGB / totalWeightGB
        if frac >= denseThreshold { return .dense }
        if frac <= sparseThreshold { return .sparse }
        return .intermediate
    }

    // MARK: - Batch-scaling discriminator

    /// Batch-scaling linearity: how closely aggregate decode tok/s tracks
    /// *ideal* linear scaling (`B ×` the B=1 rate), averaged over the B>1
    /// points. Defined as the mean of `(aggregate(B)/aggregate(1)) / B`.
    ///
    /// Interpretation (only meaningful when B=1 is already
    /// memory-bandwidth-bound — true for ≥20B models, not tiny ones whose B=1
    /// is launch-overhead-bound):
    ///   * **≈ 1.0** — a single shared weight read is amortized across the
    ///     whole batch ⇒ behaves **dense** (one weight set per step).
    ///   * **< 1.0** — adding sequences pulls in *additional* distinct experts,
    ///     so the per-step weight read grows with B ⇒ behaves **sparse**.
    ///
    /// Returns `nil` when there is no B=1 anchor or no B>1 points.
    public static func batchScalingLinearity(
        aggregateByBatch: [(batchSize: Int, aggregateTokensPerSecond: Double)]
    ) -> Double? {
        guard let base = aggregateByBatch.first(where: { $0.batchSize == 1 })?.aggregateTokensPerSecond,
              base > 0 else { return nil }
        let ratios = aggregateByBatch
            .filter { $0.batchSize > 1 && $0.aggregateTokensPerSecond > 0 }
            .map { ($0.aggregateTokensPerSecond / base) / Double($0.batchSize) }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count)
    }
}
