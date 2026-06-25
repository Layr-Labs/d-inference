import Foundation

/// Outcome label attached to every `AdaptivePrefillPolicy.record` transition.
/// Persisted inside `AdaptivePrefillState`, so cases are only ever added — the
/// store-version gate (`AdaptivePrefillStore` v2 + `policyVersion`) is what
/// retires stale state, not enum removal.
public enum AdaptivePrefillDecisionReason: String, Codable, Sendable, Equatable {
    case initial
    case steady
    case grow
    /// Descend one rung to MEASURE an as-yet-unmeasured lower neighbour before
    /// settling. Lets an overshooting seed / restored rung self-correct downward
    /// by measurement (a one-time bracket) instead of staying oversized until
    /// memory/thermal/decode harm forces a back-off. See `AdaptivePrefillPolicy.settle`.
    case probeDown
    case cooldown
    case capped
    /// Settled at the measured throughput optimum (held, or rolled back to the
    /// smaller rung of a flat-band pair).
    case holdOptimum
    /// Shrunk because a larger rung was confirmed slower per token.
    case shrinkThroughputRegression
    case shrinkMemoryPressure
    case shrinkThermalPressure
    case shrinkDecodeHarm
    case shrinkResourceError
    /// Deprecated: the duration-vs-target shrink was replaced by the measured
    /// ms/token hill-climb. Retained so any pre-v2 persisted state still decodes.
    case shrinkChunkTooSlow
}

public enum AdaptivePrefillMemorySignal: String, Codable, Sendable, Equatable {
    case normal
    case high
    case critical
}

public enum AdaptivePrefillThermalSignal: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

/// Persisted, self-calibrating state for one `(model, weights, kv-mode,
/// hardware)` key. `rungMsPerToken` is the per-rung EWMA of measured
/// ms/token; `ceiling` is a soft upper bound learned from harm or a confirmed
/// throughput regression so the climber never re-grows into a known wall.
public struct AdaptivePrefillState: Codable, Sendable, Equatable {
    public var currentChunkSize: Int
    public var cleanSamplesAtCurrentSize: Int
    public var cooldownSamplesRemaining: Int
    /// Consecutive observations that the current rung is slower than the rung
    /// below it. A rung is only abandoned once this reaches
    /// `regressionConfirmations`, so a single noisy sample never shrinks it.
    public var regressionConfirmations: Int
    /// Clean samples accumulated since the last ceiling reset; drives the
    /// optional periodic upward re-exploration.
    public var samplesSinceReexplore: Int
    /// Largest rung the climber is currently allowed to occupy. nil ⇒ the
    /// ladder's own maximum. Tightened by harm / confirmed regression.
    public var ceiling: Int?
    /// Per-rung EWMA of measured ms/token (keyed by chunk size).
    public var rungMsPerToken: [Int: Double]
    public var lastDecisionReason: AdaptivePrefillDecisionReason
    /// Algorithm/version stamp. On load, state whose `policyVersion` differs
    /// from the live policy identity is discarded → clean re-seed.
    public var policyVersion: String

    public init(
        currentChunkSize: Int = 512,
        cleanSamplesAtCurrentSize: Int = 0,
        cooldownSamplesRemaining: Int = 0,
        regressionConfirmations: Int = 0,
        samplesSinceReexplore: Int = 0,
        ceiling: Int? = nil,
        rungMsPerToken: [Int: Double] = [:],
        lastDecisionReason: AdaptivePrefillDecisionReason = .initial,
        policyVersion: String = AdaptivePrefillPolicy.algorithmIdentity
    ) {
        self.currentChunkSize = currentChunkSize
        self.cleanSamplesAtCurrentSize = cleanSamplesAtCurrentSize
        self.cooldownSamplesRemaining = cooldownSamplesRemaining
        self.regressionConfirmations = regressionConfirmations
        self.samplesSinceReexplore = samplesSinceReexplore
        self.ceiling = ceiling
        self.rungMsPerToken = rungMsPerToken
        self.lastDecisionReason = lastDecisionReason
        self.policyVersion = policyVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentChunkSize = try c.decode(Int.self, forKey: .currentChunkSize)
        cleanSamplesAtCurrentSize = try c.decodeIfPresent(Int.self, forKey: .cleanSamplesAtCurrentSize) ?? 0
        cooldownSamplesRemaining = try c.decodeIfPresent(Int.self, forKey: .cooldownSamplesRemaining) ?? 0
        regressionConfirmations = try c.decodeIfPresent(Int.self, forKey: .regressionConfirmations) ?? 0
        samplesSinceReexplore = try c.decodeIfPresent(Int.self, forKey: .samplesSinceReexplore) ?? 0
        ceiling = try c.decodeIfPresent(Int.self, forKey: .ceiling)
        rungMsPerToken = try c.decodeIfPresent([Int: Double].self, forKey: .rungMsPerToken) ?? [:]
        lastDecisionReason = try c.decodeIfPresent(AdaptivePrefillDecisionReason.self, forKey: .lastDecisionReason) ?? .initial
        // Absent stamp ⇒ pre-versioning state; mark it stale so the version gate re-seeds.
        policyVersion = try c.decodeIfPresent(String.self, forKey: .policyVersion) ?? ""
    }
}

/// One measured cold-prefill chunk, normalized for the policy. `msPerToken` is
/// the throughput signal the hill-climb optimizes; `positionOffset` and the
/// capped/overlap flags decide whether the sample is "clean" enough to move the
/// ladder.
public struct AdaptivePrefillSample: Sendable, Equatable {
    public var requestedChunkSize: Int
    public var actualChunkSize: Int
    public var totalTokens: Int
    public var positionOffset: Int
    public var durationMs: Double
    public var decodeBatchSize: Int
    public var memorySignal: AdaptivePrefillMemorySignal
    public var thermalSignal: AdaptivePrefillThermalSignal
    public var decodeLatencyHarmed: Bool
    public var resourceError: Bool
    public var cappedByBudget: Bool
    public var cappedByCheckpoint: Bool
    public var cappedByRemaining: Bool

    public init(
        requestedChunkSize: Int,
        actualChunkSize: Int,
        totalTokens: Int,
        durationMs: Double,
        positionOffset: Int = 0,
        decodeBatchSize: Int = 0,
        memorySignal: AdaptivePrefillMemorySignal = .normal,
        thermalSignal: AdaptivePrefillThermalSignal = .nominal,
        decodeLatencyHarmed: Bool = false,
        resourceError: Bool = false,
        cappedByBudget: Bool = false,
        cappedByCheckpoint: Bool = false,
        cappedByRemaining: Bool = false
    ) {
        self.requestedChunkSize = requestedChunkSize
        self.actualChunkSize = actualChunkSize
        self.totalTokens = totalTokens
        self.durationMs = durationMs
        self.positionOffset = positionOffset
        self.decodeBatchSize = decodeBatchSize
        self.memorySignal = memorySignal
        self.thermalSignal = thermalSignal
        self.decodeLatencyHarmed = decodeLatencyHarmed
        self.resourceError = resourceError
        self.cappedByBudget = cappedByBudget
        self.cappedByCheckpoint = cappedByCheckpoint
        self.cappedByRemaining = cappedByRemaining
    }

    /// Measured milliseconds per prefilled token — the quantity the policy
    /// hill-climbs. Guards against a zero token count.
    public var msPerToken: Double {
        durationMs / Double(max(1, totalTokens))
    }
}

public struct AdaptivePrefillTransition: Sendable, Equatable {
    public let state: AdaptivePrefillState
    public let reason: AdaptivePrefillDecisionReason
    public let changedChunkSize: Bool
}
