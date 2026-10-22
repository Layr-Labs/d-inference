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

    /// The measured decode-step shape that selects per-batch decode charging,
    /// or nil for the per-row charge. A reviewed calibration's error envelope,
    /// and the qualification evidence proving that envelope was used, assume
    /// the per-row conversion is its only fallback, so calibrated policies
    /// keep it.
    static func decodeRateShape(
        _ measured: CBv2DecodeRateShape, enabled: Bool, calibrated: Bool
    ) -> CBv2DecodeRateShape? {
        enabled && !calibrated ? measured : nil
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
