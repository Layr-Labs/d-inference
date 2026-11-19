import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// Qwen retains its request-stateful controller and drafter-owned cap.
    /// Exact Gemma QAT drafts two tokens at fixed depth on a measured chip
    /// (`gemmaTwoDrafts(chipName:)`, with `fixedDraftTokensByDecodeRows`), and
    /// elsewhere or with its switch off alternates ordinary decode with one
    /// draft token;
    /// all other stateless assistants retain fixed depth one. Explicit offline
    /// verification controls retain fixed depth one for comparable measurements.
    static func draftDepthPolicy(
        usesRequestStatefulDrafter: Bool,
        modelID: String? = nil,
        hasBenchmarkVerificationOverride: Bool = false,
        chipName: String? = nil,
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
            let twoDrafts = (gemmaTwoDrafts ?? gemmaTwoDraftsEnabled)
                ? Self.gemmaTwoDrafts(chipName: resolvedChipName(chipName)) : nil
            return twoDrafts == nil ? (1, nil) : (2, 2)
        }
        return (CBv2MTPConfig.testedMaxDraftTokens, initialDraftTokens)
    }

    /// `DARKBLOOM_GEMMA_MTP_TWO_DRAFTS`: on (unset, empty, `1`, `true`, `yes`,
    /// `on`; trimmed, any case) the catalog Gemma 4 26B QAT drafts two tokens
    /// a round at fixed depth on the chips listed in `gemmaTwoDrafts(chipName:)`;
    /// other chips keep the adaptive one-draft lone-row policy below. Any other
    /// value restores that policy everywhere. Read once per process.
    public static let gemmaTwoDraftsEnvironmentKey = "DARKBLOOM_GEMMA_MTP_TWO_DRAFTS"
    static let gemmaTwoDraftsEnabled = gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaTwoDraftsEnvironmentKey])

    /// The two-draft policy per measured chip: the fixed depth by planned
    /// decode rows and the envelope that admits its widest verification.
    /// - M5 Ultra: one or two rows draft two tokens (`[2, 3]`, envelope 6).
    /// - M3 Ultra: only a lone row drafts two (`[1, 3]`); envelope 3 gives two
    ///   rows depth 0 (two rows drafting two were slower than plain there).
    /// Every other chip returns nil and keeps the lone-row policy.
    static func gemmaTwoDrafts(chipName: String) -> (byDecodeRows: [Int], tokens: Int)? {
        switch parseChipIdentity(chipName) {
        case (.m5, .ultra): return ([2, 2, 0], 6)
        case (.m3, .ultra): return ([2, 0], 3)
        default: return nil
        }
    }

    static func resolvedChipName(_ chipName: String?) -> String {
        chipName ?? (try? sysctlString("machdep.cpu.brand_string")) ?? "Unknown"
    }

    /// The per-row depth table for `modelID` on this chip, or nil.
    static func fixedDraftTokensByDecodeRows(
        modelID: String?, chipName: String? = nil, hasBenchmarkVerificationOverride: Bool = false,
        twoDrafts: Bool? = nil
    ) -> [Int]? {
        guard modelID == MTPAcceptancePolicy.gemmaQATModelID, !hasBenchmarkVerificationOverride,
            twoDrafts ?? gemmaTwoDraftsEnabled
        else { return nil }
        return gemmaTwoDrafts(chipName: resolvedChipName(chipName))?.byDecodeRows
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
        let chip = Self.resolvedChipName(chipName)
        var certifiedMaximum = maxRectangularTokens(chipName: chip)
        if modelID == MTPAcceptancePolicy.gemmaQATModelID {
            if gemmaTwoDrafts ?? gemmaTwoDraftsEnabled,
                let twoDrafts = Self.gemmaTwoDrafts(chipName: chip)
            {
                certifiedMaximum = min(certifiedMaximum, twoDrafts.tokens)
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
