// Copyright © 2026 Eigen Labs.
// Production scheduler settings, page dtype, and KV accounting rates.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

extension EngineV2Factory {
    public static let soloPrefillStripeKey = "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE"
    /// Largest expert-tile-qualified stripe for the top-8 MoE route.
    public static let defaultSoloPrefillStripeTokens = 2048
    /// Dense recurrent prefill can use a larger stripe without MoE tile limits.
    public static let defaultDenseQwenSoloPrefillStripeTokens = 4096

    public static let maxPartialPrefillsKey = "DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS"
    public static let defaultMaxConcurrentPartialPrefills: Int? = 1

    /// Absent means one partial prefill. Positive values override it; zero,
    /// negative, or malformed explicit values restore unlimited interleave.
    public static func maxConcurrentPartialPrefills(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = environment[maxPartialPrefillsKey] else {
            return defaultMaxConcurrentPartialPrefills
        }
        guard let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// The bounded first-token forecast is proved only for serialized prefill.
    /// Serving with another cap remains valid, but bypasses that forecast.
    static func prefillDeadlineProjectionSupported(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        maxConcurrentPartialPrefills(environment: environment) == 1
    }

    /// Absent selects the model default. An explicit value must exceed the plain
    /// chunk size; zero, malformed, or smaller values disable solo striping.
    public static func soloPrefillStripeTokens(
        abovePlainChunk plainChunk: Int,
        model: (any LanguageModel)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = environment[soloPrefillStripeKey] else {
            let defaultStripe = defaultSoloPrefillStripeTokens(for: model)
            return defaultStripe > plainChunk ? defaultStripe : nil
        }
        guard let value = Int(raw), value > plainChunk else { return nil }
        return value
    }

    static func defaultSoloPrefillStripeTokens(
        for model: (any LanguageModel)?
    ) -> Int {
        isDenseQwen35(model) ? defaultDenseQwenSoloPrefillStripeTokens : defaultSoloPrefillStripeTokens
    }

    /// MoE subclasses the dense target, so exclude it explicitly.
    static func isDenseQwen35(_ model: (any LanguageModel)?) -> Bool {
        model is Qwen35Model && !(model is Qwen35MoEModel)
    }

    public static let prefillChunkKey = "DARKBLOOM_CBV2_PREFILL_CHUNK"
    public static let stepTokenBudgetKey = "DARKBLOOM_CBV2_STEP_TOKENS"
    /// Plain chunk, and therefore the prompt work beside decode rows, for the
    /// family whose busy-engine serving and activation measurements back it
    /// (`usesWidePrefillChunk`).
    public static let widePrefillChunkTokens = 2048
    /// Largest bidirectional block a Gemma 4 request can carry: one image at
    /// the vision family's largest soft-token budget (catalog artifacts use
    /// 280; video frames about 70).
    static let gemma4MaximumMediaBlockTokens = 1120

    /// Prompt geometry resolved once per engine; the paged pool is sized from it.
    public struct PrefillGeometry: Equatable, Sendable {
        public let prefillChunkTokens: Int
        public let maxBatchedTokensPerStep: Int
        public let soloPrefillStripeTokens: Int?
        /// Plain chunk for requests with bidirectional media blocks, when it
        /// is narrower than `prefillChunkTokens`.
        public let bidirectionalMediaPrefillChunkCeiling: Int?
    }

    public static func prefillGeometry(
        model: (any LanguageModel)?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PrefillGeometry {
        var chunk = prefillChunkTokens(model: model, environment: environment)
        var stripe = soloPrefillStripeTokens(abovePlainChunk: chunk, model: model, environment: environment)
        // A chunk that starts at a bidirectional block covers the whole block,
        // and the paged window rings hold only max(chunk, stripe) tokens
        // (`PagedSequenceKV` preconditions it). Only overrides reach this; the
        // stripe was below the block, so it cannot arm above the raised chunk.
        if isGemma4(model), max(chunk, stripe ?? 0) < gemma4MaximumMediaBlockTokens {
            chunk = gemma4MaximumMediaBlockTokens
            stripe = nil
        }
        var budget = stepTokenBudget(abovePlainChunk: chunk, environment: environment)
        // Submit validation refuses a block longer than the step budget
        // (`CBv2MultimodalPlan.validate`), so the budget must hold one too.
        if isGemma4(model) {
            budget = max(budget, gemma4MaximumMediaBlockTokens)
        }
        let sdkChunk = CBv2SchedulerConfig().prefillChunkSize
        return PrefillGeometry(
            prefillChunkTokens: chunk,
            maxBatchedTokensPerStep: budget,
            soloPrefillStripeTokens: stripe,
            bidirectionalMediaPrefillChunkCeiling: chunk > sdkChunk ? sdkChunk : nil)
    }

    /// Gemma 4 only. GPT-OSS and dense Qwen3.5/3.8 also reached the first token
    /// sooner under it, but at eight 32k-token prompts it lifted their
    /// KV-subtracted activation peaks further above their activation floors
    /// (GPT-OSS 3.50 to 3.62 GiB against 3.5; Qwen3.5-9B 5.73 to 6.03 against
    /// 5.5), and floors move only with a platform-coordinated re-measurement.
    /// Nemotron and Bonsai demanded checkpoints split only an armed 2,048-token
    /// stripe; MoE Qwen's peak rises about 2 GiB; Qwen3-VL, Qwen4, MiMo and
    /// other families have no busy-engine measurement of it.
    static func usesWidePrefillChunk(_ model: (any LanguageModel)?) -> Bool {
        isGemma4(model)
    }

    static func isGemma4(_ model: (any LanguageModel)?) -> Bool {
        model is Gemma4Model || model is Gemma4TextModel || model is MLXVLM.Gemma4
    }

    /// Absent selects the family default. A positive explicit value applies to
    /// every model (Gemma 4 raises it to cover a media block, `prefillGeometry`);
    /// zero, negative, or malformed values restore the SDK chunk.
    static func prefillChunkTokens(
        model: (any LanguageModel)?, environment: [String: String]
    ) -> Int {
        let sdkChunk = CBv2SchedulerConfig().prefillChunkSize
        guard let raw = environment[prefillChunkKey] else {
            return usesWidePrefillChunk(model) ? widePrefillChunkTokens : sdkChunk
        }
        guard let value = Int(raw), value > 0 else { return sdkChunk }
        return value
    }

    /// Absent selects twice the plain chunk, never below the SDK budget, so a
    /// full chunk and a finishing row's remainder fit beside decode rows. An
    /// explicit value must cover the plain chunk; smaller, zero, negative, or
    /// malformed values restore the SDK budget, raised to the plain chunk.
    static func stepTokenBudget(
        abovePlainChunk plainChunk: Int, environment: [String: String]
    ) -> Int {
        let sdkBudget = CBv2SchedulerConfig().maxBatchedTokensPerStep
        guard let raw = environment[stepTokenBudgetKey] else {
            let (doubled, overflow) = plainChunk.multipliedReportingOverflow(by: 2)
            return max(sdkBudget, overflow ? Int.max : doubled)
        }
        guard let value = Int(raw), value >= plainChunk else {
            return max(sdkBudget, plainChunk)
        }
        return value
    }

    /// One scheduler config sizes the paged pool and runs the engine. Keeping it
    /// on the backend preparation prevents chunk geometry from drifting.
    static func productionSchedulerConfig(
        maxConcurrentRequests: Int,
        model: (any LanguageModel)? = nil,
        modelID: String? = nil,
        performanceProfile: ServingPerformanceProfile? = nil,
        environment: [String: String]
    ) -> CBv2SchedulerConfig {
        let geometry = prefillGeometry(model: model, environment: environment)
        var config = CBv2SchedulerConfig(
            maxConcurrentRequests: nativeConcurrentRequestLimit(
                requested: maxConcurrentRequests, model: model, environment: environment),
            maxBatchedTokensPerStep: geometry.maxBatchedTokensPerStep,
            prefillChunkSize: geometry.prefillChunkTokens,
            soloPrefillStripeTokens: geometry.soloPrefillStripeTokens)
        // Paged span-bearing chunks attend unblocked, so bidirectional media keeps the SDK chunk.
        config.bidirectionalMediaPrefillChunkCeiling = geometry.bidirectionalMediaPrefillChunkCeiling
        config.mixedStepPrefillTokenCap = MixedPrefillPolicy.resolve(
            modelID: modelID, profile: performanceProfile, environment: environment,
            requiresNarrowingFloor: isGemma4(model))
        config.maxConcurrentPartialPrefills =
            Self.maxConcurrentPartialPrefills(environment: environment)
        if let limit = calibratedPrefillTokenLimit(model: model) {
            // Calibrated W4A4/FP8 workspace is a hard execution bound, not a
            // throughput preference. Environment/profile overrides cannot widen it.
            let limit = max(1, limit)
            config.prefillChunkSize = min(config.prefillChunkSize, limit)
            config.soloPrefillStripeTokens = nil
            config.mixedStepPrefillTokenCap = min(config.mixedStepPrefillTokenCap ?? limit, limit)
        }
        return config
    }

    /// The single source of GLM step geometry; the paged backend's query bound,
    /// the engine's step-scratch envelope and the scheduler all derive from it.
    /// The native engine prices one worst-case step at setup and refuses
    /// activation when it exceeds the post-load envelope (about 56.8 GB on a
    /// 256 GiB host, shared with KV). A prefill-sized paged row reads its
    /// latent history once per DSA layer instead of retaining ~46 MB of
    /// selected latents per query token. The price is a setup amount for the
    /// step geometry plus a rate per context token of each request
    /// (`GLM5NextStepScratch`), which the engine charges for the history its
    /// pool can hold (GLM5NextStepPriceTests); the provider caps running rows
    /// to what that check admits (`glm5NextActivatableRows`).
    static let glm5NextMaximumPrefillChunkTokens = 2048
    static let glm5NextMaximumStepTokens = 2048
    /// Narrows both GLM limits for a test whose small fixture context must
    /// still span a chunk boundary; it can never widen them.
    #if DEBUG
    @TaskLocal static var glm5NextStepTokensForTesting: Int?
    #endif

    /// Installs the GLM chunk and step limits, bounded by the context; the
    /// generic 512-token default chunk is not GLM's geometry. Solo stripes,
    /// including an operator override, are always disabled.
    static func glm5NextServingScheduler(_ base: CBv2SchedulerConfig, context: Int)
        -> CBv2SchedulerConfig
    {
        var scheduler = base
        #if DEBUG
        let narrowed = max(1, glm5NextStepTokensForTesting ?? Int.max)
        #else
        let narrowed = Int.max
        #endif
        scheduler.prefillChunkSize = min(context, glm5NextMaximumPrefillChunkTokens, narrowed)
        scheduler.maxBatchedTokensPerStep = min(context, glm5NextMaximumStepTokens, narrowed)
        scheduler.soloPrefillStripeTokens = nil
        scheduler.soloPrefillStripeMediaCeiling = nil
        return scheduler
    }

    /// Names every native reason the protected GLM engine stayed inactive, with
    /// the step geometry it was priced at, so a refused load (for example a
    /// step-scratch `capacityExhausted(needed:available:)`) is diagnosable from
    /// the error and logs. Nil when the engine activated its issued tuple.
    static func glm5NextActivationRefusal(
        mtpInactiveReason: String?, pagedAttentionWorkInactiveReason: String?,
        nativeCompletionFault: String?, scheduler: CBv2SchedulerConfig
    ) -> String? {
        let reasons = [
            mtpInactiveReason.map { "mtp: \($0)" },
            pagedAttentionWorkInactiveReason.map { "paged attention work: \($0)" },
            nativeCompletionFault.map { "native completion fault: \($0)" },
        ].compactMap { $0 }
        guard !reasons.isEmpty else { return nil }
        return "GLM protected engine did not activate its issued tuple: "
            + reasons.joined(separator: "; ")
            + " [max_concurrent_requests=\(scheduler.maxConcurrentRequests)"
            + " step_tokens=\(scheduler.maxBatchedTokensPerStep)"
            + " prefill_chunk_tokens=\(scheduler.prefillChunkSize)]"
    }

    /// Calibrated ModelOpt workspace bound of a Nemotron target, if it has one.
    static func calibratedPrefillTokenLimit(model: (any LanguageModel)?) -> Int? {
        (model as? NemotronHModel)?.calibratedPrefillTokenLimit
            ?? (model as? NemotronSuperRecurrentAdapter)?.calibratedPrefillTokenLimit
            ?? (model as? NemotronSuperMTPTextTarget)?.calibratedPrefillTokenLimit
    }

    static let qwen4BatchedQSAEnvKey = "DARKBLOOM_QWEN4_BATCHED_QSA"

    /// Install the serving policy on the exact target before backend probes
    /// and admission. Prepared models may have been constructed under a
    /// different process environment than this provider's injected policy.
    static func configureNativeQwen4Batching(
        model: any LanguageModel, environment: [String: String]
    ) throws {
        if let limit = calibratedPrefillTokenLimit(model: model), limit <= 0 {
            throw CBv2KVError.backendIneligible(reason: "calibrated Nemotron workspace cannot fit one token")
        }
        guard let target = model as? any CBv2Qwen4BatchCapabilityConfiguring else { return }
        let enabled = environment[qwen4BatchedQSAEnvKey] == "1"
        do {
            try target.cbv2InstallQwen4BatchedAttention(enabled: enabled)
        } catch {
            throw CBv2KVError.backendIneligible(reason: "Qwen4 batching policy is already sealed for this target")
        }
        guard target.cbv2Qwen4BatchedAttentionEnabled == enabled else {
            throw CBv2KVError.backendIneligible(reason: "Qwen4 batching capability could not be installed")
        }
    }

    static func nativeConcurrentRequestLimit(
        requested: Int,
        model: (any LanguageModel)?,
        environment: [String: String]
    ) -> Int {
        let qwen4 = model is Qwen4ExpModel || model is Qwen4ExpTextModel || model is MLXVLM.Qwen4Exp
        guard qwen4 else { return max(1, requested) }
        let installedLimit = (model as? any CBv2Qwen4BatchCapabilityConfiguring)?
            .cbv2Qwen4MaximumBatchRows ?? 1
        return environment[qwen4BatchedQSAEnvKey] == "1" ? min(max(1, requested), installedLimit) : 1
    }

    /// Qwen4 remains single-row unless the native batched-QSA candidate is
    /// explicitly enabled. The provider's outer 1...8 policy still bounds the
    /// requested cap; enabling this candidate does not qualify concurrent serving.
    static func nativeConcurrentRequestLimit(
        requested: Int,
        qwen4: Bool,
        environment: [String: String]
    ) -> Int {
        guard qwen4 else { return max(1, requested) }
        return environment[qwen4BatchedQSAEnvKey] == "1"
            ? min(max(1, requested), CBv2Qwen4BatchPolicy.maximumCandidateRows) : 1
    }

    static let pagedPoolDTypeEnvKey = "DARKBLOOM_CBV2_PAGED_KV_DTYPE"

    /// Paged measurement override: empty/unset means float16; float32 doubles page
    /// bytes. Invalid values throw so a control arm cannot silently run as fp16.
    /// Only resolved-paged builds read this setting; contiguous builds ignore it.
    static func pagedPoolDType(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DType {
        guard let raw = environment[pagedPoolDTypeEnvKey] else { return .float16 }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "float16": return .float16
        case "float32": return .float32
        default: throw EngineV2ProductionError.invalidPagedPoolDType(raw)
        }
    }

    /// Use the same dtype spelling in configuration and benchmark artifacts.
    static func pagedPoolDTypeName(_ dtype: DType) -> String {
        switch dtype {
        case .float16: return "float16"
        case .float32: return "float32"
        default: return "\(dtype)"
        }
    }

    static let legacyRequestTimeoutEnvKey = "DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT"

    /// Emergency rollback to a single request-lifetime deadline. Only affirmative
    /// values arm it; absence or malformed values retain monotonic phase leases.
    static func legacyRequestTimeoutEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[legacyRequestTimeoutEnvKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Clamp negative capacity to zero and bound the admission ceiling by physical RAM.
    static func clampKVBytesCapacity(
        _ kvBytesCapacity: Int,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let physicalCap = Int(min(physicalBytes, UInt64(Int.max)))
        return min(max(0, kvBytesCapacity), physicalCap)
    }

    /// Fallback for callers without observed native types; production slots
    /// always supply them. GPT-OSS contiguous owning-full rows are charged as
    /// fp32 by adding their fp16 byte rate once, which over-reserves bf16 rows.
    /// Other contiguous rows retain the nominal rate; overflow saturates safely.
    static func nativeKVBytesPerToken(
        nominalFP16BytesPerToken: Int,
        fp16FullKVBytesPerToken: Int,
        fullRowsUseFP32: Bool
    ) -> Int {
        guard nominalFP16BytesPerToken > 0 else { return 0 }
        guard fullRowsUseFP32 else { return nominalFP16BytesPerToken }
        guard fp16FullKVBytesPerToken >= 0 else { return Int.max }
        let (nativeRate, overflow) = nominalFP16BytesPerToken.addingReportingOverflow(
            fp16FullKVBytesPerToken)
        return overflow ? Int.max : nativeRate
    }

    /// Paged fp32 doubles every row, including sliding windows. This differs from
    /// the full-row-only contiguous adjustment and must reach advertised budgets.
    /// The two adjustments are mutually exclusive on a resolved production backend.
    static func processKVBytesPerToken(
        nominalFP16BytesPerToken: Int,
        fp16FullKVBytesPerToken: Int,
        fullRowsUseFP32: Bool,
        pagedPoolDType: String?
    ) -> Int {
        let base = nativeKVBytesPerToken(
            nominalFP16BytesPerToken: nominalFP16BytesPerToken,
            fp16FullKVBytesPerToken: fp16FullKVBytesPerToken,
            fullRowsUseFP32: fullRowsUseFP32)
        guard pagedPoolDType == pagedPoolDTypeName(.float32) else { return base }
        let (doubled, overflow) = base.multipliedReportingOverflow(by: 2)
        return overflow ? Int.max : doubled
    }
}

extension EngineV2Factory.PrefillGeometry {
    /// The geometry a built scheduler configuration carries.
    init(scheduler: CBv2SchedulerConfig) {
        self.init(
            prefillChunkTokens: scheduler.prefillChunkSize,
            maxBatchedTokensPerStep: scheduler.maxBatchedTokensPerStep,
            soloPrefillStripeTokens: scheduler.soloPrefillStripeTokens,
            bidirectionalMediaPrefillChunkCeiling: scheduler.bidirectionalMediaPrefillChunkCeiling)
    }
}
