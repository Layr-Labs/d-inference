import Foundation

/// Pure memory-admission math for DeepSeek-V4 MoE-expert SSD streaming
/// (`DeepseekV4ExpertStreaming` in `libs/mlx-swift-lm`, read-only from this
/// repo's side).
///
/// `ModelScanner`'s ordinary `estimatedMemoryGb` (see
/// `ModelScanner+Discovery.swift`) sizes a model from its FULL on-disk
/// footprint × `memoryOverheadFactor` — correct for a resident load, but
/// wildly wrong once streaming skips loading the ~125 GB of routed-expert
/// (`switch_mlp`) tensors: 141 GB × 1.2 ≈ 169 GB would refuse to load on a
/// 128 GB box even though the actual resident footprint (weights minus
/// streamed experts, plus a bounded expert cache) easily fits.
///
/// When streaming will be active for a model, the true resident estimate is:
///
///   resident ≈ (totalBytes − switchMlpBytes) × overheadFactor + expertCacheBudget
///
/// All functions here are pure (no I/O, no MLX) so the arithmetic is
/// unit-testable without a model on disk.
public enum ExpertStreamingAdmission {

    /// Same overhead multiplier `ModelScanner` applies for KV cache /
    /// activation buffers on a resident load. Kept as an explicit default
    /// (not a shared constant) so this file has zero dependency on
    /// `ModelScanner`, which lives in `ProviderCore` (this file is
    /// Foundation-only / Linux-buildable).
    public static let defaultOverheadFactor = 1.2

    /// Upper clamp (GiB) for the auto-sized expert cache when the operator
    /// leaves `expert_cache_gb` at its default (0 = auto). Caps how much of a
    /// very large box the cache alone can claim; there is deliberately NO
    /// floor — the cache must never be sized past what the unified-memory cap
    /// leaves over (a floor on a small box would push
    /// `resident + cache` OVER the cap, so the scanner would advertise a model
    /// the post-load serveability guard then unloads). A tiny (even zero)
    /// cache still serves correctly, just with more cold-miss disk reads.
    public static let autoCacheCeilingGb = 70.0

    /// KV-cache room (GiB) the auto-sizer reserves under the cap before
    /// giving the remainder to the expert cache. Deliberately larger than
    /// `UnifiedMemoryCap`'s 1 GiB minimum-serveable floor: a serving box
    /// wants real context room, and shrinking the expert cache only costs
    /// throughput (more disk reads) while shrinking KV costs ADMISSION
    /// (requests reject). When even this can't be met, the cache goes to 0
    /// and the load-time serveability guard remains the final arbiter.
    public static let autoCacheKVTargetGb = 8.0

    /// Bytes-per-GiB used throughout (binary GiB, matching `ModelScanner`).
    public static let bytesPerGiB = 1024.0 * 1024.0 * 1024.0

    /// Resident weight estimate (GiB) once routed-expert tensors are streamed
    /// instead of loaded resident: the non-expert on-disk bytes, times the
    /// same overhead factor a normal resident load uses. `switchMlpBytes`
    /// clamps to `totalBytes` (a mis-measured/over-counted index can never
    /// make this negative).
    public static func residentWeightsGb(
        totalBytes: UInt64,
        switchMlpBytes: UInt64,
        overheadFactor: Double = defaultOverheadFactor
    ) -> Double {
        let nonExpertBytes = switchMlpBytes < totalBytes ? totalBytes - switchMlpBytes : 0
        return (Double(nonExpertBytes) / bytesPerGiB) * overheadFactor
    }

