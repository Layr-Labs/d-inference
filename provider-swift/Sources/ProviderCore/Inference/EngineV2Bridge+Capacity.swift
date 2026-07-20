// Copyright © 2026 Eigen Labs.
//
// Heartbeat capacity + engine-health signals for the v2 bridge:
//
//   * `backendSlotCapacity()` maps the engine's `CBv2CapacitySnapshot`
//     into the EXISTING `BackendSlotCapacity` protocol fields — no wire
//     changes, coordinator compatibility preserved. `active_tokens` is the
//     engine's real KV-resident token count (engine truth); the BUDGET
//     fields carry the same committed/worst-case semantics the legacy
//     scheduler reports, because that is the contract the coordinator's
//     admission gate assumes — see the field-mapping table inside
//     `backendSlotCapacity()`.
//
//   * `engine_v2.step_wedge`: the same `WedgeMonitor` primitive the legacy
//     engine uses (admits vs first tokens vs loop progress), with loop
//     progress sampled from the engine's own monotonic
//     `CBv2CapacitySnapshot.stepsExecuted` counter (published every step —
//     the direct analogue of `EngineCore.stepsExecuted`), emitted through
//     the existing `engine_health` telemetry plumbing with
//     `backend=engine_v2` on a wedge-suspected TRANSITION edge (both
//     directions).

import Foundation
import MLXLMCommon

extension EngineV2Bridge {

