import Foundation

/// The declared parameters of speculative decoding on a decoding rank. The
/// depth is fixed for a session and is part of what both ranks agree to, so a
/// run is repeatable; the product's own engine varies its depth with timing.
public struct QwenMTPTerms: Equatable, Sendable, Encodable {
    /// The product drafter's own ceiling for this head.
    public static let maximumDepth = 4
    public static let standard = QwenMTPTerms(uncheckedDepth: maximumDepth)
    let schema = "qwen_resident_speculative_head_v1"
    /// Drafts per round. A round verifies the last committed token and this
    /// many drafts in one window and commits 1 to depth + 1 tokens.
    public let depth: Int
    /// Every emitted token is the target's own greedy choice at its column.
    let verification = "captured_window_exact_greedy"

    public init(depth: Int) throws {
        guard (1...Self.maximumDepth).contains(depth) else {
            throw ProbeError("Speculative depth must be 1...\(Self.maximumDepth)")
        }
        self.depth = depth
    }

    private init(uncheckedDepth: Int) { depth = uncheckedDepth }

    /// The depth a session runs when it declares none: the row's own, as
    /// measured across the cable (4,096-token prompt, 64 outputs). On the
    /// routed-expert rows a verify window of five rows costs two to three
    /// times a window of four (Qwen3.5 35B A3B 34 ms against 16.5 ms a round,
    /// Qwen3.6 35B A3B 62 ms against 21 ms), so depth 4 decodes slower than no
    /// head at all there (68 and 48 tok/s against 69 and 73 for the plain
    /// phase split) and depth 3 fastest (114 and 106 tok/s). The dense rows
    /// keep the product drafter's ceiling.
    static func standard(for model: QwenRegisteredDenseModel) -> QwenMTPTerms {
        switch model {
        case .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B: return QwenMTPTerms(uncheckedDepth: 3)
        case .qwen35NineB, .qwen38TwentySevenB, .ternaryBonsai2TwentySevenB, .nemotron35Lightning: return standard
        }
    }

    /// The depth a session of `mode` runs when it declares none. Under
    /// `pipeline_mtp_v1` every window row crosses the cable and runs through
    /// both stages, so a deeper window costs on both ranks.
    static func standard(for model: QwenRegisteredDenseModel, mode: QwenResidentGenerationMode) -> QwenMTPTerms {
        guard mode == .pipelineMTP else { return standard(for: model) }
        return standard(for: model)
    }

    /// Bound into the resident load agreement, after the mode's own fields.
    /// `headSHA256` names the head's tensor files by their manifest digests.
    func loadAgreementFields(headSHA256: String) -> [String] {
        [schema, "depth=\(depth)", "verification=\(verification)", "head=\(headSHA256)"]
    }

    /// `pipeline_mtp_v1`: the request agreement's decode framing. Both ranks
    /// frame decode as rounds: the last rank drafts, both stages verify the
    /// window `[last, d1 ... dk]` in one forward each, and every kept token is
    /// the target's own choice at its column (the greedy argmax, or for a
    /// sampled request the product's keyed target sample at that output
    /// index). Distinct from MiMo's framing, so a Qwen round is never a MiMo one.
    var pipelineDecodeFraming: String {
        "speculative_rounds_v1|depth=\(depth)|qwen_pipeline_window_target_prefix_v1"
    }

    private enum CodingKeys: String, CodingKey { case schema, depth, verification }
}

extension QwenMTPTerms: PipelineSpeculativeRoundTerms {
    static var roundFamily: String { "qwen" }
}
