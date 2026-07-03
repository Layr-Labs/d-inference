/// ProviderLoop -- DeepSeek-V4 MoE expert SSD-streaming opt-in.
///
/// Configures mlx-swift-lm's module-level `DeepseekV4ExpertStreaming` (NOT
/// modified by this repo) before a model load, and sizes its expert cache
/// budget from `ExpertStreamingAdmission`'s pure math. Pulled out of
/// `ProviderLoop+ModelLoading.swift` so that file stays focused on the load
/// orchestration flow and this DeepSeek-V4-specific concern reads as its own
/// short, self-contained unit — same pattern as `BatchScheduler
/// +SequentialRawRunner.swift` for the DeepSeek-V4 sequential-serving route.

import Foundation
import MLXLLM
import ProviderCoreFoundation

/// Shared MoE expert-streaming configuration used by BOTH model-load paths:
/// `ProviderLoop` (coordinator-driven serving) and `StandaloneServer`
/// (`darkbloom local`). One process-wide side effect (the module-level
/// `DeepseekV4ExpertStreaming` opt-in) must be set consistently no matter
/// which path loads the container — a path that admits a streaming-sized
/// model (the scanner's estimate is config-aware for every caller) but loads
/// without configuring streaming would attempt a fully-resident 141 GB load.
public enum ExpertStreamingConfigurator {

    /// `config.json`'s `model_type`, or nil if it can't be read/parsed. Cheap,
    /// dependency-free check shared by the streaming opt-in below.
    static func modelType(at directory: URL) -> String? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["model_type"] as? String
    }

    static var bytesPerGiBDouble: Double { 1024.0 * 1024.0 * 1024.0 }

    /// Core of `ProviderLoop.configureDeepseekV4ExpertStreamingIfNeeded` (see
    /// that method's doc comment for semantics + the known static-let cache
    /// budget limitation). Returns the expert cache byte budget (0 when
    /// streaming is not enabled for this load).
    @discardableResult
    public static func configure(
        streamExperts: Bool,
        expertCacheGb: Double,
        modelDirectory: URL,
        log: (String) -> Void = { _ in }
    ) -> UInt64 {
        guard streamExperts, modelType(at: modelDirectory) == "deepseek_v4" else {
            MLXLLM.DeepseekV4ExpertStreaming.enabled = false
            return 0
        }

        // Header-only: sums `data_offsets` deltas from the safetensors shard
        // headers for `.ffn.switch_mlp.` keys, never reading tensor bytes.
        let switchMlpBytes = (try? SafetensorsSizing.sumTensorBytes(
            in: modelDirectory, matching: ExpertStreamingAdmission.isSwitchMlpKey)) ?? 0
        let (totalBytes, _) = ModelScanner.collectWeightFiles(in: modelDirectory)
        // Budget against the unified-memory CAP (min(0.90 × physical,
        // physical − 2 GiB)), never physical RAM — the expert cache lives
        // inside the same weights+KV+activations ≤ cap invariant everything
        // else in the provider enforces.
        let hardCapGb = Double(UnifiedMemoryCap.hardCapBytes()) / bytesPerGiBDouble
        let activationReserveGb =
            Double(UnifiedMemoryCap.activationReserveBytesForPlanning()) / bytesPerGiBDouble
        let estimate = ExpertStreamingAdmission.estimate(
            totalBytes: totalBytes, switchMlpBytes: switchMlpBytes,
            hardCapGb: hardCapGb, activationReserveGb: activationReserveGb,
            configuredExpertCacheGb: expertCacheGb)

        setenv("DSV4_EXPERT_CACHE_GB", String(format: "%.3f", estimate.expertCacheGb), 1)
        MLXLLM.DeepseekV4ExpertStreaming.modelDirectory = modelDirectory
        MLXLLM.DeepseekV4ExpertStreaming.enabled = true
        log(
            "MoE expert streaming enabled for \(modelDirectory.lastPathComponent): "
                + "resident≈\(String(format: "%.1f", estimate.residentWeightsGb))GB "
                + "expert_cache=\(String(format: "%.1f", estimate.expertCacheGb))GB "
                + "(switch_mlp on-disk≈\(switchMlpBytes / (1024 * 1024 * 1024))GB)")
        let cacheGb = max(0, estimate.expertCacheGb)
        let cacheBytesDouble = cacheGb * bytesPerGiBDouble
        return cacheBytesDouble >= Double(UInt64.max) ? .max : UInt64(cacheBytesDouble)
    }
}

extension ProviderLoop {

    /// See `ExpertStreamingConfigurator.modelType`. Kept as a shim because
    /// other ProviderLoop code refers to `Self.modelType`.
    static func modelType(at directory: URL) -> String? {
        ExpertStreamingConfigurator.modelType(at: directory)
    }

    /// Configure mlx-swift-lm's module-level MoE expert SSD streaming opt-in
    /// (`DeepseekV4ExpertStreaming` in `libs/mlx-swift-lm`, NOT modified by
    /// this repo) for this load, when `stream_experts` is on AND the model
    /// being loaded reports `model_type == "deepseek_v4"`. Must run BEFORE
    /// `LLMModelFactory.shared.loadContainer` — `DeepseekV4Model` reads
    /// `enabled`/`modelDirectory` while building each MoE layer.
    ///
    /// `DeepseekV4ExpertStreaming.enabled`/`.modelDirectory` are
    /// `nonisolated(unsafe) static var`s (process-wide, not per-model), so
    /// every load explicitly sets `enabled` (true OR false) rather than only
    /// setting it when true — a prior DeepSeek-V4 streaming load must not
    /// leak into a subsequent non-streaming load. This is harmless for
    /// unrelated model families today (only DeepSeek-V4's own construction/
    /// weight-sanitize code ever reads the flag), but keeping it correct
    /// costs nothing and avoids a future footgun if that changes.
    ///
    /// KNOWN LIMITATION (reported, not fixed — would require a mlx-swift-lm
    /// change): the expert cache's byte budget (`DeepseekV4ExpertStreaming
    /// .cache`) is a `static let`, lazily initialized from the
    /// `DSV4_EXPERT_CACHE_GB` env var on the FIRST process-wide access —
    /// there is no settable-budget API on the type. `setenv()` here works
    /// for the FIRST DeepSeek-V4 streaming load in this process's lifetime;
    /// if the operator changes `expert_cache_gb` and the provider later
    /// unloads/reloads the SAME (or another) DeepSeek-V4 model WITHOUT a
    /// process restart, the cache keeps the first load's budget. A full
    /// restart (`darkbloom restart`) picks up a new budget.
    ///
    /// Returns the configured expert cache byte budget (0 when streaming is
    /// not enabled for this load) — the caller threads it into
    /// `BatchScheduler.loadModel` so the static token-budget math accounts
    /// for the cache's eventual resident footprint (see
    /// `BatchScheduler.expertStreamingCacheBytes`).
    @discardableResult
    func configureDeepseekV4ExpertStreamingIfNeeded(modelDirectory: URL) -> UInt64 {
        let backend = loopConfig.config.backend
        return ExpertStreamingConfigurator.configure(
            streamExperts: backend.streamExperts,
            expertCacheGb: backend.expertCacheGb,
            modelDirectory: modelDirectory,
            log: { [logger] in logger.info("\($0)") })
    }

}
