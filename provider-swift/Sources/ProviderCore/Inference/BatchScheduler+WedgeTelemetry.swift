// Copyright © 2026 Eigen Labs.
//
// First-token-wedge instrumentation for `BatchScheduler` — the provider side of
// the engine-health signals documented in
// docs/reports/2026-06-22-cancel-root-cause-and-fix.md (§C).
//
// Two channels, both MEASUREMENT ONLY (no routing/watchdog action here):
//   1. Heartbeat — `wedgeMonitor`'s counters are folded into the per-slot
//      `BackendSlotCapacity` in `BatchScheduler+Telemetry.backendCapacity()`, so
//      the coordinator can SEE "admits climbing while first-tokens stay flat and
//      the engine step counter flatlines."
//   2. Telemetry events — richer NON-PRIVATE `engine_health` events (model-load
//      milestones, periodic engine snapshots, and wedge-suspected transitions)
//      flow through `TelemetryClient` → coordinator → Datadog as the offline
//      debug trail (the `telemetry_events` DB table is intentionally retired;
//      Datadog Log Explorer is the sink — see coordinator/api/telemetry_handlers.go).
//
// PRIVACY: only operational counters/timestamps are emitted. No prompt/response
// content. The fields used here are mirrored in the Go + Swift + TS allowlists.

import Foundation
import MLX
import MLXLMCommon

extension BatchScheduler {

    /// Coarse cadence (seconds) for the periodic `engine_health` snapshot event.
    /// A wedge-suspected *transition* emits immediately regardless of this; the
    /// cadence only bounds the steady-state trail so it stays cheap fleet-wide.
    static let engineHealthSnapshotIntervalSeconds: Double = 60

    // MARK: - Bridge-lifecycle recording (called from BatchScheduler+EngineBridge)

    /// A request reached the streaming bridge (it will emit the lock-free
    /// preamble). Counted as an "admit" for the wedge monitor. Called once per
    /// request, at bridge start — independent of whether the engine ever emits a
    /// `RequestOutput`, which a wedged first-`eval` never does.
    func recordWedgeAdmit() {
        wedgeMonitor.recordAdmit(now: .now)
    }

    /// The request produced its first content token. Clears the wedge monitor's
    /// dry streak. Called once per request from the bridge's first-token path.
    func recordWedgeFirstToken() {
        wedgeMonitor.recordFirstToken(now: .now)
    }

    // MARK: - Engine-step sampling

    /// Sample the live engine step counter into the wedge monitor. Idempotent;
    /// called from both the heartbeat (`backendCapacity()`) and the liveness tick.
    func sampleEngineSteps(now: ContinuousClock.Instant = .now) {
        wedgeMonitor.sampleSteps(engine?.core.stepsExecuted ?? 0, now: now)
    }

    // MARK: - Telemetry: engine-health snapshot + wedge transitions

    /// Assess engine health and emit an `engine_health` telemetry event when a
    /// wedge-suspected transition occurs (immediately) or the periodic snapshot
    /// cadence has elapsed (steady-state trail). No-op when no model is loaded or
    /// the slot has never served (keeps idle boxes quiet fleet-wide). Called from
    /// the liveness watchdog tick — off the inference hot path.
    func emitEngineHealthTelemetry(now: ContinuousClock.Instant = .now) {
        guard engine != nil else { return }
        sampleEngineSteps(now: now)

        let suspected = wedgeMonitor.wedgeSuspected(now: now)
        let transition = suspected != lastWedgeSuspectedEmitted
        let due: Bool = {
            guard let last = lastEngineHealthEmitAt else { return true }
            return WedgeMonitor.seconds(now - last) >= Self.engineHealthSnapshotIntervalSeconds
        }()

        // Only the slot that has actually served (or is serving) is interesting:
        // a wedge requires admits, and the periodic trail for never-used idle
        // slots would be pure noise across a large fleet.
        let hasActivity = wedgeMonitor.admits > 0 || !activeBridges.isEmpty
        guard transition || (due && hasActivity) else { return }

        lastWedgeSuspectedEmitted = suspected
        lastEngineHealthEmitAt = now

        let severity: TelemetrySeverity = suspected ? .warn : .info
        let operation = transition
            ? (suspected ? "first_token_stall" : "first_token_recovered")
            : "engine_snapshot"
        let message = suspected
            ? "engine_health: first-token wedge suspected"
            : "engine_health: \(operation)"
        TelemetryClient.shared.emit(
            kind: .engineHealth,
            severity: severity,
            message: message,
            fields: engineHealthFields(operation: operation, now: now)
        )
    }

    /// Emit a model-load milestone (`engine_health`) so the offline trail records
    /// load start/complete and cold-start timing. `durationMs == nil` for the
    /// start event.
    func emitModelLoadMilestone(operation: String, model: String, durationMs: Int64? = nil) {
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string(operation),
            "model": .string(model),
        ]
        if let durationMs { fields["duration_ms"] = .int64(durationMs) }
        TelemetryClient.shared.emit(
            kind: .engineHealth,
            severity: .info,
            message: "engine_health: \(operation)",
            fields: fields
        )
    }

    /// Build the NON-PRIVATE field set for an engine-health event. Keys are
    /// mirrored in the Go/Swift/TS telemetry allowlists.
    private func engineHealthFields(
        operation: String, now: ContinuousClock.Instant
    ) -> [String: AnyCodableValue] {
        [
            "component": .string("engine"),
            "operation": .string(operation),
            "model": .string(modelId),
            "steps_executed": .int(wedgeMonitor.lastStepsSample),
            "admits": .int(wedgeMonitor.admits),
            "first_tokens_emitted": .int(wedgeMonitor.firstTokens),
            "consecutive_admits_without_first_token":
                .int(wedgeMonitor.consecutiveAdmitsWithoutFirstToken),
            "seconds_since_last_step": .double(wedgeMonitor.secondsSinceLastStep(now: now)),
            "seconds_since_last_first_token":
                .double(wedgeMonitor.secondsSinceLastFirstToken(now: now)),
            "num_running": .int(activeBridges.count),
            "wedge_suspected": .bool(wedgeMonitor.wedgeSuspected(now: now)),
            // Eval-in-flight (process-global blocking eval under evalLock).
            "eval_in_flight_ms": .int64(MLX.EvalProbe.currentEvalElapsedMs),
            "longest_eval_ms": .int64(MLX.EvalProbe.longestEvalMs),
            "evals_completed": .int(MLX.EvalProbe.evalsCompleted),
            // Idle GPU drain + buffer-cache clear (per-slot engine).
            "idle_clear_in_flight_ms": .int64(engine?.core.idleClearElapsedMs ?? 0),
            "idle_clears_completed": .int(engine?.core.idleClearsCompleted ?? 0),
            // Prefill-EWMA sampling health (why observed_prefill_tps stays 0).
            "prefill_samples_accepted": .int(prefillHealth.accepted),
            "prefill_samples_dropped_floor": .int(prefillHealth.droppedFloor),
            "prefill_samples_dropped_ceiling": .int(prefillHealth.droppedCeiling),
            "last_prefill_sample_tps": .double(prefillHealth.lastSampleTps),
            "observed_prefill_tps_ewma": .double(observedPrefillTpsEwma),
        ]
    }
}
