import Foundation

public enum AdaptivePrefillDecisionReason: String, Codable, Sendable, Equatable {
    case initial
    case steady
    case grow
    case cooldown
    case capped
    case shrinkChunkTooSlow
    case shrinkMemoryPressure
    case shrinkThermalPressure
    case shrinkDecodeHarm
    case shrinkResourceError
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

public struct AdaptivePrefillState: Codable, Sendable, Equatable {
    public var currentChunkSize: Int
    public var cleanSamplesAtCurrentSize: Int
    public var cooldownSamplesRemaining: Int
    public var lastDecisionReason: AdaptivePrefillDecisionReason

    public init(
        currentChunkSize: Int = 512,
        cleanSamplesAtCurrentSize: Int = 0,
        cooldownSamplesRemaining: Int = 0,
        lastDecisionReason: AdaptivePrefillDecisionReason = .initial
    ) {
        self.currentChunkSize = currentChunkSize
        self.cleanSamplesAtCurrentSize = cleanSamplesAtCurrentSize
        self.cooldownSamplesRemaining = cooldownSamplesRemaining
        self.lastDecisionReason = lastDecisionReason
    }
}

public struct AdaptivePrefillSample: Sendable, Equatable {
    public var requestedChunkSize: Int
    public var actualChunkSize: Int
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
        durationMs: Double,
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
        self.durationMs = durationMs
        self.decodeBatchSize = decodeBatchSize
        self.memorySignal = memorySignal
        self.thermalSignal = thermalSignal
        self.decodeLatencyHarmed = decodeLatencyHarmed
        self.resourceError = resourceError
        self.cappedByBudget = cappedByBudget
        self.cappedByCheckpoint = cappedByCheckpoint
        self.cappedByRemaining = cappedByRemaining
    }
}

public struct AdaptivePrefillTransition: Sendable, Equatable {
    public let state: AdaptivePrefillState
    public let reason: AdaptivePrefillDecisionReason
    public let changedChunkSize: Bool
}

public struct AdaptivePrefillPolicy: Sendable, Equatable {
    public static let productionLadder = [512, 1024, 2048, 4096]
    public static let experimentalLadder = [512, 1024, 2048, 4096, 8192]

    public let ladder: [Int]
    public let targetChunkDurationMs: Double
    public let growthSampleCount: Int
    public let cooldownSampleCount: Int

    public init(
        ladder: [Int] = AdaptivePrefillPolicy.productionLadder,
        targetChunkDurationMs: Double = 100,
        growthSampleCount: Int = 8,
        cooldownSampleCount: Int = 4
    ) {
        let sanitized = Array(Set(ladder.filter { $0 > 0 })).sorted()
        self.ladder = sanitized.isEmpty ? Self.productionLadder : sanitized
        self.targetChunkDurationMs = max(1, targetChunkDurationMs)
        self.growthSampleCount = max(1, growthSampleCount)
        self.cooldownSampleCount = max(0, cooldownSampleCount)
    }

    public static func liveDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> AdaptivePrefillPolicy {
        let target = environment["DARKBLOOM_ADAPTIVE_PREFILL_TARGET_MS"]
            .flatMap(Double.init)
            .map { max(1, $0) } ?? 100
        let allow8192 = AdaptivePrefillPolicy.envFlag(
            environment["DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192"])
        return AdaptivePrefillPolicy(
            ladder: allow8192 ? experimentalLadder : productionLadder,
            targetChunkDurationMs: target
        )
    }

    public func initialState(persisted: AdaptivePrefillState? = nil) -> AdaptivePrefillState {
        guard let persisted,
              ladder.contains(persisted.currentChunkSize)
        else {
            return AdaptivePrefillState(currentChunkSize: ladder.first ?? 512)
        }
        return AdaptivePrefillState(
            currentChunkSize: persisted.currentChunkSize,
            cleanSamplesAtCurrentSize: 0,
            cooldownSamplesRemaining: max(0, persisted.cooldownSamplesRemaining),
            lastDecisionReason: .steady
        )
    }

