import Foundation

struct QwenLongPrefillResidentCohortReadiness: Encodable {
    let cohortAgreementFingerprint: String
    let readinessMaterialSHA256: String
}

/// Intent agreement only, before model loading. A successful exchange does not
/// assert verified payload storage, available resources or a completed cohort.
func requireQwenLongPrefillResidentCohortReadiness(_ agreement: QwenLongPrefillResidentCohortAgreement,
    collective: Collective, check: () throws -> Void
) throws -> QwenLongPrefillResidentCohortReadiness {
    let digest = try requireQwenLongPrefillReadinessDigest(collective: collective,
        material: { .residentCohort(agreementFingerprint: agreement.fingerprint) },
        disagreementMessage: "Resident ranks disagree on ordered requests, warmups, source or policy before stage load",
        check: check)
    return .init(cohortAgreementFingerprint: agreement.fingerprint, readinessMaterialSHA256: digest)
}
