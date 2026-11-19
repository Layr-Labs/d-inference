import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// Qwen retains its request-stateful controller and drafter-owned cap.
    /// Exact Gemma QAT can alternate ordinary decode with one draft token;
    /// all other stateless assistants retain fixed depth one. Explicit offline
    /// verification controls retain fixed depth one for comparable measurements.
    static func draftDepthPolicy(
        usesRequestStatefulDrafter: Bool,
        modelID: String? = nil,
        hasBenchmarkVerificationOverride: Bool = false
    ) -> (maximum: Int, fixed: Int?) {
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

    /// `DARKBLOOM_GEMMA_MTP_LONE_ROW`: on (unset, `1`, `true`, `yes`, `on`)
    /// the catalog Gemma 4 26B QAT speculates only while one row decodes; any
    /// other value restores the chip's envelope. Read once per process.
    public static let gemmaLoneRowEnvironmentKey = "DARKBLOOM_GEMMA_MTP_LONE_ROW"
    static let gemmaLoneRowEnabled = gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaLoneRowEnvironmentKey])

    static func gemmaLoneRowEnabled(_ raw: String?) -> Bool {
        guard let raw else { return true }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    /// A lone row verifies `[1, 2]`. Two or more decode rows then get depth 0
    /// and run ordinary chained decode: Gemma's rounds at c >= 2 lost to plain
    /// decode on M5 Ultra and M5 Max.
    static let gemmaLoneRowTokens = 2

    public static func maxRectangularTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        chipName: String? = nil,
        modelID: String? = nil,
        gemmaLoneRow: Bool? = nil
    ) -> Int {
        let resolvedChipName = chipName
            ?? (try? sysctlString("machdep.cpu.brand_string"))
            ?? "Unknown"
        var certifiedMaximum = maxRectangularTokens(chipName: resolvedChipName)
        if modelID == MTPAcceptancePolicy.gemmaQATModelID, gemmaLoneRow ?? gemmaLoneRowEnabled {
            certifiedMaximum = min(certifiedMaximum, gemmaLoneRowTokens)
        }
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
