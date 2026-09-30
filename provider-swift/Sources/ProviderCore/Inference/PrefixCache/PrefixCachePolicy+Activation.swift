// Copyright © 2026 Eigen Labs.
import Foundation

extension PrefixCachePolicy {
    /// Unset uses the model SSD default; an affirmative value opts in.
    /// A non-affirmative nonempty value disables resident L1 and SSD L2.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    static let memoryEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_MEMORY"

    static let mimoCompletePrefixEnvironmentFlag = "DARKBLOOM_MIMO_COMPLETE_PREFIX"

    // MARK: - Gate

    /// Raw global kill-switch state, also used by explicit resident/diagnostic
    /// modes. SSD construction and load hashing must use the model-scoped
    /// gate below; this alone does not grant default SSD eligibility.
    static func isGloballyEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environmentEnabled(environment[environmentFlag], defaultValue: true)
    }

    /// Default SSD activation is separate from backend selection. Only these
    /// exact Qwen, Gemma QAT, GPT-OSS 20B, Nemotron Lightning, Bonsai 2 and MiMo artifacts
    /// default on; an affirmative global flag
    /// opts other models into their existing capability/identity gates. This
    /// keeps offline cache comparisons available without enabling other artifacts
    /// merely because their attention backend defaults to paged.
    static func isEnabled(
        modelId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        var defaultEnabled = EngineV2SupportedModels.isNemotron35ListingModelID(modelId)
            || EngineV2SupportedModels.isQwen4ExpListingModelID(modelId)
            || EngineV2SupportedModels.isBonsai2ListingModelID(modelId)
            || isMiMoDefaultModel(modelId)
        switch modelId {
        case "Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
            "EigenLabs/Qwen3.8-27B-4bit-mtp", "gemma-4-26b-qat-4bit", "gpt-oss-20b":
            defaultEnabled = true
        default:
            break
        }
        return environmentEnabled(environment[environmentFlag], defaultValue: defaultEnabled)
    }

    /// Only the registered native artifact and its exact download identity
    /// default on. This policy never grants native capability or changes the
    /// selected KV backend; the loaded SDK owner must still issue the profile.
    private static func isMiMoDefaultModel(_ modelId: String) -> Bool {
        switch modelId {
        case "mimo-v2.6-flash-mopd", "EigenLabs/MiMo-V2.6-Flash-MOPD-MLX-4bit-mtp":
            return true
        default:
            return false
        }
    }

    /// Empty/unset uses the exact-model default, including when launchd omits
    /// an empty override. Nonempty values retain the existing exact-1 opt-in;
    /// every other value disables. The global cache kill switch always wins.
    static func isMiMoCompletePrefixEnabled(
        modelId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let requested: Bool
        if let value = environment[mimoCompletePrefixEnvironmentFlag],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requested = value == "1"
        } else {
            requested = isMiMoDefaultModel(modelId)
        }
        return requested && isEnabled(modelId: modelId, environment: environment)
    }

    /// One explicit opt-in covers both resident tiers. A byte-budget override
    /// alone cannot keep prompt state in RAM between requests.
    static func isMemoryEnabled(environment: [String: String]) -> Bool {
        isGloballyEnabled(environment: environment)
            && environmentEnabled(environment[memoryEnvironmentFlag], defaultValue: false)
    }

    private static func environmentEnabled(_ value: String?, defaultValue: Bool) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespaces).lowercased(),
            !raw.isEmpty else { return defaultValue }
        return ["1", "true", "yes", "on"].contains(raw)
    }

}
