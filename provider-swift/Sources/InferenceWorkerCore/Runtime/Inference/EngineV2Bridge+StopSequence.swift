import Foundation

extension EngineV2Bridge {
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