    public func proposedChunkSize(state: AdaptivePrefillState) -> Int {
        guard ladder.contains(state.currentChunkSize) else { return ladder.first ?? 512 }
        return state.currentChunkSize
    }

    public func record(sample: AdaptivePrefillSample, state: AdaptivePrefillState) -> AdaptivePrefillTransition {
        var next = normalized(state)

        if let reason = harmReason(sample) {
            let shrunk = shrink(next.currentChunkSize)
            next.currentChunkSize = shrunk
            next.cleanSamplesAtCurrentSize = 0
            next.cooldownSamplesRemaining = cooldownSampleCount
            next.lastDecisionReason = reason
            return AdaptivePrefillTransition(
                state: next,
                reason: reason,
                changedChunkSize: shrunk != state.currentChunkSize
            )
        }

        if sample.cappedByBudget || sample.cappedByCheckpoint || sample.cappedByRemaining {
            next.cleanSamplesAtCurrentSize = 0
            next.cooldownSamplesRemaining = max(0, next.cooldownSamplesRemaining - 1)
            next.lastDecisionReason = .capped
            return AdaptivePrefillTransition(state: next, reason: .capped, changedChunkSize: false)
        }

        if next.cooldownSamplesRemaining > 0 {
            next.cooldownSamplesRemaining -= 1
            next.cleanSamplesAtCurrentSize = 0
            next.lastDecisionReason = .cooldown
            return AdaptivePrefillTransition(state: next, reason: .cooldown, changedChunkSize: false)
        }

        guard sample.actualChunkSize >= next.currentChunkSize,
              sample.requestedChunkSize >= next.currentChunkSize,
              sample.durationMs <= targetChunkDurationMs
        else {
            next.cleanSamplesAtCurrentSize = 0
            next.lastDecisionReason = .steady
            return AdaptivePrefillTransition(state: next, reason: .steady, changedChunkSize: false)
        }

        next.cleanSamplesAtCurrentSize += 1
        if next.cleanSamplesAtCurrentSize >= growthSampleCount {
            let grown = grow(next.currentChunkSize)
            next.cleanSamplesAtCurrentSize = 0
            next.currentChunkSize = grown
            next.lastDecisionReason = grown == state.currentChunkSize ? .steady : .grow
            return AdaptivePrefillTransition(
                state: next,
                reason: next.lastDecisionReason,
                changedChunkSize: grown != state.currentChunkSize
            )
        }

        next.lastDecisionReason = .steady
        return AdaptivePrefillTransition(state: next, reason: .steady, changedChunkSize: false)
    }

    private static func envFlag(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    private func normalized(_ state: AdaptivePrefillState) -> AdaptivePrefillState {
        guard ladder.contains(state.currentChunkSize) else {
            return AdaptivePrefillState(currentChunkSize: ladder.first ?? 512)
        }
        return state
    }

    private func harmReason(_ sample: AdaptivePrefillSample) -> AdaptivePrefillDecisionReason? {
        if sample.resourceError { return .shrinkResourceError }
        if sample.memorySignal == .high || sample.memorySignal == .critical {
            return .shrinkMemoryPressure
        }
        if sample.thermalSignal == .serious || sample.thermalSignal == .critical {
            return .shrinkThermalPressure
        }
        if sample.decodeLatencyHarmed { return .shrinkDecodeHarm }
        if sample.durationMs > targetChunkDurationMs { return .shrinkChunkTooSlow }
        return nil
    }

    private func grow(_ value: Int) -> Int {
        guard let index = ladder.firstIndex(of: value), index + 1 < ladder.count else { return value }
        return ladder[index + 1]
    }

    private func shrink(_ value: Int) -> Int {
        guard let index = ladder.firstIndex(of: value), index > 0 else { return ladder.first ?? 512 }
        return ladder[index - 1]
    }
}
