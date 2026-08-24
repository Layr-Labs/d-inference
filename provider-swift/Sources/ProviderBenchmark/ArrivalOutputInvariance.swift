/// Exact output comparisons for one arrival pattern.
///
/// First-token parity is the prefill contract. Full generated-output parity is
/// retained separately because later decode tokens can expose useful drift and
/// must never be hidden by a passing first-token comparison.
struct ArrivalOutputInvariance: Sendable, Equatable {
    let outputsStableAcrossIterations: Bool
    let outputsMatchBurst: Bool
    let firstTokensStableAcrossIterations: Bool
    let firstTokensMatchBurst: Bool

    static func evaluate(
        outputsByIteration: [[[Int]]],
        burstOutputs: [[Int]]
    ) -> Self {
        guard let referenceOutputs = outputsByIteration.first,
              let referenceFirstTokens = firstTokens(in: referenceOutputs),
              let burstFirstTokens = firstTokens(in: burstOutputs)
        else {
            return Self(
                outputsStableAcrossIterations: false,
                outputsMatchBurst: false,
                firstTokensStableAcrossIterations: false,
                firstTokensMatchBurst: false)
        }

        let allFirstTokens = outputsByIteration.compactMap(firstTokens(in:))
        let everyIterationHasFirstTokens =
            allFirstTokens.count == outputsByIteration.count
        return Self(
            outputsStableAcrossIterations: outputsByIteration.allSatisfy {
                $0 == referenceOutputs
            },
            outputsMatchBurst: outputsByIteration.allSatisfy {
                $0 == burstOutputs
            },
            firstTokensStableAcrossIterations:
                everyIterationHasFirstTokens
                && allFirstTokens.allSatisfy { $0 == referenceFirstTokens },
            firstTokensMatchBurst:
                everyIterationHasFirstTokens
                && allFirstTokens.allSatisfy { $0 == burstFirstTokens })
    }

    private static func firstTokens(in outputs: [[Int]]) -> [Int]? {
        guard !outputs.isEmpty, outputs.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return outputs.compactMap(\.first)
    }
}
