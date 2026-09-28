import Foundation
import MLX

/// Both callers have already independently admitted their verified local stage.
/// This v4-only exchange owns no request state and completes before rank zero's
/// clock. Its distinct domain cannot be satisfied by a v3 readiness message.
func requireQwenLongPrefillRankReadiness(_ agreement: QwenLayerStageProfiledPrefillStartAgreement,
    collective: Collective, check: () throws -> Void
) throws -> QwenLongPrefillRankReadiness {
    let digest = try requireQwenLongPrefillReadinessDigest(collective: collective,
        material: { .request(agreementFingerprint: agreement.fingerprint) },
        disagreementMessage: "Long ranks disagree on admitted source, input, arithmetic or scheduling before clock start",
        check: check)
    return .init(agreementFingerprint: agreement.fingerprint, readinessMaterialSHA256: digest)
}
