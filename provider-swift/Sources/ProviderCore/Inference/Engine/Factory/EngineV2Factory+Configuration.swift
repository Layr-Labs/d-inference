// Copyright © 2026 Eigen Labs.
// Production scheduler settings, page dtype, and KV accounting rates.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

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
        guard let model else { return defaultSoloPrefillStripeTokens }
        // MoE subclasses the dense target, so exclude it explicitly.
        if model is Qwen35Model, !(model is Qwen35MoEModel) {
            return defaultDenseQwenSoloPrefillStripeTokens
        }
        return defaultSoloPrefillStripeTokens
    }

    /// One scheduler config sizes the paged pool and runs the engine. Keeping it
    /// on the backend preparation prevents chunk geometry from drifting.
    static func productionSchedulerConfig(
        maxConcurrentRequests: Int,
        model: (any LanguageModel)? = nil,
        environment: [String: String]
    ) -> CBv2SchedulerConfig {
        var config = CBv2SchedulerConfig(
            maxConcurrentRequests: max(1, maxConcurrentRequests))
        config.soloPrefillStripeTokens = Self.soloPrefillStripeTokens(
            abovePlainChunk: config.prefillChunkSize,
            model: model,
            environment: environment)
        config.maxConcurrentPartialPrefills =
            Self.maxConcurrentPartialPrefills(environment: environment)
        return config
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

    /// GPT-OSS contiguous owning-full rows use fp32: add their fp16 byte rate once.
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
