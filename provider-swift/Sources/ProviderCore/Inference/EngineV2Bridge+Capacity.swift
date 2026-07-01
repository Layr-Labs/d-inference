// Copyright © 2026 Eigen Labs.
//
// Heartbeat capacity + engine-health signals for the v2 bridge:
//
//   * `backendSlotCapacity()` maps the engine's `CBv2CapacitySnapshot`
//     into the EXISTING `BackendSlotCapacity` protocol fields — no wire
//     changes, coordinator compatibility preserved. Numbers become
//     truthful: `active_tokens` is the engine's real KV-resident token
//     count and the budget fields are BYTES-derived
//     (`kvBytesInUse / kvBytesPerToken`), not worst-case reservations.
//
//   * `engine_v2.step_wedge`: the same `WedgeMonitor` primitive the legacy
//     engine uses (admits vs first tokens vs loop progress), fed from
//     bridge-observable signals, emitted through the existing
//     `engine_health` telemetry plumbing with `backend=engine_v2` on a
//     wedge-suspected TRANSITION edge (both directions).

import Foundation
import MLXLMCommon

extension EngineV2Bridge {

    /// One heartbeat slot for this bridge's model, shaped exactly like the
    /// legacy scheduler's slot (same protocol fields, same state strings)
    /// so the coordinator's admission/routing math is engine-agnostic.
    public func backendSlotCapacity(
        now: ContinuousClock.Instant = .now
    ) -> BackendSlotCapacity {
        let snapshot = engineBox.capacity()

        // Sample loop progress into the wedge monitor on the heartbeat
        // cadence (mirrors `sampleEngineSteps`), then emit the step_wedge
        // transition signal if the verdict flipped.
        wedgeMonitor.sampleSteps(eventsObserved, now: now)
        emitStepWedgeTransitionIfNeeded(now: now)

        // Worst-case potential is bridge bookkeeping (the snapshot has no
        // per-request max-token view); active tokens are engine truth.
        var maxTokensPotential: Int64 = 0
        for state in active.values {
            maxTokensPotential += Int64(state.promptTokens + state.maxTokens)
        }

        // Truthful bytes-derived token budget. When the per-token KV cost
        // is unknown (0), fall back to the engine's token counts rather
        // than inventing a budget.
        let budgetUsed: Int64
        let budgetMax: Int64
        if kvBytesPerToken > 0 {
            budgetUsed = Int64(snapshot.kvBytesInUse / kvBytesPerToken)
            budgetMax = Int64(snapshot.kvBytesCapacity / kvBytesPerToken)
        } else {
            budgetUsed = Int64(snapshot.activeTokens)
            budgetMax = 0
        }

        let state: String
        if wedgeMonitor.wedgeSuspected(now: now) {
            // Same truthful-derouting contract as the legacy heartbeat: a
            // wedged slot must not keep advertising healthy.
            state = "crashed"
        } else {
            state = snapshot.activeRequests > 0 ? "running" : "idle"
        }

        return BackendSlotCapacity(
            model: modelId,
            state: state,
            numRunning: UInt32(clamping: max(0, snapshot.activeRequests)),
            numWaiting: UInt32(clamping: max(0, snapshot.waitingRequests)),
            activeTokens: Int64(snapshot.activeTokens),
            maxTokensPotential: maxTokensPotential,
            maxConcurrency: UInt32(clamping: maxConcurrentRequests),
            observedDecodeTps: observedDecodeTpsEwma,
            observedPrefillTps: 0,
            activeTokenBudgetUsed: budgetUsed,
            activeTokenBudgetMax: budgetMax,
            queuedTokenBudget: 0,
            kvBytesPerToken: Int64(kvBytesPerToken),
            modelLoadTimeMs: 0,
            stepsExecuted: Int64(wedgeMonitor.lastStepsSample),
            admits: Int64(wedgeMonitor.admits),
            firstTokensEmitted: Int64(wedgeMonitor.firstTokens),
            secondsSinceLastStep: wedgeMonitor.secondsSinceLastStep(now: now),
            secondsSinceLastFirstToken: wedgeMonitor.secondsSinceLastFirstToken(now: now),
            wedgeSuspected: wedgeMonitor.wedgeSuspected(now: now)
        )
    }

    /// Number of requests currently active on this bridge (heartbeat
    /// aggregate `inferenceActive` input).
    public func activeRequestCount() -> Int {
        active.count
    }

    // MARK: - engine_v2.step_wedge

    /// Emit an `engine_health` telemetry event on a wedge-suspected
    /// transition (both edges), tagged `backend=engine_v2` with
    /// `operation=step_wedge` / `step_wedge_recovered`. Runs on the
    /// heartbeat path — off the inference hot path — and only on edges so
    /// it stays cheap fleet-wide.
    func emitStepWedgeTransitionIfNeeded(now: ContinuousClock.Instant) {
        let suspected = wedgeMonitor.wedgeSuspected(now: now)
        guard suspected != lastWedgeSuspectedEmitted else { return }
        lastWedgeSuspectedEmitted = suspected

        let operation = suspected ? "step_wedge" : "step_wedge_recovered"
        let event = TelemetryEvent(
            source: .provider,
            severity: suspected ? .warn : .info,
            kind: .engineHealth,
            message: suspected
                ? "engine_v2: step wedge suspected"
                : "engine_v2: step wedge recovered"
        ).withFields([
            "component": .string("engine"),
            "operation": .string(operation),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "steps_executed": .int(wedgeMonitor.lastStepsSample),
            "admits": .int(wedgeMonitor.admits),
            "first_tokens_emitted": .int(wedgeMonitor.firstTokens),
            "consecutive_admits_without_first_token":
                .int(wedgeMonitor.consecutiveAdmitsWithoutFirstToken),
            "seconds_since_last_step": .double(wedgeMonitor.secondsSinceLastStep(now: now)),
            "seconds_since_last_first_token":
                .double(wedgeMonitor.secondsSinceLastFirstToken(now: now)),
            "num_running": .int(active.count),
            "wedge_suspected": .bool(suspected),
        ])
        emit(event)
    }
}
