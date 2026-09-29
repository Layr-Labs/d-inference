import Foundation

struct QualificationPostureSnapshot: Codable, Sendable {
    let thermalState: Int
    let lowPowerMode: Bool
    var isNominal: Bool { thermalState == 0 && !lowPowerMode }

    static func capture() -> Self {
        Self(thermalState: ProcessInfo.processInfo.thermalState.rawValue,
             lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

struct QualificationCooldownReceipt: Codable, Sendable {
    let before: QualificationPostureSnapshot
    let after: QualificationPostureSnapshot
    let waitedMilliseconds: Double
    let nominalStableMilliseconds: Double
    let minimumMilliseconds: Int
    let stableMilliseconds: Int
    let recoveryLimitMilliseconds: Int
    let passed: Bool
}

/// Fixed before collecting a cohort; no sample is removed or retried after a
/// thermal failure. Recovery time belongs to preparation, outside GPU timing.
struct QualificationPostureGate {
    static let minimumMilliseconds = 20_000
    static let stableMilliseconds = 5_000
    static let recoveryLimitMilliseconds = 180_000
    private(set) var nominalSinceMilliseconds: Double?

    mutating func observe(_ posture: QualificationPostureSnapshot, elapsedMilliseconds: Double) -> Bool? {
        if posture.isNominal {
            if nominalSinceMilliseconds == nil { nominalSinceMilliseconds = elapsedMilliseconds }
        } else {
            nominalSinceMilliseconds = nil
        }
        if elapsedMilliseconds > Double(Self.recoveryLimitMilliseconds) { return false }
        let stable = nominalSinceMilliseconds.map { elapsedMilliseconds - $0 } ?? 0
        if elapsedMilliseconds >= Double(Self.minimumMilliseconds), stable >= Double(Self.stableMilliseconds) {
            return true
        }
        return elapsedMilliseconds >= Double(Self.recoveryLimitMilliseconds) ? false : nil
    }

    static func waitForNominal() async throws -> QualificationCooldownReceipt {
        let started = ContinuousClock.now
        let before = QualificationPostureSnapshot.capture()
        var gate = Self()
        while true {
            try Task.checkCancellation()
            let after = QualificationPostureSnapshot.capture()
            let duration = started.duration(to: .now).components
            let elapsed = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            if let passed = gate.observe(after, elapsedMilliseconds: elapsed) {
                return QualificationCooldownReceipt(before: before, after: after,
                    waitedMilliseconds: elapsed,
                    nominalStableMilliseconds: gate.nominalSinceMilliseconds.map { elapsed - $0 } ?? 0,
                    minimumMilliseconds: minimumMilliseconds, stableMilliseconds: stableMilliseconds,
                    recoveryLimitMilliseconds: recoveryLimitMilliseconds, passed: passed)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}

struct QualificationTrialPostureReceipt: Codable, Sendable {
    let before: QualificationPostureSnapshot
    let after: QualificationPostureSnapshot
    let worstThermalState: Int
    let lowPowerObserved: Bool
    var isNominal: Bool {
        before.isNominal && after.isNominal && worstThermalState == 0 && !lowPowerObserved
    }
}

/// Opt-in harness-only observation. It neither changes power/fan policy nor
/// waits for recovery while measured inference is executing.
final class QualificationPostureMonitor: Sendable {
    private let state: PostureState
    private let task: Task<Void, Never>

    init() {
        let state = PostureState(initial: .capture())
        self.state = state
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                if !Task.isCancelled { state.observe(.capture()) }
            }
        }
    }

    func finish() async -> QualificationTrialPostureReceipt {
        task.cancel()
        await task.value
        return state.finish(after: .capture())
    }

    deinit { task.cancel() }
}

private final class PostureState: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: QualificationPostureSnapshot
    private var worstThermalState: Int
    private var lowPowerObserved: Bool

    init(initial: QualificationPostureSnapshot) {
        self.initial = initial
        worstThermalState = initial.thermalState
        lowPowerObserved = initial.lowPowerMode
    }

    func observe(_ posture: QualificationPostureSnapshot) {
        lock.withLock {
            worstThermalState = max(worstThermalState, posture.thermalState)
            lowPowerObserved = lowPowerObserved || posture.lowPowerMode
        }
    }

    func finish(after: QualificationPostureSnapshot) -> QualificationTrialPostureReceipt {
        observe(after)
        return lock.withLock {
            QualificationTrialPostureReceipt(before: initial, after: after,
                worstThermalState: worstThermalState, lowPowerObserved: lowPowerObserved)
        }
    }
}

enum QualificationPostureFailure: Error { case recoveryTimedOut, nonNominalMeasurement }
