import Foundation
import MLXLMCommon

public enum MTPAutomaticVerificationPolicy {
    /// Draft depth for a STATELESS assistant, and the only depth Gemma 4 has
    /// ever served at. Historically 1, which is not a policy: it was the
    /// smallest depth that could not be wrong, chosen because the Gemma
    /// drafter carries no request state and the engine's marginal controller
    /// was reserved for drafters that do.
    ///
    /// Depth 1 caps a round at two committed tokens — a 2.0x theoretical
    /// ceiling before a single token is drafted — and the B=1 control matrix
    /// on production pins (3 prompts, 64 output tokens, contiguous KV, M5 Max,
    /// 2026-09-03) shows how much that leaves behind:
    ///
    ///   width 1 (k=0)  118.2 tok/s   -6.6%   round overhead, no draft
    ///   width 2 (k=1)  149.4 tok/s  +18.1%   the historical pin
    ///   width 3 (k=2)  159.1 tok/s  +25.8%
    ///   width 4 (k=3)  162.6 tok/s  +28.5%
    ///   width 5 (k=4)  171.7 tok/s  +35.7%   <- optimum
    ///   width 6 (k=5)  170.8 tok/s  +35.0%
    ///   width 7 (k=6)  155.2 tok/s  +22.7%
    ///   width 8 (k=7)  148.0 tok/s  +17.0%
    ///   adaptive       121.7 tok/s   -3.8%   3 rounds in 64 tokens
    ///
    /// against a 126.5 tok/s target-only baseline. Per-token acceptance falls
    /// from 0.91 at k=1 to 0.64 at k=4, but each round still commits more:
    /// the curve peaks where the falling acceptance stops paying for the extra
    /// verify column. The adaptive controller barely engages at B=1 and loses
    /// to target-only, which is why a stateless drafter gets a fixed pin at all.
    ///
    /// SHAPE INDEPENDENCE. This is a constant, not a table: the same depth is
    /// requested for a 64-token prompt and for a full-context one, and nothing
    /// in this type reads a prompt length, a context size, a KV window, or a
    /// prefill chunk size. That is deliberate. A depth that switched on prompt
    /// length would make every measurement a measurement of the switch, and
    /// would silently mis-serve every length nobody tuned.
    ///
    /// It is also why the depth is only ever a REQUEST. The engine bounds each
    /// round by the rectangular width budget, the step token budget, and KV
    /// headroom, all of which are computed per plan from live state — so a
    /// request that does not fit at some shape is clamped there and nowhere
    /// else. Degradation across shapes is the engine's job, done with facts it
    /// has; picking a number per shape here would be doing it with facts this
    /// type does not have.
    ///
    /// The measurement above is a 64-token, three-short-prompt one, and the
    /// cost model says the optimum should move DEEPER as context grows (the
    /// target step gets more expensive with KV length while the drafter and
    /// the extra verify column barely do). Re-derive it at length; if the
    /// answer differs, change this one constant or set the knob — do not add a
    /// length-keyed branch.
    public static let defaultStatelessDraftTokens = 4

    /// Whether a stateless drafter gets a fixed pin at all, or is handed to
    /// the engine's cost/acceptance controller like a stateful one.
    ///
    /// It is handed to the controller. A constant cannot adapt and a
    /// controller can, and the arms say the difference is large in both
    /// directions: at 64-token chat prompts a pin of 4 measured +35.7% while
    /// adaptive measured -3.8%, and at THE TEST's 17,408-token prompt the same
    /// pin measures **-15.7%** while adaptive measures **-1.2%** — because the
    /// controller priced speculation, found it unprofitable at that shape, and
    /// selected depth 0 for 1,002 of 1,018 decisions (`unprofitable: 1001` in
    /// `controllerFallbacks`).
    ///
    /// A pin that is +36% at one context and -16% at another is shape coupling
    /// expressed as a constant instead of as a branch — the same defect the
    /// depth policy is otherwise careful to avoid. Adaptive's one measured
    /// loss came from a 64-token run, which gives the controller three rounds
    /// to warm up and ends while it is still exploring; that is not a fair
    /// test of a controller, and no production request is 64 tokens long.
    ///
    /// `DARKBLOOM_MTP_DRAFT_TOKENS=<int>` remains the fixed override for an
    /// operator who has measured their own shape and wants to pin it.
    public static let statelessUsesAdaptiveController = true

    /// Retained name for the historical pin. It is no longer the default; it
    /// is the depth an operator asks for with `DARKBLOOM_MTP_DRAFT_TOKENS=1`.
    public static let initialDraftTokens = 1

    /// Operator override for the stateless fixed depth. An integer pins that
    /// depth (clamped to the engine's tested envelope); `adaptive` hands the
    /// stateless drafter to the engine's marginal controller instead of a pin.
    public static let draftTokensEnvironmentKey = "DARKBLOOM_MTP_DRAFT_TOKENS"

    /// Operator override for the certified rectangular width budget. It may
    /// only ever TIGHTEN the per-chip certification, never widen it.
    public static let maxRectangularTokensEnvironmentKey =
        "DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS"

    /// Request-stateful assistants own enough trusted history to use the
    /// engine's marginal controller and get no pin. A stateless assistant
    /// (Gemma 4) gets the measured fixed depth, or whatever the operator
    /// pinned in its place.
    ///
    /// This is a REQUESTED depth, not a granted one. The engine still bounds
    /// every round by the rectangular width budget
    /// (`plannedDecodeRows * (1 + k) <= maxAutomaticRectangularTokens`), so at
    /// B=4 with a cap of 8 the granted depth is 1 whatever is requested here.
    static func fixedDraftTokens(
        usesRequestStatefulDrafter: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard !usesRequestStatefulDrafter else { return nil }
        guard let raw = environment[draftTokensEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return statelessUsesAdaptiveController ? nil : defaultStatelessDraftTokens }
        if raw.lowercased() == "adaptive" { return nil }
        guard let value = Int(raw) else { return defaultStatelessDraftTokens }
        return min(max(value, 0), CBv2MTPConfig.testedMaxDraftTokens)
    }

    public static func maxRectangularTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        chipName: String? = nil
    ) -> Int {
        let resolvedChipName = chipName
            ?? (try? sysctlString("machdep.cpu.brand_string"))
            ?? "Unknown"
        let certifiedMaximum = maxRectangularTokens(chipName: resolvedChipName)
        if let value = environment[maxRectangularTokensEnvironmentKey].flatMap(Int.init) {
            return min(max(value, 0), certifiedMaximum)
        }
        return certifiedMaximum
    }

    public static func maxRectangularTokens(chipName: String) -> Int {
        switch parseChipIdentity(chipName).0 {
        case .m3, .m4, .m5:
            return 8
        case .m1, .m2, .unknown:
            return 4
        }
    }
}
