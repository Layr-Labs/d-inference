import Foundation

extension EngineV2Bridge {
    /// How many generated tokens the pump retains for stop-string
    /// identification, 0 when the request has no stop strings.
    ///
    /// The engine's `StopHoldback` stops on the EARLIEST full match across
    /// every candidate and the loop finishes one step late, so whenever a
    /// stop string caused a `.stop` the whole match lies inside the last
    /// few tokens. A bounded tail therefore decodes to the same verdict as
    /// the full output — at O(1) cost on the bridge actor (which every pump
    /// of this model shares) instead of an O(output) decode.
    ///
    /// Budget, in tokens: a byte-fallback scalar can span up to 4 tokens,
    /// so the longest candidate needs `4 × its scalar count`; +1 for the
    /// one-step-late token; +2 defensive margin. The invariant the bound
    /// rests on: the match plus at most one late token always sits inside
    /// the last `4N + 3` filtered tokens. One margin token was budgeted as
    /// a "leading context token" for SentencePiece leading-whitespace
    /// rendering, but the engine cannot produce a finish whose match starts
    /// at the tail boundary (a stop beginning with a one-byte space never
    /// fills its 4N budget), so that term is margin, not a load-bearing
    /// bound.
    static func stopTailTokenLimit(for candidates: [String]) -> Int {
        let longest = candidates.map { $0.unicodeScalars.count }.max() ?? 0
        guard longest > 0 else { return 0 }
        return 4 * longest + 3
    }

    /// Identify which caller stop sequence the engine stopped on, from the
    /// retained token tail (`stopTailTokenLimit`). The tail decode is a
    /// suffix of the full decode, so earliest-match / lowest-index
    /// semantics are unchanged. One documented divergence: a `.length`/EOS
    /// finish whose FULL decode happened to contain a candidate the engine
    /// never matched (a SentencePiece whitespace-rewrite artifact) used to
    /// report that stale match; the pump still runs identification for
    /// `.length`, so such an artifact is reported only when it sits inside
    /// the retained tail and is nil otherwise.
    func matchedStopSequence(
        candidates: [String],
        generatedTokens: [Int]
    ) -> String? {
        guard !candidates.isEmpty, !generatedTokens.isEmpty else { return nil }
        let generatedText = tokenizer.inner.decode(
            tokenIds: generatedTokens,
            skipSpecialTokens: false
        )
        return Self.matchedStopSequence(candidates: candidates, generatedText: generatedText)
    }

    static func matchedStopSequence(
        candidates: [String],
        generatedText: String
    ) -> String? {
        let generatedScalars = Array(generatedText.unicodeScalars)
        var best: (position: Int, candidateIndex: Int, value: String)?
        for (candidateIndex, candidate) in candidates.enumerated() where !candidate.isEmpty {
            let candidateScalars = Array(candidate.unicodeScalars)
            guard candidateScalars.count <= generatedScalars.count else { continue }
            var matchPosition: Int?
            for position in 0...(generatedScalars.count - candidateScalars.count) {
                if generatedScalars[position..<(position + candidateScalars.count)]
                    .elementsEqual(candidateScalars)
                {
                    matchPosition = position
                    break
                }
            }
            guard let matchPosition else { continue }
            if let current = best {
                if matchPosition > current.position
                    || (matchPosition == current.position
                        && candidateIndex > current.candidateIndex)
                {
                    continue
                }
            }
            best = (matchPosition, candidateIndex, candidate)
        }
        return best?.value
    }
}
