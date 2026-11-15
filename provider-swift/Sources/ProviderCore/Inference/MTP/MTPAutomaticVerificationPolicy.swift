import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// How exact Muse Glimmer picks its draft depth.
    public enum MuseGlimmerDraftDepth: String, Sendable, CaseIterable {
        /// Every round drafts the model's cap (7): one block forward proposes
        /// them all at the same cost.
        case fixed
        /// The engine's controller picks a depth up to the cap each round.
        case adaptive
    }

    /// Selects Muse Glimmer's depth policy; unset is `fixed`. The variable's
    /// prefix puts it in the complete-checkpoint fingerprint, and the policy
    /// itself is there as `mtp.fixedDraftTokens`, so the two never share
    /// checkpoints.
    public static let museGlimmerDraftDepthEnvironmentKey = "DARKBLOOM_MTP_MUSE_GLIMMER_DEPTH"

    /// The selected policy and the value it could not read, if any. An
    /// unreadable value keeps the default.
    public static func museGlimmerDraftDepth(
        environment: [String: String]
    ) -> (depth: MuseGlimmerDraftDepth, unrecognized: String?) {
        guard let raw = environment[museGlimmerDraftDepthEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return (.fixed, nil) }
        guard let depth = MuseGlimmerDraftDepth(rawValue: raw) else { return (.fixed, raw) }
        return (depth, nil)
    }

    /// Qwen retains its request-stateful controller and drafter-owned cap.
    /// Exact Muse Glimmer drafts its cap every round by default, or adapts up
    /// to it when `DARKBLOOM_MTP_MUSE_GLIMMER_DEPTH=adaptive`, with or without
    /// an offline verification control.
    /// Exact Gemma QAT can alternate ordinary decode with one draft token;
    /// all other stateless assistants retain fixed depth one. Explicit offline
    /// verification controls retain fixed depth one for comparable measurements.
    static func draftDepthPolicy(
        usesRequestStatefulDrafter: Bool,
        modelID: String? = nil,
        hasBenchmarkVerificationOverride: Bool = false,
        environment: [String: String] = [:]
    ) -> (maximum: Int, fixed: Int?) {
        if MuseGlimmerModelPolicy.matchesModelID(modelID) {
            // Its block drafter proposes several tokens a round; the cap never
            // exceeds the engine's tested window.
            let cap = min(MuseGlimmerModelPolicy.maximumDraftTokens, CBv2MTPConfig.testedMaxDraftTokens)
            switch museGlimmerDraftDepth(environment: environment).depth {
            case .fixed: return (cap, cap)
            case .adaptive: return (cap, nil)
            }
        }
        if usesRequestStatefulDrafter {
            if Bonsai9BModelPolicy.matchesModelID(modelID) {
                // Publisher's private 9B reference depth; retain a bounded
                // fixed comparison until this separate head is qualified.
                return (2, 2)
            }
            return (CBv2MTPConfig.testedMaxDraftTokens, nil)
        }
        if modelID == "gemma-4-26b-qat-4bit", !hasBenchmarkVerificationOverride {
            return (1, nil)
        }
        return (CBv2MTPConfig.testedMaxDraftTokens, initialDraftTokens)
    }

    public static func maxRectangularTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        chipName: String? = nil
    ) -> Int {
        let resolvedChipName = chipName
            ?? (try? sysctlString("machdep.cpu.brand_string"))
            ?? "Unknown"
        let certifiedMaximum = maxRectangularTokens(chipName: resolvedChipName)
        if let value = environment["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS"].flatMap(Int.init) {
            return min(max(value, 0), certifiedMaximum)
        }
        return certifiedMaximum
    }

    public static func maxRectangularTokens(chipName: String) -> Int {
        switch parseChipIdentity(chipName).0 {
        case .m3, .m4, .m5:
            return 8
        case .m1, .m2, .m6, .unknown:
            return 4
        }
    }
}
