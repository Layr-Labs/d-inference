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
        isOn(environmentKey, environment: environment)
    }

    /// Unset, or any value but `0`, `false`, `no` or `off` (trimmed,
    /// case-insensitive), is on.
    static func isOn(_ key: String, environment: [String: String]) -> Bool {
        guard let raw = environment[key]?
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

/// Admission's view of the isolated cold-prefill rate of a GLM-5.3-Flash or
/// native MiMo V2.6 bridge (`EngineV2Bridge.nativePrefillEvidenceApplies`).
/// Those engines have neither the anchor bound above nor the refusal streak:
/// before their first calibration cell, their own recovery admits only
/// prompts of up to 1,024 tokens once their evidence expires.
///
/// A short cold prompt measures mostly the request's fixed cost: on idle GLM
/// M5 Ultras a 13-20-token prompt measured 9-140 tok/s, against 1,378-2,031
/// tok/s for prompts above 4K tokens. One such sample set the estimate, every
/// longer prompt was refused, and a refusal measures nothing. So a cold sample
/// from a prompt of at most `sampleTokensAbove` tokens may raise the estimate
/// (a short prompt's rate bounds a longer prompt's from below) but never lower
/// it; calibration cells and longer prompts move it either way and alone date
/// the evidence and, once the Mac has a calibration cell, restart the estimate
/// after a gap (`countsAsRateSample`). A
/// slower short sample stays in its prompt-size bucket only, out of the
/// published isolated and observed prefill rates that routing reads. The
/// smallest bucket never tightens a prompt (`bucketTightens`); larger buckets
/// still do.
///
/// On an idle Mac at nominal posture, counted evidence older than the
/// 120-second freshness window is priced at no less than the calibration
/// anchor, which was measured under those conditions; fresh counted evidence
/// keeps the ordinary engines' floor of one eighth of the anchor, as does a
/// busy Mac or another posture. Unlike `IsolatedPrefillAdmissionRate`, old
/// evidence never skips the projection: a native step cannot be preempted, so
/// a large prompt stays projected. With an anchor, the projection replaces the
/// short-prompt recovery. On by default;
/// `DARKBLOOM_TTFT_NATIVE_PREFILL_EVIDENCE=0` restores the previous estimator,
/// as does `DARKBLOOM_TTFT_ADMISSION_FIXES=0`.
enum NativePrefillEvidence {
    static let environmentKey = "DARKBLOOM_TTFT_NATIVE_PREFILL_EVIDENCE"
    static let enabled = resolve()
    /// The 4,096-token prompt-size bucket's ceiling
    /// (`EnginePerformanceMeasurements.bucket`).
    static let sampleTokensAbove = 4_096

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        DeadlineAdmissionFixes.isOn(environmentKey, environment: environment)
    }

    static func countsAsRateSample(promptTokens: Int) -> Bool {
        promptTokens > sampleTokensAbove
    }

    /// The smallest prompt-size bucket (up to 1,024 tokens) mixes a few-token
    /// prompt's fixed cost with real prefill, so it never tightens a native
    /// prompt; larger buckets hold prompts of comparable size and still do.
    static func bucketTightens(promptTokens: Int) -> Bool {
        EnginePerformanceMeasurements.bucket(promptTokens) > 1_024
    }

    static func resolve(
        observed: Double?, anchor: Double?, evidenceAge: Duration?,
        macIdle: Bool, nominalPosture: Bool
    ) -> Double? {
        let observed = observed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let anchor = anchor.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let anchor, macIdle, nominalPosture,
            evidenceAge.map({ $0 > EnginePerformanceMeasurements.freshness }) ?? true {
            return max(observed ?? anchor, anchor)
        }
        guard let observed else { return nil }
        guard let anchor else { return observed }
        return max(observed, anchor * IsolatedPrefillAdmissionRate.anchorFloorFraction)
    }
}

/// The refusal streak's own off switch. On by default;
/// `DARKBLOOM_TTFT_REFUSAL_PROBE=0` stops its counting and its probe and leaves
/// the estimator corrections (`DeadlineAdmissionFixes`) on.
enum DeadlineRefusalProbe {
    static let environmentKey = "DARKBLOOM_TTFT_REFUSAL_PROBE"
    static let enabled = resolve()

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        DeadlineAdmissionFixes.isOn(environmentKey, environment: environment)
    }
}

/// Consecutive `deadline_unreachable` refusals that stale isolated prefill
/// evidence explains on an idle Mac, with nothing admitted in between. A
/// refusal measures nothing, so expired evidence that refuses is never
/// replaced: with no calibration anchor, or off nominal posture,
/// `IsolatedPrefillAdmissionRate` keeps it for thirty minutes.
///
/// A full streak asks for one idle-calibration probe
/// (`ModelCalibrationPolicy.evidenceRefresh`), never for a customer request
/// submitted unprojected. The probe runs only on an idle Mac at nominal
/// posture, any request preempts it, and its measurement replaces the stale
/// estimate and the anchor. `probeInterval` holds a Mac and model to one
/// probe per interval, whatever the probe goes on to measure.
struct DeadlineRefusalStreak {
    /// One refusal can be one long prompt and two a client's retry of it.
    static let threshold = 3
    static let probeInterval = EnginePerformanceMeasurements.freshness
    /// A request refused with less first-content budget left is a late retry:
    /// out of time on any Mac, so its refusal says nothing about the estimate.
    /// A first attempt has at least 9 s.
    static let minimumRemainingBudget: Duration = .seconds(5)

    private(set) var refusals = 0
    /// The newest counted refusal's rate and prompt, for the log line.
    private(set) var lastRefusal: (tokensPerSecond: Double, promptTokens: Int)?
    /// When the next probe may start; nil before the first.
    private(set) var probeAvailableAt: ContinuousClock.Instant?

    mutating func recordRefusal(tokensPerSecond: Double, promptTokens: Int) {
        refusals = min(refusals + 1, Self.threshold)
        lastRefusal = (tokensPerSecond, promptTokens)
    }

    func permitsEvidenceProbe(at now: ContinuousClock.Instant = .now) -> Bool {
        refusals >= Self.threshold && (probeAvailableAt.map { now >= $0 } ?? true)
    }

    /// Any engine admission ends the streak.
    mutating func recordAdmission() {
        refusals = 0
    }

    /// A started probe ends the streak and starts the interval.
    mutating func recordProbe(at now: ContinuousClock.Instant = .now) {
        refusals = 0
        probeAvailableAt = now.advanced(by: Self.probeInterval)
    }
}
