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

    func requireLive() throws {
        if let prefillAllowance {
            try allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([
                prefillAllowance.extraNativeBytes, recordingCharge?.capture.extraNativeBytes ?? 0]),
                additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
                    prefillAllowance.extraHostBytes, recordingCharge?.capture.extraHostBytes ?? 0]))
        } else { try allowance.requireLive() }
    }
}
