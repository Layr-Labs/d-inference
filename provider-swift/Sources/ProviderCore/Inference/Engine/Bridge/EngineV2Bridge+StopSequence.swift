import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    func matchedStopSequence(
        candidates: [String],
        generatedTokens: [Int],
        scope: CBv2StopStringScope?
    ) -> String? {
        guard !candidates.isEmpty, !generatedTokens.isEmpty else { return nil }
        let generatedText = tokenizer.inner.decode(
            tokenIds: generatedTokens,
            skipSpecialTokens: false
        )
        return Self.matchedStopSequence(
            candidates: candidates, generatedText: generatedText, scope: scope)
    }

    /// The candidate that ended generation. A scoped request matched stops
    /// only inside its scope, so a candidate seen elsewhere (Harmony analysis,
    /// reasoning) did not stop it.
    static func matchedStopSequence(
        candidates: [String],
        generatedText: String,
        scope: CBv2StopStringScope? = nil
    ) -> String? {
        if let scope {
            let scan = StopHoldback(stopStrings: candidates, scope: scope).ingest(generatedText)
            guard scan.stopped else { return nil }
            // The first candidate that alone stops at the same place: one that
            // merely starts there may not count (whitespace before an answer).
            return candidates.first {
                !$0.isEmpty
                    && StopHoldback(stopStrings: [$0], scope: scope).ingest(generatedText) == scan
            }
        }
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
