import Foundation

/// Builds the long single-prompt corpus THE TEST measures against: one chat
/// turn whose body is filler prose, sized to an exact token count, ending in an
/// instruction that keeps the model generating to the output budget instead of
/// emitting EOS after a paragraph.
///
/// The exact length matters. THE TEST is 16,384 prefill + 1,024 input =
/// 17,408 prompt tokens; a prompt that lands "about there" moves the sliding
/// window, the KV footprint, and the per-step attention read, so the arms stop
/// being comparable to the control. Chat templates make exact sizing awkward
/// (a body of N words is not N tokens), so this builder deliberately works in
/// two stages: grow the templated prompt until it is at least the target, then
/// delete the surplus from the middle of the filler at the token level, where
/// removing a handful of tokens from repeated prose changes nothing that
/// matters.
public enum MTPBenchmarkSyntheticPrompt {
    /// Filler body. Technical prose rather than lorem ipsum so the tokenizer
    /// produces a realistic token mix and MoE routing is not degenerate.
    public static let fillerParagraph = """
        Unified memory changes where the cost of autoregressive decoding lives. \
        The weights are read once per emitted token, the key-value cache is read \
        once per attention layer, and the arithmetic in between is small enough \
        that the memory system, not the arithmetic units, sets the pace. A \
        mixture-of-experts layer sharpens this: only a routed subset of the \
        expert weights is read for any one token, so the bytes moved per token \
        fall while the number of distinct weight regions touched per batch \
        rises. Speculative decoding is a trade against exactly this shape. A \
        drafter proposes several tokens, the target verifies them together in \
        one rectangular forward, and the accepted prefix is committed. The \
        verification reads the same weights as a single decode step, so a round \
        that commits four tokens amortizes one weight sweep over four emissions. \
        What decides whether that pays is the accepted length per round and the \
        fixed cost of the round itself: the draft forward, the accept walk, the \
        cache rollback on rejection, and every host round trip that separates \
        one command buffer from the next. \

        """

    /// The instruction appended after the filler. It has one job: make greedy
    /// decoding keep producing text to the output budget, so every arm in the
    /// sweep measures the same number of emitted tokens.
    public static let continuationInstruction = """
        Continue the technical note above. Write a long, detailed, uninterrupted \
        continuation covering memory bandwidth, cache residency, expert routing, \
        speculative decoding, acceptance rates, and round overhead. Do not \
        summarize, do not stop early, and do not write a conclusion; keep \
        elaborating in full paragraphs until you are cut off.
        """

    /// Body text long enough that the templated prompt is at least
    /// `approximateTokens` tokens. Callers grow it until the tokenizer agrees.
    public static func body(paragraphs: Int) -> String {
        var text = ""
        text.reserveCapacity(paragraphs * fillerParagraph.count + continuationInstruction.count)
        for index in 0..<max(1, paragraphs) {
            text += "Section \(index + 1). " + fillerParagraph
        }
        return text + "\n\n" + continuationInstruction
    }

    /// Trim an over-long templated prompt to exactly `target` tokens by
    /// deleting from the middle, which is filler in every prompt this builder
    /// produces. The chat template's leading and trailing control tokens are
    /// never touched, so the result is still a well-formed turn.
    ///
    /// Throws when the prompt is shorter than the target: this helper only ever
    /// removes tokens, because inserting them would mean inventing text.
    public static func trimmedToExactLength(
        tokenIDs: [Int],
        target: Int
    ) throws -> [Int] {
        guard target > 0 else {
            throw MTPBenchmarkError.invalidSyntheticPrompt("target token count must be positive")
        }
        guard tokenIDs.count >= target else {
            throw MTPBenchmarkError.invalidSyntheticPrompt(
                "templated prompt is \(tokenIDs.count) tokens, short of the \(target) requested")
        }
        let surplus = tokenIDs.count - target
        guard surplus > 0 else { return tokenIDs }
        // Cut from the middle of the filler. Half the target on each side keeps
        // the cut clear of both the template prefix and the trailing
        // instruction even for a large surplus.
        let cutStart = max(1, min(tokenIDs.count - surplus - 1, target / 2))
        var trimmed = tokenIDs
        trimmed.removeSubrange(cutStart..<(cutStart + surplus))
        return trimmed
    }
}
