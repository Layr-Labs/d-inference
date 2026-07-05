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

    /// Result of `configure(...)`: whether THIS load configured MoE expert
    /// SSD streaming, plus the resulting cache byte budget.
    ///
    /// `enabled` is intentionally its own field rather than something a
    /// caller derives from `cacheBytes > 0` or from
    /// `BatchScheduler.requiresSequentialServing`: the latter is set for
    /// EVERY DeepSeek-V4 load (its cache layout isn't representable by the
    /// batched engine) whether or not streaming is active, so it is
    /// correlated with but independent of "does this load's teardown need
    /// to purge the shared expert cache" — using it as a proxy would purge
    /// (or skip purging) incorrectly whenever streaming is off/on out of
    /// step with sequential-serving.
    public struct ConfigurationResult: Sendable, Equatable {
        public let enabled: Bool
        public let cacheBytes: UInt64

        public init(enabled: Bool, cacheBytes: UInt64) {
            self.enabled = enabled
            self.cacheBytes = cacheBytes
        }
    }

    /// Core of `ProviderLoop.configureDeepseekV4ExpertStreamingIfNeeded` (see
    /// that method's doc comment for semantics). Returns whether this load
    /// configured streaming plus the expert cache byte budget (0/false when
    /// streaming is not enabled for this load).
    @discardableResult
    public static func configure(
        streamExperts: Bool,
        expertCacheGb: Double,
        modelDirectory: URL,
        log: (String) -> Void = { _ in }
    ) -> ConfigurationResult {
        guard streamExperts, modelType(at: modelDirectory) == "deepseek_v4" else {
            MLXLLM.DeepseekV4ExpertStreaming.enabled = false
            return ConfigurationResult(enabled: false, cacheBytes: 0)
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

        let cacheGb = max(0, estimate.expertCacheGb)
        let cacheBytesDouble = cacheGb * bytesPerGiBDouble
        let cacheBytes: UInt64 = cacheBytesDouble >= Double(UInt64.max) ? .max : UInt64(cacheBytesDouble)

        MLXLLM.DeepseekV4ExpertStreaming.modelDirectory = modelDirectory
        MLXLLM.DeepseekV4ExpertStreaming.enabled = true
        // Resize the shared cache directly rather than relying solely on
        // `setenv` + the cache's lazy first-touch initialization: a provider
        // that already streamed a DeepSeek-V4 model earlier in this process's
        // lifetime has a live `DeepseekV4ExpertStreaming.cache` whose budget
        // this call must be able to change (e.g. the operator reconfigured
        // `expert_cache_gb` between loads). `setenv` is kept too — it's the
        // ONLY way a separate process (the DSV4Smoke CLI harness) picks up
        // the budget, and it keeps the cache's bootstrap value correct for
        // the very first access in THIS process if that ever races ahead of
        // this call for some reason.
        setenv("DSV4_EXPERT_CACHE_GB", String(format: "%.3f", estimate.expertCacheGb), 1)
        MLXLLM.DeepseekV4ExpertStreaming.setCacheBudgetBytes(Int(clamping: cacheBytes))
        log(
            "MoE expert streaming enabled for \(modelDirectory.lastPathComponent): "
                + "resident≈\(String(format: "%.1f", estimate.residentWeightsGb))GB "
                + "expert_cache=\(String(format: "%.1f", estimate.expertCacheGb))GB "
                + "(switch_mlp on-disk≈\(switchMlpBytes / (1024 * 1024 * 1024))GB)")
        return ConfigurationResult(enabled: true, cacheBytes: cacheBytes)
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
    /// The expert cache's byte budget is resized directly via
    /// `DeepseekV4ExpertStreaming.setCacheBudgetBytes(_:)` on every call
    /// (not just the first) — a provider that unloads/reloads a DeepSeek-V4
    /// model with a different configured `expert_cache_gb` gets the new
    /// budget immediately, no process restart required. (Previously the
    /// cache was a `static let` sized once from `DSV4_EXPERT_CACHE_GB` on
    /// first access, with no settable-budget API — see mlx-swift-lm's
    /// `ExpertCache.setByteBudget`/`DeepseekV4ExpertStreaming
    /// .setCacheBudgetBytes`.)
    ///
    /// Returns whether this load configured streaming plus the expert cache
    /// byte budget (false/0 when streaming is not enabled for this load).
    /// The caller threads BOTH into `BatchScheduler.loadModel`: the byte
    /// budget so the static token-budget math accounts for the cache's
    /// eventual resident footprint (see `BatchScheduler
    /// .expertStreamingCacheBytes`), and the enabled flag so
    /// `stopCurrentEngine()` knows whether to purge the shared cache when
    /// THIS model unloads (see `BatchScheduler.expertStreamingConfigured`).
    @discardableResult
    func configureDeepseekV4ExpertStreamingIfNeeded(
        modelDirectory: URL
    ) -> ExpertStreamingConfigurator.ConfigurationResult {
        let backend = loopConfig.config.backend
        return ExpertStreamingConfigurator.configure(
            streamExperts: backend.streamExperts,
            expertCacheGb: backend.expertCacheGb,
            modelDirectory: modelDirectory,
            log: { [logger] in logger.info("\($0)") })
    }

}
