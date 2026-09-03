import Foundation

/// Builds a chat prompt of an EXACT token count, at any token count, for any
/// tokenizer and any chat template.
///
/// Nothing here is calibrated to a particular prompt size. The builder does
/// not know how many tokens a paragraph is worth, where the chat template's
/// control tokens sit, or how long the instruction is: it measures all three
/// from three probe tokenizations of the same template it is about to use, and
/// derives every index from those measurements. Change the filler, the
/// instruction, the tokenizer or the template and the same code still lands on
/// the requested count.
///
/// That matters because a benchmark prompt builder that is tuned to one size
/// silently stops being exact at every other size, and a sweep across prompt
/// lengths is then measuring the builder as much as the engine.
public enum MTPBenchmarkSyntheticPrompt {
    /// One unit of filler. Technical prose rather than lorem ipsum so the
    /// tokenizer produces a realistic token mix and MoE routing is not
    /// degenerate. Its length in tokens is never assumed — it is measured.
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

    /// Appended after the filler. Its job is to make greedy decoding keep
    /// producing text to the output budget, so every arm of a sweep measures
    /// the same number of emitted tokens.
    public static let continuationInstruction = """
        Continue the technical note above. Write a long, detailed, uninterrupted \
        continuation covering memory bandwidth, cache residency, expert routing, \
        speculative decoding, acceptance rates, and round overhead. Do not \
        summarize, do not stop early, and do not write a conclusion; keep \
        elaborating in full paragraphs until you are cut off.
        """

    /// Chat body carrying exactly `fillerUnits` filler paragraphs. `variant`
    /// rotates the content so a multi-row batch does not submit identical
    /// prompts (identical prompts route to identical experts and understate
    /// MoE traffic).
    public static func body(
        fillerUnits: Int, variant: Int, includeInstruction: Bool = true
    ) -> String {
        var text = "Revision \(variant). "
        text.reserveCapacity(max(0, fillerUnits) * fillerParagraph.count + 512)
        for index in 0..<max(0, fillerUnits) {
            text += "Section \(index + 1). " + fillerParagraph
        }
        guard includeInstruction else { return text }
        return text + "\n\n" + continuationInstruction
    }

    /// Where a templated prompt's content lives, measured rather than assumed.
    ///
    /// `templateHead` is the token count the chat template contributes before
    /// any body content; `templateTail` is what it contributes after. Between
    /// them sit the filler and then the instruction. Every one of these is
    /// derived by differencing three probe tokenizations, so none of them is a
    /// constant that can go stale.
    public struct TemplateShape: Equatable, Sendable {
        public let templateHead: Int
        public let templateTail: Int
        /// Tokens the instruction contributes, filler excluded.
        public let instructionTokens: Int
        /// Tokens one filler unit contributes. Always at least 1.
        public let tokensPerFillerUnit: Int
        /// Tokens in the shortest well-formed turn this template can produce:
        /// head + tail with no body at all. A request below this cannot be
        /// satisfied without emitting something that is not a chat turn.
        public var minimumTokens: Int { templateHead + templateTail }

        public init(
            templateHead: Int,
            templateTail: Int,
            instructionTokens: Int,
            tokensPerFillerUnit: Int
        ) {
            self.templateHead = templateHead
            self.templateTail = templateTail
            self.instructionTokens = instructionTokens
            self.tokensPerFillerUnit = max(1, tokensPerFillerUnit)
        }
    }

    /// Derive the template's shape from three tokenizations of the SAME
    /// template the caller will use:
    ///
    ///   `noInstruction` — body with zero filler units and no instruction
    ///   `zeroUnits`     — body with zero filler units, instruction present
    ///   `oneUnit`       — body with one filler unit, instruction present
    ///
    /// `templateHead` is the common prefix of `zeroUnits` and `oneUnit` (they
    /// differ only by inserted filler). `templateTail` is the common suffix of
    /// `noInstruction` and `zeroUnits` (they differ only by the instruction).
    /// `tokensPerFillerUnit` is the size difference between the last two.
    public static func templateShape(
        noInstruction: [Int], zeroUnits: [Int], oneUnit: [Int]
    ) -> TemplateShape {
        TemplateShape(
            templateHead: commonPrefixLength(zeroUnits, oneUnit),
            templateTail: commonSuffixLength(noInstruction, zeroUnits),
            instructionTokens: max(0, zeroUnits.count - noInstruction.count),
            tokensPerFillerUnit: oneUnit.count - zeroUnits.count)
    }

