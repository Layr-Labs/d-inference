import Foundation
import MLXLMCommon
import os

let adaptivePrefillLogger = Logger(
    subsystem: "dev.darkbloom.provider",
    category: "adaptive-prefill"
)

public final class AdaptivePrefillRuntime: @unchecked Sendable {
    /// Live OS memory/thermal signals. Injectable so tests can drive the harm
    /// path deterministically without mocking the policy or store (the real
    /// components under test); production leaves it nil and samples the OS.
    public typealias SafetySignalProvider = @Sendable () -> (
        memory: AdaptivePrefillMemorySignal, thermal: AdaptivePrefillThermalSignal
    )

    private struct SafetySignals {
        let memory: AdaptivePrefillMemorySignal
        let thermal: AdaptivePrefillThermalSignal
    }

    private let policy: AdaptivePrefillPolicy
    private let store: AdaptivePrefillStore
    private let key: AdaptivePrefillStoreKey
    private let safetySignalTTL: TimeInterval
    private let safetySignalProvider: SafetySignalProvider?
    private let lock = NSLock()
    private var state: AdaptivePrefillState
    private var cachedSafetySignals: (sampledAt: Date, signals: SafetySignals)?

    public init(
        policy: AdaptivePrefillPolicy = .liveDefault(),
        store: AdaptivePrefillStore = AdaptivePrefillStore(),
        key: AdaptivePrefillStoreKey,
        safetySignalTTL: TimeInterval = 2.0,
        safetySignalProvider: SafetySignalProvider? = nil
    ) {
        self.policy = policy
        self.store = store
        self.key = key
        self.safetySignalTTL = max(0.1, safetySignalTTL)
        self.safetySignalProvider = safetySignalProvider
        self.state = policy.initialState(persisted: store.load(key: key))
    }

    public func proposeChunkSize(_: PrefillChunkContext) -> Int {
        lock.lock()
        let proposed = policy.proposedChunkSize(state: state)
        lock.unlock()
        return max(1, proposed)
    }

    public func record(_ sample: ColdPrefillChunkSample) {
        let signals = safetySignals()
        let policySample = AdaptivePrefillSample(
            requestedChunkSize: sample.requestedChunkSize,
            actualChunkSize: sample.actualChunkSize,
            totalTokens: sample.totalTokens,
            durationMs: sample.durationSeconds * 1000.0,
            positionOffset: sample.positionOffset,
            decodeBatchSize: sample.decodeBatchSize,
            memorySignal: signals.memory,
            thermalSignal: signals.thermal,
            cappedByBudget: sample.cappedByBudget,
            cappedByCheckpoint: sample.cappedByCheckpoint,
            cappedByRemaining: sample.cappedByRemaining
        )

        lock.lock()
        let previous = state
        let transition = policy.record(sample: policySample, state: previous)
        state = transition.state
        lock.unlock()

        guard transition.changedChunkSize else { return }
        adaptivePrefillLogger.notice(
            "adaptive-prefill \(transition.reason.rawValue, privacy: .public): chunk \(previous.currentChunkSize) -> \(transition.state.currentChunkSize), ms_per_token=\(policySample.msPerToken, privacy: .public) (total_tokens=\(policySample.totalTokens, privacy: .public), pos_offset=\(policySample.positionOffset, privacy: .public))"
        )
        do {
            try store.save(transition.state, key: key)
        } catch {
            adaptivePrefillLogger.warning(
                "adaptive-prefill state persistence failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func snapshotState() -> AdaptivePrefillState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func safetySignals(now: Date = Date()) -> SafetySignals {
        lock.lock()
        if let cachedSafetySignals,
           now.timeIntervalSince(cachedSafetySignals.sampledAt) < safetySignalTTL {
            let signals = cachedSafetySignals.signals
            lock.unlock()
            return signals
        }
        lock.unlock()

        let signals: SafetySignals
        if let safetySignalProvider {
            let resolved = safetySignalProvider()
            signals = SafetySignals(memory: resolved.memory, thermal: resolved.thermal)
        } else {
            signals = Self.currentSafetySignals()
        }

        lock.lock()
        cachedSafetySignals = (sampledAt: now, signals: signals)
        lock.unlock()
        return signals
    }

    private static func currentSafetySignals() -> SafetySignals {
        let cores = UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let metrics = SystemMetricsCollector.collect(cpuCores: cores)
        return SafetySignals(
            memory: memorySignal(metrics.memoryPressure),
            thermal: thermalSignal(metrics.thermalState)
        )
    }

    private static func memorySignal(_ pressure: Double) -> AdaptivePrefillMemorySignal {
        if pressure >= 0.92 { return .critical }
        if pressure >= 0.85 { return .high }
        return .normal
    }

    private static func thermalSignal(_ thermal: ThermalState) -> AdaptivePrefillThermalSignal {
        switch thermal {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }
}
