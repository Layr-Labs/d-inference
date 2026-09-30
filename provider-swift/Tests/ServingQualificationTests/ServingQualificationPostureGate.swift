import Foundation

/// Fixed before collecting a cohort. Thermal recovery is allowed; a missing
/// source observation, a non-AC source or a sampling gap fails this cohort.
struct QualificationPostureGate {
    static let minimumMilliseconds = 20_000
    static let stableMilliseconds = 5_000
    static let recoveryLimitMilliseconds = 180_000
    private(set) var nominalSinceMilliseconds: Double?
    private(set) var observations: [QualificationPostureObservation] = []
    private(set) var droppedObservations = 0
    private var invalid = false

    mutating func observe(_ posture: QualificationPostureSnapshot, elapsedMilliseconds: Double) -> Bool? {
        let previous = observations.last?.elapsedMilliseconds
        if observations.count < QualificationPostureObservation.maximumCount {
            observations.append(.init(elapsedMilliseconds: elapsedMilliseconds, snapshot: posture))
        } else { droppedObservations += 1; invalid = true }
        if !elapsedMilliseconds.isFinite || elapsedMilliseconds < 0
            || (previous == nil && elapsedMilliseconds != 0)
            || (previous.map { elapsedMilliseconds <= $0 || elapsedMilliseconds - $0 > QualificationPostureObservation.maximumGapMilliseconds } ?? false)
            || !posture.hasMeasuredAutomaticAC { invalid = true }
        guard !invalid else { return false }
        if posture.isNominal {
            if nominalSinceMilliseconds == nil { nominalSinceMilliseconds = elapsedMilliseconds }
        } else { nominalSinceMilliseconds = nil }
        if elapsedMilliseconds > Double(Self.recoveryLimitMilliseconds) { return false }
        let stable = nominalSinceMilliseconds.map { elapsedMilliseconds - $0 } ?? 0
        if elapsedMilliseconds >= Double(Self.minimumMilliseconds), stable >= Double(Self.stableMilliseconds) {
            return true
        }
        return elapsedMilliseconds >= Double(Self.recoveryLimitMilliseconds) ? false : nil
    }

    static func waitForNominal() async throws -> QualificationCooldownReceipt {
        let before = QualificationPostureSnapshot.capture()
        let started = ContinuousClock.now
        var gate = Self()
        var after = before
        var elapsed = 0.0
        while true {
            try Task.checkCancellation()
            if let passed = gate.observe(after, elapsedMilliseconds: elapsed) {
                return QualificationCooldownReceipt(before: before, after: after,
                    waitedMilliseconds: elapsed,
                    nominalStableMilliseconds: gate.nominalSinceMilliseconds.map { elapsed - $0 } ?? 0,
                    minimumMilliseconds: minimumMilliseconds, stableMilliseconds: stableMilliseconds,
                    recoveryLimitMilliseconds: recoveryLimitMilliseconds,
                    observations: gate.observations, droppedObservations: gate.droppedObservations, passed: passed)
            }
            try await Task.sleep(for: .milliseconds(500))
            after = .capture()
            let duration = started.duration(to: .now).components
            elapsed = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
    }
}
