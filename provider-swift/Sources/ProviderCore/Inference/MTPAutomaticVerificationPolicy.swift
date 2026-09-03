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
    public static let defaultStatelessDraftTokens = 4

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
        else { return defaultStatelessDraftTokens }
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
