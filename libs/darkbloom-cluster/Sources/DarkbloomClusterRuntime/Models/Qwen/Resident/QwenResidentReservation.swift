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
    /// Most bytes this request's prompt-prefix capture may hold
    /// (`QwenStagePrefixCache.captureLimit`), charged as named native storage;
    /// zero when the cache is off or the capture did not fit.
    var prefixCaptureBytes = 0

    /// The live check of this admitted request while it runs, with `grown`
    /// bytes already allocated since it started (`requireContinuing`).
    func requireContinuing(grown: Int, additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0) throws {
        try allowance.requireContinuing(grownBytes: grown,
            additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([additionalNativeBytes, prefixCaptureBytes,
                prefillAllowance?.extraNativeBytes ?? 0, recordingCharge?.capture.extraNativeBytes ?? 0]),
            additionalHostBytes: QwenLongPrefillCheckedBytes.sum([additionalHostBytes,
                prefillAllowance?.extraHostBytes ?? 0, recordingCharge?.capture.extraHostBytes ?? 0]))
    }

    /// A reservation runs on a loaded stage: it asks for its own needs plus headroom (`requireLive(onLoadedStage:)`).
    func requireLive() throws {
        if let prefillAllowance {
            try allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([
                prefillAllowance.extraNativeBytes, recordingCharge?.capture.extraNativeBytes ?? 0, prefixCaptureBytes]),
                additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
                    prefillAllowance.extraHostBytes, recordingCharge?.capture.extraHostBytes ?? 0]), onLoadedStage: true)
        } else if prefixCaptureBytes > 0 {
            try allowance.requireLive(additionalNativeBytes: prefixCaptureBytes, additionalHostBytes: 0, onLoadedStage: true)
        } else { try allowance.requireLive(onLoadedStage: true) }
    }
}
