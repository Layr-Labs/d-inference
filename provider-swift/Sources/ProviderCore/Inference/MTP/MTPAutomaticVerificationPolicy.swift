import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// Qwen retains its request-stateful controller and drafter-owned cap.
    /// Exact Gemma QAT drafts two tokens at one or two decode rows (fixed, with
    /// `fixedDraftTokensByDecodeRows`), or with its switch off alternates
    /// ordinary decode with one draft token;
    /// all other stateless assistants retain fixed depth one. Explicit offline
    /// verification controls retain fixed depth one for comparable measurements.
    static func draftDepthPolicy(
        usesRequestStatefulDrafter: Bool,
        modelID: String? = nil,
        hasBenchmarkVerificationOverride: Bool = false,
        gemmaTwoDrafts: Bool? = nil
    ) -> (maximum: Int, fixed: Int?) {
        if usesRequestStatefulDrafter {
            if Bonsai9BModelPolicy.matchesModelID(modelID) {
                // Publisher's private 9B reference depth; retain a bounded
                // fixed comparison until this separate head is qualified.
                return (2, 2)
            }
            return (CBv2MTPConfig.testedMaxDraftTokens, nil)
        }
        if modelID == MTPAcceptancePolicy.gemmaQATModelID, !hasBenchmarkVerificationOverride {
            return gemmaTwoDrafts ?? gemmaTwoDraftsEnabled ? (2, 2) : (1, nil)
        }
        return (CBv2MTPConfig.testedMaxDraftTokens, initialDraftTokens)
    }

    /// `DARKBLOOM_GEMMA_MTP_TWO_DRAFTS`: on (unset, empty, `1`, `true`, `yes`,
    /// `on`; trimmed, any case) the catalog Gemma 4 26B QAT drafts two tokens
    /// a round while one or two rows decode (`gemmaTwoDraftsByDecodeRows`), and
    /// three or more rows decode without speculation. Any other value restores
    /// the adaptive one-draft lone-row policy below. Read once per process.
    public static let gemmaTwoDraftsEnvironmentKey = "DARKBLOOM_GEMMA_MTP_TWO_DRAFTS"
    static let gemmaTwoDraftsEnabled = gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaTwoDraftsEnvironmentKey])

    /// Fixed draft depth by planned decode rows for the two-draft policy:
    /// one or two rows draft two tokens, three or more rows none.
    static let gemmaTwoDraftsByDecodeRows = [2, 2, 0]

    /// `[2, 3]` (two rows of three tokens) is the widest verification.
    static let gemmaTwoDraftsTokens = 6

    /// The per-row depth table for `modelID`, or nil.
    static func fixedDraftTokensByDecodeRows(
        modelID: String?, hasBenchmarkVerificationOverride: Bool = false,
        twoDrafts: Bool? = nil
    ) -> [Int]? {
        guard modelID == MTPAcceptancePolicy.gemmaQATModelID, !hasBenchmarkVerificationOverride,
            twoDrafts ?? gemmaTwoDraftsEnabled
        else { return nil }
        return gemmaTwoDraftsByDecodeRows
    }

    /// `DARKBLOOM_GEMMA_MTP_LONE_ROW`: on (unset, empty, `1`, `true`, `yes`,
    /// `on`; trimmed, any case) the catalog Gemma 4 26B QAT speculates only
    /// while one row decodes; any other value restores the chip's envelope.
    /// Read once from the process environment, not from a slot's `environment`.
    public static let gemmaLoneRowEnvironmentKey = "DARKBLOOM_GEMMA_MTP_LONE_ROW"
    static let gemmaLoneRowEnabled = gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaLoneRowEnvironmentKey])

    static func gemmaLoneRowEnabled(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !value.isEmpty
        else { return true }
        return ["1", "true", "yes", "on"].contains(value)
    }

    /// A lone row verifies `[1, 2]`. Two or more decode rows then get depth 0
    /// and run ordinary chained decode: Gemma's rounds at two to four rows were
    /// slower than plain decode on an M5 Ultra.
    static let gemmaLoneRowTokens = 2

    public static func maxRectangularTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        chipName: String? = nil,
        modelID: String? = nil,
        gemmaLoneRow: Bool? = nil,
        gemmaTwoDrafts: Bool? = nil
    ) -> Int {
        let resolvedChipName = chipName
            ?? (try? sysctlString("machdep.cpu.brand_string"))
            ?? "Unknown"
        var certifiedMaximum = maxRectangularTokens(chipName: resolvedChipName)
        if modelID == MTPAcceptancePolicy.gemmaQATModelID {
            if gemmaTwoDrafts ?? gemmaTwoDraftsEnabled {
                certifiedMaximum = min(certifiedMaximum, gemmaTwoDraftsTokens)
            } else if gemmaLoneRow ?? gemmaLoneRowEnabled {
                certifiedMaximum = min(certifiedMaximum, gemmaLoneRowTokens)
            }
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