    /// Auto-size the expert cache budget (GiB) UNDER THE UNIFIED-MEMORY CAP.
    ///
    /// The provider may never plan against physical RAM: `UnifiedMemoryCap`
    /// grants MLX at most `min(0.90 × physical, physical − 2 GiB)` for
    /// EVERYTHING (weights + KV + activations), and the expert cache is
    /// MLX-resident memory like any other weights. So the budget is what the
    /// CAP leaves after the resident weights, the activation reserve, and a
    /// real KV allowance — never a subtraction from physical RAM (which
    /// over-grants by the OS share) and never floored (a floor would push
    /// `resident + cache` past the cap on small boxes, admitting a model the
    /// post-load serveability guard immediately unloads).
    ///
    /// `hardCapGb`/`activationReserveGb` are parameters (not read here)
    /// because this file is Foundation-only and `UnifiedMemoryCap` lives in
    /// `ProviderCore` — callers pass `UnifiedMemoryCap.hardCapBytes()` /
    /// `loadHeadroomBytes()`-derived values so there is exactly one source of
    /// truth for the cap arithmetic.
    public static func autoExpertCacheGb(
        hardCapGb: Double,
        residentWeightsGb: Double,
        activationReserveGb: Double,
        kvTargetGb: Double = autoCacheKVTargetGb
    ) -> Double {
        let available = hardCapGb - residentWeightsGb - activationReserveGb - kvTargetGb
        return max(0, min(autoCacheCeilingGb, available))
    }

    /// The expert cache budget (GiB) to use: the operator's explicit
    /// `expert_cache_gb` when positive — clamped so even an operator typo can
    /// never size the cache past what the cap leaves above the resident
    /// weights + activation reserve + minimum serveable KV — otherwise the
    /// cap-derived auto size.
    public static func expertCacheGb(
        configuredGb: Double,
        hardCapGb: Double,
        residentWeightsGb: Double,
        activationReserveGb: Double,
        minimumKVGb: Double = 1.0
    ) -> Double {
        if configuredGb > 0 {
            let ceiling = max(
                0, hardCapGb - residentWeightsGb - activationReserveGb - minimumKVGb)
            return min(configuredGb, ceiling)
        }
        return autoExpertCacheGb(
            hardCapGb: hardCapGb, residentWeightsGb: residentWeightsGb,
            activationReserveGb: activationReserveGb)
    }

    /// Full streaming-aware memory estimate for a model: resident weights
    /// (non-expert bytes) plus the expert cache budget.
    public struct Estimate: Sendable, Equatable {
        public let residentWeightsGb: Double
        public let expertCacheGb: Double
        public var totalGb: Double { residentWeightsGb + expertCacheGb }

        public init(residentWeightsGb: Double, expertCacheGb: Double) {
            self.residentWeightsGb = residentWeightsGb
            self.expertCacheGb = expertCacheGb
        }
    }

    public static func estimate(
        totalBytes: UInt64,
        switchMlpBytes: UInt64,
        hardCapGb: Double,
        activationReserveGb: Double,
        configuredExpertCacheGb: Double,
        overheadFactor: Double = defaultOverheadFactor
    ) -> Estimate {
        let resident = residentWeightsGb(
            totalBytes: totalBytes, switchMlpBytes: switchMlpBytes, overheadFactor: overheadFactor)
        let cache = expertCacheGb(
            configuredGb: configuredExpertCacheGb, hardCapGb: hardCapGb,
            residentWeightsGb: resident, activationReserveGb: activationReserveGb)
        return Estimate(residentWeightsGb: resident, expertCacheGb: cache)
    }

    /// Whether a tensor key belongs to the routed-expert weights DeepSeek-V4
    /// streaming skips loading resident. Mirrors
    /// `DeepseekV4Model.shouldStreamWeight` / the `sanitize` filter in
    /// `libs/mlx-swift-lm/Libraries/MLXLLM/Models/DeepseekV4.swift` EXACTLY
    /// (read-only reference — not modified): MTP layers (`mtp.` prefix)
    /// always stay resident, everything else matching `.ffn.switch_mlp.`
    /// streams.
    public static func isSwitchMlpKey(_ key: String) -> Bool {
        !key.hasPrefix("mtp.") && key.contains(".ffn.switch_mlp.")
    }
}
