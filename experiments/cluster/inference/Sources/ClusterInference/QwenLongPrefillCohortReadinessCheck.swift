import Foundation
import MLX

struct QwenLongPrefillCohortReadinessCheckReport: Encodable {
    let kind = "qwen_long_prefill_cohort_readiness_check", schemaVersion = 1
    let epoch: String
    let fixtureCase: QwenLongPrefillCohortReadinessCase
    let rank: Int
    let worldSize = 2, transport = "loopback-test"
    let cohortAgreement: QwenLongPrefillResidentCohortAgreement.Descriptor
    let cohortReadiness: QwenLongPrefillResidentCohortReadiness
    let postAgreementMarker = "reached_without_model_load"
    let readinessExchangePassed = true
    let modelConstructed = false, weightsMaterialized = false, requestsExecuted = false
    let modelPayloadRead = false, requestStateCreated = false
    let arithmeticEnvironmentIsFixture = true
    let actualArtifactVerificationPerformed = false, actualOSResourceAdmissionPerformed = false
    let residentReuseQualified = false, physicalTransferQualified = false
    let throughputMeasurementValid = false
}

/// The only native path is the existing fixed-shape readiness exchange. A
/// failure returns directly to Main/parent retirement without a blocking fence.
func runQwenLongPrefillCohortReadinessCheck(_ admission: QwenLongPrefillCohortReadinessAdmission,
    check: () throws -> Void
) throws -> QwenLongPrefillCohortReadinessCheckReport {
    let collective = try Collective(transport: .loopbackTest)
    return try MLX.withError { error in
        func checked() throws { try error.check(); try check(); try error.check() }
        // Select only from the admitted native group, never an environment rank.
        let agreement = try admission.agreement(forRank: collective.rank)
        let readiness = try requireQwenLongPrefillResidentCohortReadiness(
            agreement, collective: collective, check: checked)
        try checked()
        let report = QwenLongPrefillCohortReadinessCheckReport(epoch: admission.epoch,
            fixtureCase: admission.fixtureCase, rank: collective.rank,
            cohortAgreement: agreement.descriptor, cohortReadiness: readiness)
        guard try canonicalJSONData(report).count < 65_536 else {
            throw ProbeError("Cohort readiness success record exceeds its 64 KiB line bound")
        }
        return report
    }
}