    /// How many filler units to ask for to reach at least `target` tokens.
    /// Uses the MEASURED per-unit slope, so it converges in one step for any
    /// target and any tokenizer instead of relying on a tuned guess.
    public static func fillerUnits(
        forTarget target: Int, shape: TemplateShape, alreadyProduced: Int = 0
    ) -> Int {
        let have = alreadyProduced
        guard target > have else { return 0 }
        let shortfall = target - have
        return (shortfall + shape.tokensPerFillerUnit - 1) / shape.tokensPerFillerUnit
    }

    /// Delete exactly `tokenIDs.count - target` tokens, taking them from
    /// `removableInPriorityOrder` in order: the first range is emptied before
    /// the second is touched.
    ///
    /// Ranges must be disjoint and ascending. Everything outside them is
    /// preserved byte for byte, which is what keeps the result a well-formed
    /// chat turn at every target length — the template's own control tokens
    /// are simply never in a removable range.
    public static func trimmed(
        tokenIDs: [Int],
        target: Int,
        removableInPriorityOrder ranges: [Range<Int>]
    ) throws -> [Int] {
        guard target >= 0 else {
            throw MTPBenchmarkError.invalidSyntheticPrompt(
                "target token count must not be negative, got \(target)")
        }
        guard tokenIDs.count >= target else {
            throw MTPBenchmarkError.invalidSyntheticPrompt(
                "prompt is \(tokenIDs.count) tokens, short of the \(target) requested")
        }
        var surplus = tokenIDs.count - target
        guard surplus > 0 else { return tokenIDs }
        var previousEnd = 0
        for range in ranges {
            guard range.lowerBound >= previousEnd, range.upperBound <= tokenIDs.count else {
                throw MTPBenchmarkError.invalidSyntheticPrompt(
                    "removable ranges must be disjoint, ascending, and inside the prompt")
            }
            previousEnd = range.upperBound
        }
        let capacity = ranges.reduce(0) { $0 + $1.count }
        guard capacity >= surplus else {
            throw MTPBenchmarkError.invalidSyntheticPrompt(
                "cannot reach \(target) tokens: \(surplus) surplus tokens exceed the "
                    + "\(capacity) removable ones without cutting the chat template itself")
        }
        // Delete from the LAST range backwards so earlier indices stay valid,
        // while still consuming priority order (the first range is emptied
        // first, so compute each range's take in priority order and apply the
        // deletions in reverse).
        var takes = Array(repeating: 0, count: ranges.count)
        for (index, range) in ranges.enumerated() where surplus > 0 {
            let take = min(surplus, range.count)
            takes[index] = take
            surplus -= take
        }
        var result = tokenIDs
        for index in stride(from: ranges.count - 1, through: 0, by: -1) where takes[index] > 0 {
            let range = ranges[index]
            result.removeSubrange(range.lowerBound ..< (range.lowerBound + takes[index]))
        }
        return result
    }

    /// Filler first, instruction second: a prompt too short to hold both keeps
    /// as much of the instruction as it can, and a prompt too short to hold
    /// even the template is refused by `trimmed` with both numbers named.
    public static func removableRanges(
        promptTokens count: Int, shape: TemplateShape
    ) -> [Range<Int>] {
        let instructionStart = max(shape.templateHead, count - shape.templateTail
            - shape.instructionTokens)
        let instructionEnd = max(instructionStart, count - shape.templateTail)
        let fillerEnd = min(instructionStart, max(shape.templateHead, count))
        let fillerStart = min(shape.templateHead, fillerEnd)
        return [fillerStart ..< fillerEnd, instructionStart ..< instructionEnd]
            .filter { !$0.isEmpty }
    }

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var index = 0
        let limit = min(a.count, b.count)
        while index < limit, a[index] == b[index] { index += 1 }
        return index
    }

    static func commonSuffixLength(_ a: [Int], _ b: [Int]) -> Int {
        var index = 0
        let limit = min(a.count, b.count)
        while index < limit, a[a.count - 1 - index] == b[b.count - 1 - index] { index += 1 }
        return index
    }
}
