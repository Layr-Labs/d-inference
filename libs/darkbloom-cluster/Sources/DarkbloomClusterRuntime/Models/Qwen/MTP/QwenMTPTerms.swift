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

    /// Bound into the resident load agreement, after the mode's own fields.
    /// `headSHA256` names the head's tensor files by their manifest digests.
    func loadAgreementFields(headSHA256: String) -> [String] {
        [schema, "depth=\(depth)", "verification=\(verification)", "head=\(headSHA256)"]
    }

    private enum CodingKeys: String, CodingKey { case schema, depth, verification }
}
