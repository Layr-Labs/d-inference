import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// Qwen retains its request-stateful controller and drafter-owned cap.
    /// Exact Gemma QAT adapts between ordinary decode and `gemmaQATMaximumDepth`
    /// draft tokens per request (`requestProbeDepth`); all other stateless
    /// assistants retain fixed depth one. Explicit offline verification
    /// controls retain fixed depth one for comparable measurements. Quantized
    /// live KV turns off ordinary-decode chaining, which request-probe mode
    /// needs, so Gemma QAT there keeps the adaptive controller at depth one.
    static func draftDepthPolicy(
        usesRequestStatefulDrafter: Bool,
        modelID: String? = nil,
        hasBenchmarkVerificationOverride: Bool = false,
        quantizedLiveKV: Bool = false
    ) -> (maximum: Int, fixed: Int?) {
        if usesRequestStatefulDrafter {
            if Bonsai9BModelPolicy.matchesModelID(modelID) {
                // Publisher's private 9B reference depth; retain a bounded
                // fixed comparison until this separate head is qualified.
                return (2, 2)
            }
            return (CBv2MTPConfig.testedMaxDraftTokens, nil)
        }
        if modelID == gemmaQATModelID, !hasBenchmarkVerificationOverride {
            return (quantizedLiveKV ? 1 : gemmaQATMaximumDepth, nil)
        }
        return (CBv2MTPConfig.testedMaxDraftTokens, initialDraftTokens)
    }

    static let gemmaQATModelID = "gemma-4-26b-qat-4bit"
    /// Gemma QAT's deepest round. Whether a request uses it is the adaptive
    /// controller's measurement on this Mac (`requestProbeDepth`); the
    /// automatic verification envelope (`maxRectangularTokens`) still clamps a
    /// batch's depth. Exactness was measured for B1/L2...L8 on M5
    /// (`docs/design/gemma4-cbv2-mtp.md`).
    static let gemmaQATMaximumDepth = 4

    /// The adaptive controller's request-probe depth (`CBv2MTPConfig.requestProbeDepth`):
    /// Gemma QAT opens each request with a depth-2 window, then follows the
    /// request's own acceptance against this engine's measured cost of a round
    /// at each depth, so chat stays near ordinary decode while tools and code
    /// go deep. nil keeps the incremental controller (every other model,
    /// explicit offline verification controls, and quantized live KV).
    static func requestProbeDepth(
        usesRequestStatefulDrafter: Bool, modelID: String?, hasBenchmarkVerificationOverride: Bool = false,
        quantizedLiveKV: Bool = false
    ) -> Int? {
        guard !usesRequestStatefulDrafter, modelID == gemmaQATModelID, !hasBenchmarkVerificationOverride,
            !quantizedLiveKV
        else {
            return nil
        }
        return 2
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
