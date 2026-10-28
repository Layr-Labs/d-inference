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
            let holdback = StopHoldback(stopStrings: candidates, scope: scope)
            let scan = holdback.ingest(generatedText)
            guard scan.stopped else { return nil }
            let tail = generatedText.unicodeScalars.dropFirst(scan.text.unicodeScalars.count)
            return candidates.first { !$0.isEmpty && tail.starts(with: $0.unicodeScalars) }
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
