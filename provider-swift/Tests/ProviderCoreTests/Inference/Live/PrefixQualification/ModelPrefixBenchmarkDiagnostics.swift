import MLXLMCommon

/// Actual immutable engine geometry, rather than the requested environment.
struct ModelPrefixBenchmarkSchedulerConfiguration: Codable, Sendable {
    let prefillChunkSize: Int
    let maxBatchedTokensPerStep: Int
    let soloPrefillStripeTokens: Int?
    let maxConcurrentRequests: Int
    let maxConcurrentPartialPrefills: Int?
    let demandedShortCheckpointMinimumTokens: Int?
    let demandedCheckpointPartitionIncludesLongPrompts: Bool

    init(_ config: CBv2SchedulerConfig) {
        prefillChunkSize = config.prefillChunkSize
        maxBatchedTokensPerStep = config.maxBatchedTokensPerStep
        soloPrefillStripeTokens = config.soloPrefillStripeTokens
        maxConcurrentRequests = config.maxConcurrentRequests
        maxConcurrentPartialPrefills = config.maxConcurrentPartialPrefills
        demandedShortCheckpointMinimumTokens = config.demandedShortCheckpointMinimumTokens
        demandedCheckpointPartitionIncludesLongPrompts = config.demandedCheckpointPartitionIncludesLongPrompts
    }
}

/// Opt-in synthetic-input observations from the actual ordinary event stream.
/// These logprob-enabled runs diagnose first divergence; their timing does
/// not qualify the normal benchmark's throughput or full logit-vector parity.
struct ModelPrefixBenchmarkTokenDiagnostics: Codable, Sendable {
    enum Failure: Error, Equatable { case incompleteLogprobs, tokenMismatch }
    struct TopToken: Codable, Sendable {
        let token: Int
        let logprob: Float?
    }
    struct Position: Codable, Sendable {
        let index: Int
        let token: Int
        let logprob: Float?
        let topTokens: [TopToken]
        /// A normalized logprob difference is the raw logit gap for this
        /// one vector. It cannot reconstruct distances between full vectors.
        let topTwoLogprobGap: Float?
        let hasNonFiniteLogprob: Bool
    }
    let generatedTokenIDs: [Int]
    let positions: [Position]

    init(tokens: [Int], logprobs: [CBv2TokenLogprob]) throws {
        guard tokens.count == logprobs.count else { throw Failure.incompleteLogprobs }
        generatedTokenIDs = tokens
        positions = try zip(tokens, logprobs).enumerated().map { index, pair in
            let (token, observation) = pair
            guard token == observation.token else { throw Failure.tokenMismatch }
            let top = observation.topLogprobs.sorted { $0.logprob > $1.logprob }
            let difference = top.count >= 2 && top[0].logprob.isFinite && top[1].logprob.isFinite
                ? top[0].logprob - top[1].logprob : nil
            let gap = difference.flatMap { $0.isFinite ? $0 : nil }
            return Position(index: index, token: token,
                logprob: observation.logprob.isFinite ? observation.logprob : nil,
                topTokens: top.map { TopToken(token: $0.token,
                    logprob: $0.logprob.isFinite ? $0.logprob : nil) },
                topTwoLogprobGap: gap,
                hasNonFiniteLogprob: !observation.logprob.isFinite
                    || top.contains { !$0.logprob.isFinite })
        }
    }
}
