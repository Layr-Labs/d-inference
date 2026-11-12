// Copyright © 2026 Eigen Labs.
//
// Wedge self-recovery — the v2 bridge's half of the port of the legacy
// `BatchScheduler+Liveness.selfRestartForRecovery` (v0.7.5 §1.10).
//
// The v2 engine already DETECTS wedges (`WedgeMonitor` + the engine's own
// monotonic `stepsExecuted` flatline → heartbeat slot state "crashed" via
// `backendSlotCapacity`) but could not HEAL. Healing is driven by the slot
// owner (`ProviderLoop+EngineV2Liveness` — it holds the container, the
// grant, and the re-slice gate); this file owns the bridge-side pieces:
//
//   * the CONFIRMED-wedge verdict the recovery driver acts on — stricter
//     than the 10s heartbeat *suspicion*: the oldest hanging admit must
//     have produced no first token for the legacy restart threshold
//     (`recoveryStallSeconds`, 120s) AND the
//     engine step counter must have been frozen just as long. The
//     flatline term (which the legacy `.wedged` verdict did not require)
//     keeps a starved-but-alive engine from triggering a full rebuild —
//     the v2 scheduler round-robins, so a stalled request under an
//     advancing step counter is not an engine wedge.
//   * the "reloading" heartbeat window (`recoveryReloading`, the legacy
//     `isReloadingForRecovery` semantic — see `backendSlotCapacity`).
//   * the self-restart telemetry, shaped exactly like the legacy wedge
//     telemetry (`wedgeHealthFields`: operational counters only).
//
// Deliberately NOT ported: the legacy `.pinned` verdict (token-budget
// collapse). Its trigger was the legacy scheduler's live `tokenBudgetMax`
// arithmetic; v2 grants are re-sliced byte ceilings that only move at
// load/unload/recovery, so the collapsing-budget failure mode does not
// exist on this engine.

import Foundation
import MLXLMCommon

/// An engine that reports a sealed native fault: its native work failed, the
/// SDK sealed the native shutdown state `incomplete`, and the engine's step
/// loop never runs again (`EngineV2.nativeCompletionFault`).
protocol SealedNativeFaultReporting {
    var hasSealedNativeFault: Bool { get }
}

extension EngineV2: SealedNativeFaultReporting {
    var hasSealedNativeFault: Bool { nativeCompletionFault != nil }
}

extension EngineV2Bridge {

    /// Stall threshold (seconds) for a CONFIRMED wedge — the legacy engine's
    /// self-restart trigger: no legitimate cold prefill takes this long to
    /// emit its first token.
    static let recoveryStallSeconds: Double = 120

    /// Whether this slot's engine has stopped: its native work failed and the
    /// SDK sealed it (any slot; a sealed engine never steps again), or, on a
    /// native MiMo slot only, its queue has held work with nothing running and
    /// no step for `seconds`. Production shows that same queue on healthy
    /// Gemma, Qwen, Bonsai and Super slots (vision encoding counts as waiting;
    /// a plan with nothing to assign takes no step), and on MiMo only once in
    /// 7 days, when its engine had stopped.
    func engineStopped(queueStalledFor seconds: Double, now: ContinuousClock.Instant) -> Bool {
        if (ownedEngine as? any SealedNativeFaultReporting)?.hasSealedNativeFault == true { return true }
        return nativeTransactionID != nil && wedgeMonitor.queueStallSeconds(now: now) >= seconds
    }

    /// Confirmed-wedge verdict for the recovery driver. True when the
    /// oldest STILL-HANGING admit (admitted, zero first tokens, not
    /// terminated) has stalled ≥ 120s while the engine's step counter has
    /// been frozen ≥ 120s, or when the engine has stopped
    /// (`engineStopped`, its queue term at 120s). Samples the live engine
    /// first so the verdict never depends on heartbeat cadence. Never fires
    /// while a recovery is already in flight for this bridge.
    func confirmedWedgeForRecovery(now: ContinuousClock.Instant = .now) -> Bool {
        guard !recoveryReloading, ownedEngine != nil else { return false }
        let snapshot = capacitySnapshot()
        wedgeMonitor.sampleSteps(snapshot.stepsExecuted, now: now)
        wedgeMonitor.sampleQueue(waiting: snapshot.waitingRequests, running: snapshot.activeRequests,
            steps: snapshot.stepsExecuted, now: now)
        if engineStopped(queueStalledFor: Self.recoveryStallSeconds, now: now) { return true }
        return wedgeMonitor.consecutiveAdmitsWithoutFirstToken >= 1
            && wedgeMonitor.dryStreakSeconds(now: now) >= Self.recoveryStallSeconds
            && wedgeMonitor.secondsSinceLastStep(now: now) >= Self.recoveryStallSeconds
    }

    /// Enter the recovery window: heartbeats report "reloading" from the
    /// next capacity snapshot (legacy `isReloadingForRecovery` semantic).
    /// One-way: a successful recovery discards this bridge entirely, and
    /// every abort path after this point also retires it.
    func beginRecoveryReload() {
        recoveryReloading = true
    }

    /// Emit one self-restart lifecycle event, shaped like the legacy wedge
    /// telemetry (`engine_health`, operational counters only — the same
    /// field set as the step-wedge transitions), with the
    /// recovery-specific `operation` and optional `duration_ms`.
    func emitSelfRestartTelemetry(
        operation: String,
        severity: TelemetrySeverity,
        message: String,
        durationMs: Int64? = nil,
        now: ContinuousClock.Instant = .now
    ) {
        var fields = wedgeHealthFields(operation: operation, now: now)
        if let durationMs {
            fields["duration_ms"] = .int64(durationMs)
        }
        let event = TelemetryEvent(
            source: .provider,
            severity: severity,
            kind: .engineHealth,
            message: message
        ).withFields(fields)
        emit(event)
    }
}