    /// One heartbeat slot for this bridge's model, shaped exactly like the
    /// legacy scheduler's slot (same protocol fields, same state strings)
    /// so the coordinator's admission/routing math is engine-agnostic.
    ///
    /// `kvBytesBudgetClamp` (round-3 PR#499 P2): the engine's admission
    /// ceiling is construction-fixed, so when ANOTHER model loads later the
    /// snapshot's `kvBytesCapacity` goes stale against fleet reality. The
    /// heartbeat caller (`EngineV2Runtime.capacitySummary`) recomputes this
    /// bridge's CURRENT byte budget from live fleet residency
    /// (`EngineV2KVSizing.liveEngineKVBytesBudget`) and passes it here; the
    /// REPORTED `activeTokenBudgetMax` is clamped to it so the coordinator
    /// stops routing requests the shared KV gate would reject. nil ⇒ no
    /// clamp (unit tests / callers without fleet context).
    public func backendSlotCapacity(
        now: ContinuousClock.Instant = .now,
        kvBytesBudgetClamp: Int? = nil
    ) -> BackendSlotCapacity {
        let snapshot = capacitySnapshot()

        // Sample loop progress into the wedge monitor on the heartbeat
        // cadence (mirrors `sampleEngineSteps`), then emit the step_wedge
        // transition signal if the verdict flipped. `stepsExecuted` is the
        // engine's own monotonic step counter — a stalled engine stops
        // incrementing it, which is exactly the flatline term
        // `wedgeSuspected` requires.
        wedgeMonitor.sampleSteps(snapshot.stepsExecuted, now: now)
        emitStepWedgeTransitionIfNeeded(now: now)

        // Worst-case potential is bridge bookkeeping (the snapshot has no
        // per-request max-token view); active tokens are engine truth.
        var maxTokensPotential: Int64 = 0
        for state in active.values {
            maxTokensPotential += Int64(state.promptTokens + state.maxTokens)
        }

        // Budget fields — SEMANTICS ALIGNED WITH THE LEGACY SCHEDULER
        // (round-2 PR#499 P2). The coordinator's token-budget admission gate
        // is (coordinator/registry/scheduler.go):
        //
        //     activeTokenBudgetUsed + queuedTokenBudget + requestTokens
        //         <= activeTokenBudgetMax        (only when budgetMax > 0)
        //
        // and it expects `used` to carry the COMMITTED worst-case reservation
        // of every accepted request — the legacy scheduler reports
        // Σ(promptTokens + maxTokens) over active bridges
        // (`BatchScheduler.activeTokenBudgetUsed`). Reporting the engine's
        // MATERIALIZED KV here instead (a long-max_tokens request that has
        // only prefilled a small prefix) leaves the remaining growth of
        // accepted requests unprotected: the gate does not consult
        // `max_tokens_potential`, so the coordinator over-routes until the
        // engine starts rejecting post-acceptance. Field mapping (existing
        // wire fields only — no protocol change):
        //
        //   activeTokens          ← snapshot.activeTokens (ENGINE TRUTH: the
        //                           real KV-resident token count)
        //   maxTokensPotential    ← Σ(prompt + maxTokens)  (worst case)
        //   activeTokenBudgetUsed ← Σ(prompt + maxTokens)  (the committed
        //                           reservation the admission gate must see —
        //                           conservative for sliding-window models,
        //                           whose engine ledger plateaus per layer)
        //   activeTokenBudgetMax  ← min(kvBytesCapacity, live fleet clamp) /
        //                           resolved native rate (the engine's
        //                           admission ceiling
        //                           in tokens, clamped to the sizing
        //                           function's CURRENT answer when the caller
        //                           supplies fleet context — see the doc
        //                           comment above; 0 when the rate is
        //                           unknown ⇒ the coordinator's budget gate
        //                           disengages rather than trusting an
        //                           invented budget)
        //   queuedTokenBudget     ← 0 (engine-WAITING requests are already
        //                           inside the committed sum above — the
        //                           bridge does not split running/waiting)
        let budgetUsed = maxTokensPotential
        // Physical backend truth binds the advertised capacity from below
        // the admission ledger: on the PAGED backend a re-slice GROW moves
        // only the ledger — the construction-fixed pool is what actually
        // places pages, so advertising ledger tokens past pool truth would
        // over-route into the capacity-requeue path. (Contiguous backends
        // resize both ledgers together — the min is a no-op. 0 ⇒ unknown,
        // e.g. an idle point-update snapshot — no bind.)
        var boundedKVBytesCapacity = snapshot.kvBytesCapacity
        if snapshot.kvBytesBackendCapacity > 0 {
            boundedKVBytesCapacity = min(
                boundedKVBytesCapacity, snapshot.kvBytesBackendCapacity)
        }
        let reportedKVBytesCapacity: Int
        if let kvBytesBudgetClamp {
            reportedKVBytesCapacity = min(boundedKVBytesCapacity, max(0, kvBytesBudgetClamp))
        } else {
            reportedKVBytesCapacity = boundedKVBytesCapacity
        }
        let budgetMax: Int64 =
            kvBytesPerToken > 0 ? Int64(reportedKVBytesCapacity / kvBytesPerToken) : 0

        let state: String
        if recoveryReloading {
            // Recovery self-restart in flight (`EngineV2Bridge+Liveness`):
            // report "reloading" for the whole drain→rebuild window — the
            // legacy `heartbeatSlotState` precedence — so the coordinator
            // deroutes the model without treating it as crashed-forever.
            state = "reloading"
        } else if wedgeMonitor.wedgeSuspected(now: now) {
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
            // Bridge-measured cold-prefill EWMA (submit → first token over
            // prompt tokens; see EngineV2Bridge.recordPrefillSample). Feeds
            // the coordinator's prefill-honest TTFT estimation.
            observedPrefillTps: observedPrefillTpsEwma,
            activeTokenBudgetUsed: budgetUsed,
            activeTokenBudgetMax: budgetMax,
            queuedTokenBudget: 0,
            kvBytesPerToken: Int64(kvBytesPerToken),
            // Slot-level bookkeeping (recorded by ensureModelLoaded on
            // load completion) — previously the legacy scheduler's field.
            modelLoadTimeMs: modelLoadTimeMs,
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

    /// This engine's live-KV admission ceiling in bytes.
    /// The heartbeat (`EngineV2Runtime.capacitySummary`) uses it as the
    /// grant input to the live budget clamp
    /// (`EngineV2KVSizing.liveEngineKVBytesBudget`); the slot factory sizes
    /// LATER engines against `slotKVBytesClaim()` — this figure PLUS the
    /// cache budget — so Σ(engine ceilings + cache budgets) stays within
    /// the process-wide KV budget (`EngineV2KVSizing.engineKVBytesCapacity`).
    public func engineKVBytesCapacity() -> Int {
        capacitySnapshot().kvBytesCapacity
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
        ).withFields(wedgeHealthFields(operation: operation, now: now))
        emit(event)
    }

    /// NON-PRIVATE wedge/engine-health field set — the same shape the
    /// legacy `BatchScheduler.engineHealthFields` emitted (operational
    /// counters + timestamps only; keys mirrored in the Go/Swift/TS
    /// telemetry allowlists), tagged `backend=engine_v2`. Shared by the
    /// step-wedge transition events above and the self-restart events
    /// (`EngineV2Bridge+Liveness`).
    func wedgeHealthFields(
        operation: String, now: ContinuousClock.Instant
    ) -> [String: AnyCodableValue] {
        [
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
            "wedge_suspected": .bool(wedgeMonitor.wedgeSuspected(now: now)),
        ]
    }
}
