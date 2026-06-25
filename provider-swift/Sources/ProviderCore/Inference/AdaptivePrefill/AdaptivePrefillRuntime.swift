import Foundation
import MLXLMCommon
import os

let adaptivePrefillLogger = Logger(
    subsystem: "dev.darkbloom.provider",
    category: "adaptive-prefill"
)

public final class AdaptivePrefillRuntime: @unchecked Sendable {
    private let policy: AdaptivePrefillPolicy
    private let store: AdaptivePrefillStore
    private let key: AdaptivePrefillStoreKey
    private let lock = NSLock()
    private var state: AdaptivePrefillState

    public init(
        policy: AdaptivePrefillPolicy = .liveDefault(),
        store: AdaptivePrefillStore = AdaptivePrefillStore(),
        key: AdaptivePrefillStoreKey
    ) {
        self.policy = policy
        self.store = store
        self.key = key
        self.state = policy.initialState(persisted: store.load(key: key))
    }

    public func proposeChunkSize(_: PrefillChunkContext) -> Int {
        lock.lock()
        let proposed = policy.proposedChunkSize(state: state)
        lock.unlock()
        return max(1, proposed)
    }

    public func record(_ sample: ColdPrefillChunkSample) {
        let signals = Self.currentSafetySignals()
        let policySample = AdaptivePrefillSample(
            requestedChunkSize: sample.requestedChunkSize,
            actualChunkSize: sample.actualChunkSize,
            durationMs: sample.durationSeconds * 1000.0,
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
            "adaptive-prefill \(transition.reason.rawValue, privacy: .public): chunk \(previous.currentChunkSize) -> \(transition.state.currentChunkSize), duration_ms=\(policySample.durationMs, privacy: .public)"
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

    private static func currentSafetySignals() -> (
        memory: AdaptivePrefillMemorySignal,
        thermal: AdaptivePrefillThermalSignal
    ) {
        let cores = UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let metrics = SystemMetricsCollector.collect(cpuCores: cores)
        return (
            memorySignal(metrics.memoryPressure),
            thermalSignal(metrics.thermalState)
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
