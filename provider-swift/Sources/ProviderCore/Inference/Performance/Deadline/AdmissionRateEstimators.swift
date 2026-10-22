import Foundation
import MLXLMCommon

/// Corrections to the observed-rate inputs of first-token deadline admission:
/// newest-observation freshness, self-healing isolated prefill evidence and
/// per-batch decode charging. On by default; `DARKBLOOM_TTFT_ADMISSION_FIXES=0`
/// restores the previous estimators.
enum DeadlineAdmissionFixes {
    static let environmentKey = "DARKBLOOM_TTFT_ADMISSION_FIXES"
    static let enabled = resolve()

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return true }
        return !["0", "false", "no", "off"].contains(raw)
    }

    /// The decode rate and step shape handed to the engine. Per-batch charging
    /// prices one smoothed measured step; the per-row charge (nil shape) keeps
    /// the per-request EWMA. A reviewed calibration's error envelope, and the
    /// qualification evidence proving that envelope was used, assume the
    /// per-row conversion is its only fallback, so calibrated policies keep it.
    /// The step is smoothed and reset with the per-request EWMA, which alone
    /// says whether decode evidence exists.
    static func decodeCharge(
        perRequestRate: Double?, measuredStep: MeasuredDecodeStep, enabled: Bool, calibrated: Bool
    ) -> (rate: Double?, shape: CBv2DecodeRateShape?) {
        guard enabled, !calibrated else { return (perRequestRate, nil) }
        return (perRequestRate == nil ? nil : measuredStep.tokensPerSecond, measuredStep.shape)
    }
}

/// The decode step behind per-batch charging. Each completed request
/// contributes its mean step duration (`tokensPerStep / rate`) and the shape it
/// was measured at, smoothed with one weight, so admission prices an average of
/// measured steps: the step time and the time per row stay inside the measured
/// range. Smoothing the per-request rate and the rows separately pairs one
/// batch width's rate with another's rows: 10 tok/s at eight rows, then
/// 100 tok/s solo, would price an eight-row step at 0.037 s, not 0.1 s.
struct MeasuredDecodeStep {
    private(set) var shape = CBv2DecodeRateShape(batchRows: 1)
    /// Mean measured step duration; zero before any observation.
    private(set) var seconds: Double = 0

    /// `restart` discards earlier steps, as the decode EWMA does after a reset.
    /// An invalid shape counts as one plain row.
    mutating func observe(tokensPerSecond tps: Double, shape: CBv2DecodeRateShape,
        weight: Double, restart: Bool) {
        guard tps.isFinite, tps > 0 else { return }
        let shape = shape.isValid ? shape : CBv2DecodeRateShape(batchRows: 1)
        let stepSeconds = shape.tokensPerStep / tps
        guard !restart, seconds > 0 else {
            self.shape = shape
            seconds = stepSeconds
            return
        }
        func blend(_ new: Double, _ old: Double) -> Double { weight * new + (1 - weight) * old }
        seconds = blend(stepSeconds, seconds)
        self.shape = CBv2DecodeRateShape(
            batchRows: blend(shape.batchRows, self.shape.batchRows),
            tokensPerStep: blend(shape.tokensPerStep, self.shape.tokensPerStep),
            stepWidth: blend(shape.stepWidth, self.shape.stepWidth))
    }

    /// The per-request rate at which one measured step of `shape` takes
    /// `seconds`; nil before any observation.
    var tokensPerSecond: Double? {
        let rate = shape.tokensPerStep / seconds
        return seconds > 0 && rate.isFinite && rate > 0 ? rate : nil
    }
}

/// Admission's view of the aggregate isolated cold-prefill rate for an
/// ordinary engine (native engines own their bounded recovery probe instead).
///
/// Isolation is judged inside this provider only, so another process's GPU
/// work can record a contended prefill as isolated, and after an evidence gap
/// one such sample replaces the estimate. Nothing refused can refresh it.
/// Startup calibration measures the rate idle at nominal posture; that anchor
/// bounds how far one sample can push the aggregate and replaces evidence that
/// expired while the Mac sat idle. The caller still tightens the result with a
/// fresh prompt-size bucket: the anchor's short cell never certifies long work,
/// and bucket evidence expires on its own. The published rate is unchanged.
enum IsolatedPrefillAdmissionRate {
    /// Low Power Mode roughly halves prefill and the measured first-request
    /// penalty is about 2.3x. A sample eight times below the idle anchor is
    /// far outside both, so the aggregate is never priced below this fraction of it.
    static let anchorFloorFraction = 0.125
    /// Evidence this old on an idle Mac is treated like none, anchored or
    /// not: projection is skipped and absolute expiry still applies, exactly
    /// as after a restart. A calibration cell can run under another process's
    /// GPU load too, so only recent work can keep an idle Mac refusing.
    /// Matches the coordinator's idle decode expiry.
    static let staleEvidenceExpiry: Duration = .seconds(30 * 60)

    /// `macIdle`: no other request on any resident model and no load, encoder
    /// preparation or cache transfer holds the Mac.
    static func resolve(
        observed: Double?, anchor: Double?, evidenceAge: Duration?,
        macIdle: Bool, nominalPosture: Bool
    ) -> Double? {
        let observed = observed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let anchor = anchor.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if macIdle, let evidenceAge, evidenceAge > staleEvidenceExpiry { return nil }
        if let anchor, macIdle, nominalPosture, let evidenceAge,
            evidenceAge > EnginePerformanceMeasurements.freshness {
            // Expired evidence on an idle Mac is not evidence of current
            // slowness; the next admitted request measures afresh.
            return max(observed ?? anchor, anchor)
        }
        guard let observed else { return nil }
        guard let anchor else { return observed }
        return max(observed, anchor * anchorFloorFraction)
    }
}
