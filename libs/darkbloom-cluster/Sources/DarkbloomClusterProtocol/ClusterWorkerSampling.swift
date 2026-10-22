import Foundation

/// How the decoding rank selects each token when a request is not plain
/// greedy text. The values are the single-Mac product's
/// (`CBv2SamplingParams`), already resolved by the provider: request fields,
/// then the artifact's defaults, then the contract's no-op values. A
/// reservation without sampling is greedy, byte for byte as before.
///
/// The decoding rank applies them exactly as the product's sampler does
/// (logit bias, then penalties, then temperature, then top-k / top-p / min-p,
/// then a keyed Gumbel-max draw), and keys its random stream on
/// `(seed, stream, output index)` as the product keys it on
/// `(seed, requestID, step)`. `stream` is the product's request identity for
/// the same request, so a seeded request draws the same noise on the pair as
/// on one Mac. Floating-point values travel as their IEEE-754 bit patterns:
/// the worker protocol carries integers only, and both ranks then hold the
/// identical values.
public struct ClusterWorkerSampling: Equatable, Sendable {
    public struct LogitBias: Equatable, Sendable {
        public let tokenID: Int
        public let bias: Float
        public init(tokenID: Int, bias: Float) { self.tokenID = tokenID; self.bias = bias }
    }

    /// Below this a temperature is greedy (the product's
    /// `LogitsPipelineV2.greedyEpsilon`).
    public static let greedyTemperature: Float = 1e-5
    /// The most logit-bias entries one request may carry.
    public static let maximumLogitBiasEntries = 4096

    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let minP: Float
    public let repetitionPenalty: Float
    public let repetitionContextSize: Int
    public let frequencyPenalty: Float
    public let presencePenalty: Float
    public let seed: UInt64
    public let stream: UInt64
    /// Ascending by token, each token at most once.
    public let logitBias: [LogitBias]

    public init(temperature: Float, topP: Float, topK: Int, minP: Float, repetitionPenalty: Float,
                repetitionContextSize: Int, frequencyPenalty: Float, presencePenalty: Float,
                seed: UInt64, stream: UInt64, logitBias: [LogitBias]) {
        self.temperature = temperature; self.topP = topP; self.topK = topK; self.minP = minP
        self.repetitionPenalty = repetitionPenalty; self.repetitionContextSize = repetitionContextSize
        self.frequencyPenalty = frequencyPenalty; self.presencePenalty = presencePenalty
        self.seed = seed; self.stream = stream; self.logitBias = logitBias
    }

    /// The draw is random (not an argmax).
    public var isStochastic: Bool { temperature >= Self.greedyTemperature }
    /// The penalty window has an effect, as the product decides it.
    public var hasRepetitionPenalty: Bool { repetitionPenalty != 1 && repetitionContextSize > 0 }
    /// A transform depends on the tokens selected so far. The product runs
    /// such requests without speculative decoding, and so do the pipeline's
    /// MTP paths; GLM tensor parallel replays them over each round's
    /// proposals (`QwenStageTokenSampler.verifyRound`).
    public var dependsOnHistory: Bool {
        !logitBias.isEmpty || hasRepetitionPenalty || frequencyPenalty != 0 || presencePenalty != 0
    }
    /// Nothing here changes a plain argmax: the reservation needs no sampling.
    public var isGreedyNoOp: Bool { !isStochastic && !dependsOnHistory }
    /// Speculative decoding verifies drafts against keyed target samples,
    /// as the product's target-prefix acceptance does. Only the stateless
    /// transforms are reproduced position by position.
    public var admitsSpeculativeVerification: Bool { !dependsOnHistory }
}

enum ClusterWorkerSamplingCodec {
    static func encode(_ s: ClusterWorkerSampling) -> [String: Any] {
        ["temperatureBits": Int(s.temperature.bitPattern), "topPBits": Int(s.topP.bitPattern), "topK": s.topK,
         "minPBits": Int(s.minP.bitPattern), "repetitionPenaltyBits": Int(s.repetitionPenalty.bitPattern),
         "repetitionContextSize": s.repetitionContextSize,
         "frequencyPenaltyBits": Int(s.frequencyPenalty.bitPattern),
         "presencePenaltyBits": Int(s.presencePenalty.bitPattern),
         "seed": hex(s.seed), "stream": hex(s.stream),
         "logitBiasTokenIDs": s.logitBias.map(\.tokenID), "logitBiasBits": s.logitBias.map { Int($0.bias.bitPattern) }]
    }

    static func decode(_ object: [String: Any]) throws -> ClusterWorkerSampling {
        var r = WorkerObject(object)
        func float(_ key: String) throws -> Float {
            let bits = try r.int(key)
            try workerRequire((0...Int(UInt32.max)).contains(bits), "Invalid sampling float bits: " + key)
            return Float(bitPattern: UInt32(bits))
        }
        let temperature = try float("temperatureBits"), topP = try float("topPBits"), topK = try r.int("topK")
        let minP = try float("minPBits"), repetitionPenalty = try float("repetitionPenaltyBits")
        let repetitionContextSize = try r.int("repetitionContextSize")
        let frequencyPenalty = try float("frequencyPenaltyBits"), presencePenalty = try float("presencePenaltyBits")
        let seed = try unhex(r.string("seed")), stream = try unhex(r.string("stream"))
        let tokens = try r.ints("logitBiasTokenIDs"), bits = try r.ints("logitBiasBits")
        try workerRequire(tokens.count == bits.count && bits.allSatisfy({ (0...Int(UInt32.max)).contains($0) }),
            "Invalid logit bias")
        try r.finish()
        return .init(temperature: temperature, topP: topP, topK: topK, minP: minP, repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize, frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty, seed: seed, stream: stream,
            logitBias: zip(tokens, bits).map { .init(tokenID: $0.0, bias: Float(bitPattern: UInt32($0.1))) })
    }

    static func validate(_ s: ClusterWorkerSampling) throws {
        let floats = [s.temperature, s.topP, s.minP, s.repetitionPenalty, s.frequencyPenalty, s.presencePenalty]
            + s.logitBias.map(\.bias)
        try workerRequire(floats.allSatisfy(\.isFinite)
            && (0...ClusterWorkerLimits.vocabularySize).contains(s.topK)
            && (0...ClusterWorkerLimits.contextTokens).contains(s.repetitionContextSize)
            && s.logitBias.count <= ClusterWorkerSampling.maximumLogitBiasEntries
            && s.logitBias.allSatisfy({ (0..<ClusterWorkerLimits.vocabularySize).contains($0.tokenID) })
            && zip(s.logitBias, s.logitBias.dropFirst()).allSatisfy({ $0.tokenID < $1.tokenID })
            && !s.isGreedyNoOp, "Invalid worker sampling")
    }

    /// Sixteen lowercase hexadecimal digits: a full 64-bit value that no
    /// JSON reader can round through a double.
    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
    private static func unhex(_ text: String) throws -> UInt64 {
        guard text.utf8.count == 16, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let value = UInt64(text, radix: 16) else {
            throw ClusterWorkerProtocolError.invalid("Expected sixteen lowercase hexadecimal digits")
        }
        return value
    }
}
