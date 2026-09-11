// Copyright © 2026 Eigen Labs.
import Foundation

extension PrefixCachePolicy {
    /// Unset uses the model SSD default; an affirmative value opts in.
    /// A non-affirmative nonempty value disables resident L1 and SSD L2.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    static let memoryEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_MEMORY"

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
    /// exact Qwen, Gemma QAT, and Nemotron Lightning artifacts default on; an affirmative global flag
    /// opts other models into their existing capability/identity gates. This
    /// keeps offline cache comparisons available without enabling other artifacts
    /// merely because their attention backend defaults to paged.
    static func isEnabled(
        modelId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        var defaultEnabled = EngineV2SupportedModels.isNemotron35ListingModelID(modelId)
        switch modelId {
        case "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
            "EigenLabs/Qwen3.8-27B-4bit-mtp", "gemma-4-26b-qat-4bit":
            defaultEnabled = true
        default:
            break
        }
        return environmentEnabled(environment[environmentFlag], defaultValue: defaultEnabled)
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
