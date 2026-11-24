import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    public static let initialDraftTokens = 1

    /// Qwen retains its request-stateful controller and drafter-owned cap.
    /// Exact Gemma QAT drafts two tokens at fixed depth on a measured chip
    /// (`gemmaTwoDrafts(chipName:m5UltraLoneRow:)`, with `fixedDraftTokensByDecodeRows`), and
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
    /// a round at fixed depth on the chips listed in `gemmaTwoDrafts(chipName:m5UltraLoneRow:)`;
    /// other chips keep the adaptive one-draft lone-row policy below. Any other
    /// value restores that policy everywhere. Read once per process.
    public static let gemmaTwoDraftsEnvironmentKey = "DARKBLOOM_GEMMA_MTP_TWO_DRAFTS"
    static let gemmaTwoDraftsEnabled = gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaTwoDraftsEnvironmentKey])

    /// The two-draft policy per measured chip: the fixed depth by planned
    /// decode rows and the envelope that admits its widest verification.
    /// On M5 Ultra, M3 Ultra and M5 Max only a lone row drafts two (`[1, 3]`);
    /// envelope 3 gives two rows depth 0, ordinary chained decode (two rows
    /// drafting two did not beat plain decode on these chips). With
    /// `m5UltraLoneRow` off, M5 Ultra keeps its earlier table: one or two rows
    /// draft two (`[2, 3]`, envelope 6).
    /// Every other chip returns nil and keeps the lone-row policy.
    static func gemmaTwoDrafts(
        chipName: String, m5UltraLoneRow: Bool? = nil
    ) -> (byDecodeRows: [Int], tokens: Int)? {
        let m5UltraLoneRow = m5UltraLoneRow ?? gemmaM5UltraLoneRowEnabled
        switch parseChipIdentity(chipName) {
        case (.m5, .ultra) where !m5UltraLoneRow: return ([2, 2, 0], 6)
        case (.m5, .ultra), (.m3, .ultra), (.m5, .max): return ([2, 0], 3)
        default: return nil
        }
    }

    /// `DARKBLOOM_GEMMA_MTP_M5_ULTRA_LONE_ROW`: on (unset, empty, `1`, `true`,
    /// `yes`, `on`; trimmed, any case) M5 Ultra drafts two tokens only for a
    /// lone row; any other value (e.g. `0`) restores its earlier table, one or
    /// two rows drafting two. Read once per process.
    public static let gemmaM5UltraLoneRowEnvironmentKey = "DARKBLOOM_GEMMA_MTP_M5_ULTRA_LONE_ROW"
    static let gemmaM5UltraLoneRowEnabled = gemmaLoneRowEnabled(
        ProcessInfo.processInfo.environment[gemmaM5UltraLoneRowEnvironmentKey])

    static func resolvedChipName(_ chipName: String?) -> String {
        chipName ?? (try? sysctlString("machdep.cpu.brand_string")) ?? "Unknown"
    }

    /// The operator's Gemma draft prompt-length setting
    /// (`DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS`).
    enum GemmaDraftPromptLimit: Equatable {
        /// Unset, empty or not a positive integer: the chip's measured limit.
        case chipDefault
        /// `0`, `off`, `false` or `no`: no limit; every prompt drafts.
        case off
        /// A positive integer: that limit on the chips that have one.
        case tokens(Int)

        init(_ raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if ["0", "off", "false", "no"].contains(value) {
                self = .off
            } else if let tokens = Int(value), tokens > 0 {
                self = .tokens(tokens)
            } else {
                self = .chipDefault
            }
        }
    }

    /// `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS`: under the two-draft policy on
    /// M5 Ultra, a Gemma 4 26B QAT decode step whose speculation-eligible rows
    /// all have prompts over the limit runs without drafts
    /// (`CBv2MTPConfig.maxDraftPromptTokens`); a row under the limit keeps the
    /// chip's table. Unset: `gemmaM5UltraMaxDraftPromptTokens`;
    /// `0` (or `off`, `false`, `no`): no limit, the earlier behaviour; a
    /// positive integer: that limit. Other chips never get one. Read once per
    /// process.
    public static let gemmaMaxDraftPromptTokensEnvironmentKey =
        "DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS"
    static let gemmaDraftPromptLimit = GemmaDraftPromptLimit(
        ProcessInfo.processInfo.environment[gemmaMaxDraftPromptTokensEnvironmentKey])
    /// On a quiet M5 Ultra a lone row's two-draft rounds lose to plain decode
    /// above this prompt length.
    static let gemmaM5UltraMaxDraftPromptTokens = 16384
    /// Whether an unset `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS` applies the
    /// chip's limit. False gives every chip no limit unless the operator sets
    /// a positive value.
    static let gemmaPromptLimitOnByDefault = true

    /// The prompt-length limit for drafting for `modelID` on this chip, or nil
    /// for no limit.
    static func maxDraftPromptTokens(
        modelID: String?, chipName: String? = nil, hasBenchmarkVerificationOverride: Bool = false,
        twoDrafts: Bool? = nil, limit: GemmaDraftPromptLimit? = nil,
        onByDefault: Bool = gemmaPromptLimitOnByDefault
    ) -> Int? {
        guard modelID == MTPAcceptancePolicy.gemmaQATModelID, !hasBenchmarkVerificationOverride,
            twoDrafts ?? gemmaTwoDraftsEnabled,
            case (.m5, .ultra) = parseChipIdentity(resolvedChipName(chipName))
        else { return nil }
        switch limit ?? gemmaDraftPromptLimit {
        case .chipDefault: return onByDefault ? gemmaM5UltraMaxDraftPromptTokens : nil
        case .off: return nil
        case .tokens(let tokens): return tokens
        }
    }

    /// The per-row depth table for `modelID` on this chip, or nil.
    static func fixedDraftTokensByDecodeRows(
        modelID: String?, chipName: String? = nil, hasBenchmarkVerificationOverride: Bool = false,
        twoDrafts: Bool? = nil, m5UltraLoneRow: Bool? = nil
    ) -> [Int]? {
        guard modelID == MTPAcceptancePolicy.gemmaQATModelID, !hasBenchmarkVerificationOverride,
            twoDrafts ?? gemmaTwoDraftsEnabled
        else { return nil }
        return gemmaTwoDrafts(
            chipName: resolvedChipName(chipName), m5UltraLoneRow: m5UltraLoneRow)?.byDecodeRows
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
        gemmaTwoDrafts: Bool? = nil,
        gemmaM5UltraLoneRow: Bool? = nil
    ) -> Int {
        let chip = Self.resolvedChipName(chipName)
        var certifiedMaximum = maxRectangularTokens(chipName: chip)
        if modelID == MTPAcceptancePolicy.gemmaQATModelID {
            if gemmaTwoDrafts ?? gemmaTwoDraftsEnabled,
                let twoDrafts = Self.gemmaTwoDrafts(
                    chipName: chip, m5UltraLoneRow: gemmaM5UltraLoneRow)
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
