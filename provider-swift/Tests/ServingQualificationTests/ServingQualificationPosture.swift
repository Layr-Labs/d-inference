import Foundation

@testable import ProviderCore

struct QualificationPostureSnapshot: Codable, Sendable, Equatable {
    let thermalState: Int
    let lowPowerMode: Bool
    let powerSource: String?
    let automaticPower: Bool?
    let powerPolicyAgeMilliseconds: Double?
    var hasMeasuredAutomaticAC: Bool {
        guard powerSource == "ac", automaticPower == true, let age = powerPolicyAgeMilliseconds else { return false }
        return age.isFinite && age >= 0 && age < 3000
    }
    var isNominal: Bool { thermalState == 0 && !lowPowerMode && hasMeasuredAutomaticAC }

    static func capture() -> Self {
        let source = DeadlinePowerPolicyReader.activeSource()
        let policy = DeadlinePostureMonitor.shared.state.powerObservation()
        let matches = source != nil && policy?.source == source
        return Self(thermalState: ProcessInfo.processInfo.thermalState.rawValue,
             lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
             powerSource: source, automaticPower: matches ? policy?.automatic : nil,
             powerPolicyAgeMilliseconds: matches ? policy?.powerReadAgeMilliseconds : nil)
    }
}

struct QualificationPostureObservation: Codable, Sendable {
    let elapsedMilliseconds: Double
    let snapshot: QualificationPostureSnapshot

    static let maximumCount = 2048
    static let maximumGapMilliseconds = 1000.0

    static func continuousAC(_ observations: [Self], dropped: Int,
                             before: QualificationPostureSnapshot,
                             after: QualificationPostureSnapshot) -> Bool {
        guard dropped == 0, observations.count >= 2, observations.count <= maximumCount,
              observations.first?.elapsedMilliseconds == 0,
              observations.first?.snapshot == before, observations.last?.snapshot == after else { return false }
        var previous = 0.0
        for (index, observation) in observations.enumerated() {
            let elapsed = observation.elapsedMilliseconds
            guard elapsed.isFinite, (index == 0 ? elapsed == 0 : elapsed > previous),
                  elapsed - previous <= maximumGapMilliseconds,
                  observation.snapshot.hasMeasuredAutomaticAC else { return false }
            previous = elapsed
        }
        return true
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
    let observations: [QualificationPostureObservation]
    let droppedObservations: Int
    let passed: Bool
}

struct QualificationTrialPostureReceipt: Codable, Sendable {
    let before: QualificationPostureSnapshot
    let after: QualificationPostureSnapshot
    let worstThermalState: Int
    let lowPowerObserved: Bool
    let observations: [QualificationPostureObservation]
    let droppedObservations: Int
    var isNominal: Bool {
        before.isNominal && after.isNominal && worstThermalState == 0 && !lowPowerObserved
            && QualificationPostureObservation.continuousAC(observations, dropped: droppedObservations,
                                                           before: before, after: after)
            && observations.allSatisfy { $0.snapshot.isNominal }
    }
}

enum QualificationPostureFailure: Error { case recoveryTimedOut, nonNominalMeasurement }
