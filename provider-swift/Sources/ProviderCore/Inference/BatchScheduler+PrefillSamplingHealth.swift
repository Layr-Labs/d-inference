// Copyright © 2026 Eigen Labs.
//
// Prefill-EWMA sampling health — MEASUREMENT ONLY.
//
// This file holds only the OBSERVABILITY side of cold-prefill sampling: the
// cumulative accept/drop counters (`PrefillSamplingHealth`, surfaced on the
// `engine_health` telemetry path) and `classifyPrefillSample` — the pure,
// unit-testable classifier that `recordFinish` routes each candidate sample
// through. The classifier encodes the EXACT same floor/ceiling/finite/cold
// conditions as `recordFinish` and the accept path (`updatePrefillTpsEwma` on
// `.accepted`) is byte-for-byte unchanged, so extracting it changes no behavior;
// the counters just turn a previously silent drop into a dashboard line.
//
// The prefill-measurement MECHANISM itself — why the engine emits a token-less
// prefill-start marker at admit, how admittedAt/firstTokenAt bound the cold-prefill
// window, and the `minPrefillWindowSeconds` / `maxPlausiblePrefillTps` bounds and
// their rationale — is documented canonically in BatchScheduler+EngineBridge.swift
// (the "Prefill-EWMA sampling bounds" section and `recordFinish`), not repeated here.

import Foundation

/// Cumulative prefill-sampling health for the loaded model's slot. Pure data;
/// read on the `engine_health` telemetry path. NO prompt/response content.
struct PrefillSamplingHealth: Equatable {
    /// Cold prefill samples that passed the floor + ceiling and updated the EWMA.
    var accepted: Int = 0
    /// Dropped because the admission→first-token window was below the 1 ms floor
    /// (cache hit / near-instant first token — the dominant drop reason).
    var droppedFloor: Int = 0
    /// Dropped because the derived rate was non-finite or above the plausibility
    /// ceiling (`maxPlausiblePrefillTps`).
    var droppedCeiling: Int = 0
    /// The most recent raw sample rate (tok/s) regardless of accept/drop — a
    /// huge value here next to `droppedFloor` climbing is the window-collapse
    /// signature.
    var lastSampleTps: Double = 0
}

/// Outcome of the (unchanged) prefill-sample bounds check. `.accepted` carries
/// the tok/s the EWMA would consume — exactly the value `recordFinish` computed.
enum PrefillSampleClass: Equatable {
    case accepted(tps: Double)
    case belowFloor
    case aboveCeiling
    case notColdPrefill
}

extension BatchScheduler {
    /// Pure classification of a prefill sample against the SAME bounds
    /// `recordFinish` enforces (`minPrefillWindowSeconds` floor,
    /// `maxPlausiblePrefillTps` + finiteness ceiling, positive prefilled tokens).
    /// Behavior-preserving: `.accepted` fires iff the original `if` did.
    static func classifyPrefillSample(
        prefilledTokens: Int, prefillSeconds: Double
    ) -> PrefillSampleClass {
        guard prefilledTokens > 0 else { return .notColdPrefill }
        guard prefillSeconds >= minPrefillWindowSeconds else { return .belowFloor }
        let tps = Double(prefilledTokens) / prefillSeconds
        guard tps.isFinite, tps <= maxPlausiblePrefillTps else { return .aboveCeiling }
        return .accepted(tps: tps)
    }

    /// Best-effort raw rate for diagnostics (`last_prefill_sample_tps`), computed
    /// for any class where the window is positive — including the below-floor
    /// case, whose near-zero denominator yields the inflated rate that reveals the
    /// collapse. Returns nil when no rate is computable.
    static func rawPrefillSampleTps(prefilledTokens: Int, prefillSeconds: Double) -> Double? {
        guard prefilledTokens > 0, prefillSeconds > 0 else { return nil }
        let tps = Double(prefilledTokens) / prefillSeconds
        return tps.isFinite ? tps : nil
    }
}
