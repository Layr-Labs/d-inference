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

    /// Lower/upper clamp (GiB) for the auto-sized expert cache when the
    /// operator leaves `expert_cache_gb` at its default (0 = auto). 8 GiB is
    /// enough to keep a handful of hot experts resident; 70 GiB caps how much
    /// of a very large box the cache alone can claim, leaving room for KV +
    /// OS regardless of how much headroom the naive subtraction implies.
    public static let autoCacheFloorGb = 8.0
    public static let autoCacheCeilingGb = 70.0

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

    /// Auto-size the expert cache budget (GiB) from physical RAM and the
    /// resident-weights-only estimate (i.e. NOT including the cache itself —
    /// computing the cache from a resident estimate that already includes it
    /// would be circular). Leaves 24 GiB of headroom for KV cache + the OS on
    /// top of the resident weights, clamped to
    /// `[autoCacheFloorGb, autoCacheCeilingGb]` so a huge box doesn't let the
    /// cache alone crowd out all KV headroom, and a tight box still gets a
    /// usable minimum cache.
    public static func autoExpertCacheGb(
        physicalMemoryGb: Double,
        residentWeightsGb: Double,
        headroomGb: Double = 24.0
    ) -> Double {
        max(autoCacheFloorGb, min(autoCacheCeilingGb, physicalMemoryGb - residentWeightsGb - headroomGb))
    }

    /// The expert cache budget (GiB) to use: the operator's explicit
    /// `expert_cache_gb` when positive, otherwise the auto-sized value.
    public static func expertCacheGb(
        configuredGb: Double,
        physicalMemoryGb: Double,
        residentWeightsGb: Double
    ) -> Double {
        configuredGb > 0 ? configuredGb : autoExpertCacheGb(
            physicalMemoryGb: physicalMemoryGb, residentWeightsGb: residentWeightsGb)
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
        physicalMemoryGb: Double,
        configuredExpertCacheGb: Double,
        overheadFactor: Double = defaultOverheadFactor
    ) -> Estimate {
        let resident = residentWeightsGb(
            totalBytes: totalBytes, switchMlpBytes: switchMlpBytes, overheadFactor: overheadFactor)
        let cache = expertCacheGb(
            configuredGb: configuredExpertCacheGb, physicalMemoryGb: physicalMemoryGb,
            residentWeightsGb: resident)
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
