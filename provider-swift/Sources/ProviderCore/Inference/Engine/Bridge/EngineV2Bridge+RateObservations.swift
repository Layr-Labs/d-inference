import Foundation
import MLXLMCommon

/// Numeric phase evidence only. Calibration holds it until the whole cell
/// retires and passes its final posture check; serving applies it immediately.
struct EngineRateObservation: Sendable {
    let phase: String
    let tps: Double
    let prompt: Int
    let context: Int
    let cache: String
    let overlap: EngineMeasurementActivity.Overlap
    let at: ContinuousClock.Instant
    let postureEpoch: UUID?
    let aggregate: Bool
    /// Decode only: the decode-step shape the request was measured at.
    var decodeShape = CBv2DecodeRateShape(batchRows: 1)
}

extension EngineV2Bridge {
    func recordRateObservation(_ observation: EngineRateObservation, requestID: String) {
        if modelCalibration.requests[requestID] != nil {
            modelCalibration.pendingObservations[requestID, default: []].append(observation)
        } else {
            applyRateObservation(observation, requestID: requestID, calibration: false)
        }
    }

    func applyRateObservation(_ value: EngineRateObservation, requestID: String, calibration: Bool) {
        let isDecode = value.phase == "decode"
        let resetIsolated = !isDecode && value.phase == "isolated_prefill"
            && isolatedPrefillEvidenceExpired(at: value.at)
        // A late completed sample older than the newest evidence is not an
        // evidence gap and must not restart the combined estimate.
        let resetPrefill = !isDecode && value.cache == "cold"
            && (admissionFixes
                ? !performanceMeasurements.coversObservation("isolated_prefill", at: value.at)
                    && !performanceMeasurements.coversObservation("contended_prefill", at: value.at)
                : performanceMeasurements.freshRate("isolated_prefill", now: value.at) == nil
                    && performanceMeasurements.freshRate("contended_prefill", now: value.at) == nil)
        if isDecode && value.aggregate {
            if calibration || performanceMeasurements.rateExpiration("decode").map({ value.at > $0 }) == true {
                ewmaInitialized = false
            }
            updateDecodeTpsEwma(value.tps, shape: value.decodeShape)
        }
        performanceMeasurements.observe(value.phase, tps: value.tps, prompt: value.prompt,
            context: value.context, cache: value.cache, overlap: value.overlap, at: value.at,
            deadlinePostureEpoch: value.postureEpoch, recordAggregate: value.aggregate,
            restartEstimate: calibration && value.aggregate)
        guard !isDecode, value.aggregate, value.cache == "cold" else { return }
        if resetIsolated || calibration { isolatedPrefillEwmaInitialized = false }
        if resetPrefill || calibration { prefillEwmaInitialized = false }
        updatePrefillTpsEwma(value.tps, isolated: !value.overlap.contended)
        if calibration, value.phase == "isolated_prefill" { calibratedIsolatedPrefillTps = value.tps }
        if value.phase == "isolated_prefill" { prefillEvidenceRecovery.observe(requestID) }
    }
}
