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

    /// How many decoding requests one exact Muse Glimmer round may hold.
    public struct MuseGlimmerSpeculativeRows: Sendable, Equatable {
        /// The drafter's speculative batch and the engine's batch gate.
        public let rows: Int
        /// Fixed depth by planned decode rows, applied only under a fixed
        /// depth; nil keeps one depth for every width.
        public let depthByDecodeRows: [Int]?

        /// One request per round: more than one decoding row drafts nothing.
        public static let single = MuseGlimmerSpeculativeRows(rows: 1, depthByDecodeRows: nil)
        /// Two requests per round: one row alone keeps the cap, two draft
        /// `pairedRoundDraftTokens` each, so a paired round verifies the same
        /// 8 target rows as one row at depth 7. Three or more decoding rows
        /// exceed the gate and decode plainly, as every width does today.
        public static let paired = MuseGlimmerSpeculativeRows(
            rows: 2,
            depthByDecodeRows: [
                MuseGlimmerModelPolicy.maximumDraftTokens, MuseGlimmerModelPolicy.pairedRoundDraftTokens,
            ])
    }

    /// `2` opts in to two requests per round (paired); unset, empty or `1` is
    /// the default, one request per round, the binding before paired rounds.
    /// The prefix puts the variable in the complete-checkpoint fingerprint,
    /// and the batch is there as `mtp.maxSpeculativeBatch`.
    public static let museGlimmerSpeculativeRowsEnvironmentKey = "DARKBLOOM_MTP_MUSE_GLIMMER_ROWS"

    /// The selected row policy and the value it could not read, if any. An
    /// unreadable value keeps the default.
    public static func museGlimmerSpeculativeRows(
        environment: [String: String]
    ) -> (rows: MuseGlimmerSpeculativeRows, unrecognized: String?) {
        guard let raw = environment[museGlimmerSpeculativeRowsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return (.single, nil) }
        switch raw {
        case "1": return (.single, nil)
        case "2": return (.paired, nil)
        default: return (.single, raw)
        }
    }

    /// `1` opts sampled Muse Glimmer rows in to coupled proposals: a sampled
    /// row's drafts are raced with the noise of the target's own verify draw
    /// at each position. Unset, empty or `0` is the default, argmax proposals
    /// (the binding before coupled proposals). Output is unchanged either way
    /// (exact acceptance emits the target's draw). The prefix puts the
    /// variable in the complete-checkpoint fingerprint.
    public static let museGlimmerCoupledProposalsEnvironmentKey = "DARKBLOOM_MTP_MUSE_GLIMMER_COUPLED"

    /// Whether sampled rows get coupled proposals, and the value it could not
    /// read, if any. An unreadable value keeps the default.
    public static func museGlimmerCoupledProposals(
        environment: [String: String]
    ) -> (coupled: Bool, unrecognized: String?) {
        guard let raw = environment[museGlimmerCoupledProposalsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return (false, nil) }
        switch raw {
        case "0": return (false, nil)
        case "1": return (true, nil)
        default: return (false, raw)
        }
    }

    /// Gives an enabled Muse Glimmer configuration its row policy: the batch
    /// gate, and under a fixed depth the width table. The single-row policy
    /// leaves the configuration as it is, the drafter's one-row binding being
    /// the gate. Every other model and a disabled configuration are
    /// untouched. Returns the unreadable variable value, if any.
    @discardableResult
    static func applyMuseGlimmerSpeculativeRows(
        to config: inout CBv2MTPConfig, modelID: String?, environment: [String: String]
    ) -> String? {
        guard MuseGlimmerModelPolicy.matchesModelID(modelID), config.enabled else { return nil }
        let (policy, unrecognized) = museGlimmerSpeculativeRows(environment: environment)
        guard policy != .single else { return unrecognized }
        config.maxSpeculativeBatch = policy.rows
        if let fixed = config.fixedDraftTokens, let table = policy.depthByDecodeRows {
            config.fixedDraftTokensByDecodeRows = table.map { min($0, fixed) }
        }
        return unrecognized
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
