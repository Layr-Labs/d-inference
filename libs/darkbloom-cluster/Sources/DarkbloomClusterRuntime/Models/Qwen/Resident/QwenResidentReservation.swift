import Foundation

/// The admitted request and its named resource charges. Both reservation and
/// execution use the same live-memory check; native ownership stays in the runtime.
struct QwenResidentReservation {
    let request: QwenLayerStageGenerationRequest
    let allowance: QwenResidentRequestAllowance
    let deadline: UInt64
    let mode: QwenResidentRequestMode
    let recordingCharge: QwenResidentRecordingCharge?
    let prefillPolicy: QwenResidentPrefillPolicy
    let prefillAllowance: QwenGenerationPrefillAllowance?

    /// The live check of this admitted request while it runs, with `grown`
    /// bytes already allocated since it started (`requireContinuing`).
    func requireContinuing(grown: Int, additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0) throws {
        try allowance.requireContinuing(grownBytes: grown,
            additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([additionalNativeBytes,
                prefillAllowance?.extraNativeBytes ?? 0, recordingCharge?.capture.extraNativeBytes ?? 0]),
            additionalHostBytes: QwenLongPrefillCheckedBytes.sum([additionalHostBytes,
                prefillAllowance?.extraHostBytes ?? 0, recordingCharge?.capture.extraHostBytes ?? 0]))
    }

    func requireLive() throws {
        if let prefillAllowance {
            try allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([
                prefillAllowance.extraNativeBytes, recordingCharge?.capture.extraNativeBytes ?? 0]),
                additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
                    prefillAllowance.extraHostBytes, recordingCharge?.capture.extraHostBytes ?? 0]))
        } else { try allowance.requireLive() }
    }
}
