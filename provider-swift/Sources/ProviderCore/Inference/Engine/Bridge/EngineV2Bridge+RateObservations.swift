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
        let native = nativePrefillEvidenceApplies
        // A short prompt's rate bounds a longer prompt's from below: it may
        // raise a native engine's estimate, never lower it.
        let shortNativeSample = native && !calibration && value.phase == "isolated_prefill"
            && !NativePrefillEvidence.countsAsRateSample(promptTokens: value.prompt)
            && isolatedPrefillEwmaInitialized && value.tps <= isolatedPrefillTpsEwma
        // Only a calibration cell or a long prompt dates a native estimate and,
        // once the Mac has a calibration cell, restarts it after a gap; a faster
        // short sample blends in, so it can only raise the estimate. Before the
        // first cell, restarts follow the published measurement's own clock.
        let countedNativeSample = calibration || NativePrefillEvidence.countsAsRateSample(promptTokens: value.prompt)
        let nativeClock = native && calibratedIsolatedPrefillTps != nil
        let resetIsolated = !isDecode && value.phase == "isolated_prefill" && !shortNativeSample
            && (nativeClock ? countedNativeSample && nativeRateEvidenceExpired(at: value.at)
                : isolatedPrefillEvidenceExpired(at: value.at))
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
        // The prompt-size bucket keeps a slower short sample; the published
        // isolated rate, which routing prices this Mac from, leaves it out and
        // restarts whenever the native estimate does.
        performanceMeasurements.observe(value.phase, tps: value.tps, prompt: value.prompt,
            context: value.context, cache: value.cache, overlap: value.overlap, at: value.at,
            deadlinePostureEpoch: value.postureEpoch, recordAggregate: value.aggregate && !shortNativeSample,
            restartEstimate: (calibration || (native && resetIsolated)) && value.aggregate)
        guard !isDecode, value.aggregate, value.cache == "cold", !shortNativeSample else { return }
        if resetIsolated || calibration { isolatedPrefillEwmaInitialized = false }
        if resetPrefill || calibration { prefillEwmaInitialized = false }
        updatePrefillTpsEwma(value.tps, isolated: !value.overlap.contended)
        if native, !value.overlap.contended, countedNativeSample {
            nativeRateEvidenceAt = max(nativeRateEvidenceAt ?? value.at, value.at)
        }
        if calibration, value.phase == "isolated_prefill" { calibratedIsolatedPrefillTps = value.tps }
        if value.phase == "isolated_prefill" { prefillEvidenceRecovery.observe(requestID) }
    }
}
