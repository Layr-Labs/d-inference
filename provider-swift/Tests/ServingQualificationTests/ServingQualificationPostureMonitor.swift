import Foundation

/// Opt-in harness-only observation; never changes power policy or delays GPU work.
final class QualificationPostureMonitor: Sendable {
    private let state: QualificationPostureHistory
    private let task: Task<Void, Never>
    private let started: ContinuousClock.Instant

    init() {
        let state = QualificationPostureHistory(initial: .capture())
        let started = ContinuousClock.now
        self.state = state
        self.started = started
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                if !Task.isCancelled {
                    let snapshot = QualificationPostureSnapshot.capture()
                    state.observe(snapshot, elapsedMilliseconds: Self.milliseconds(started.duration(to: .now)))
                }
            }
        }
    }

    func finish() async -> QualificationTrialPostureReceipt {
        task.cancel()
        await task.value
        let after = QualificationPostureSnapshot.capture()
        return state.finish(after: after, elapsedMilliseconds: Self.milliseconds(started.duration(to: .now)))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    deinit { task.cancel() }
}

final class QualificationPostureHistory: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: QualificationPostureSnapshot
    private var worstThermalState: Int
    private var lowPowerObserved: Bool
    private var observations: [QualificationPostureObservation]
    private var dropped = 0

    init(initial: QualificationPostureSnapshot) {
        self.initial = initial
        worstThermalState = initial.thermalState
        lowPowerObserved = initial.lowPowerMode
        observations = [.init(elapsedMilliseconds: 0, snapshot: initial)]
    }

    func observe(_ posture: QualificationPostureSnapshot, elapsedMilliseconds: Double) {
        lock.withLock {
            worstThermalState = max(worstThermalState, posture.thermalState)
            lowPowerObserved = lowPowerObserved || posture.lowPowerMode
            if observations.count < QualificationPostureObservation.maximumCount {
                observations.append(.init(elapsedMilliseconds: elapsedMilliseconds, snapshot: posture))
            } else { dropped += 1 }
        }
    }

    func finish(after: QualificationPostureSnapshot, elapsedMilliseconds: Double) -> QualificationTrialPostureReceipt {
        observe(after, elapsedMilliseconds: elapsedMilliseconds)
        return lock.withLock {
            QualificationTrialPostureReceipt(before: initial, after: after,
                worstThermalState: worstThermalState, lowPowerObserved: lowPowerObserved,
                observations: observations, droppedObservations: dropped)
        }
    }
}
