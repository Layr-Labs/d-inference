// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore


@Suite("EngineV2 admission-error mapping")
struct EngineV2ErrorMappingTests {

    @Test("capacityExhausted → canonical token_budget_exhausted string → retryable class")
    func capacityExhaustedIsRetryable() async {
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.capacityExhausted(needed: 5120, available: 1024)
            ))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events.count == 1)
        guard case .error(let message)? = events.first else {
            Issue.record("expected a single .error event, got \(events)")
            return
        }
        #expect(message == "token_budget_exhausted: request requires 5120 tokens but only 1024 available")
        // The exact classification the legacy engine's rejections get:
        // retryable capacity (→ 503 with backoff upstream).
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .tokenBudgetExhausted(message))
        #expect(ProviderLoop.mapInferenceErrorToStatus(classified) == 503)
    }

    @Test("engine queue-full sentinel maps to the legacy queue-full class (429), not token-budget (503)")
    func queueFullSentinelMapsToQueueFull() async {
        // `EngineV2.submit` throws `capacityExhausted(needed: 1, available: 0)`
        // when its waiting queue is full (`gauges.beginSubmit(maxWaiting:)`) or
        // it is draining for shutdown — a SLOT rejection, not a byte figure.
        // The legacy path classifies queue saturation as `.queueFull` (429 +
        // Retry-After), so the v2 mapping must preserve that distinction
        // (round-3 PR#499 P2).
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.capacityExhausted(needed: 1, available: 0)
            ))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events.count == 1)
        guard case .error(let message)? = events.first else {
            Issue.record("expected a single .error event, got \(events)")
            return
        }
        // The exact canonical string the legacy planner emits for a full
        // queue (`BatchSchedulerTypes.RejectionReason.queueFull`) — no new
        // classification strings on the wire.
        #expect(message == "token_budget_exhausted: request queue full")
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .queueFull(message))
        #expect(ProviderLoop.mapInferenceErrorToStatus(classified) == 429)
    }

    @Test("real byte figures near the sentinel still classify as token-budget capacity")
    func nearSentinelByteFiguresStayTokenBudget() {
        // Only the exact slot-rejection sentinel (needed == 1, available ≤ 0)
        // is queue-full; a genuine byte-ledger rejection always carries
        // needed = a multiple of the per-token KV cost (≫ 1).
        let byteReject = EngineV2Translation.admissionErrorMessage(
            for: CBv2KVError.capacityExhausted(needed: 2, available: 0))
        #expect(!byteReject.contains("queue full"))
        #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(byteReject)
            == .tokenBudgetExhausted(byteReject))
        // needed == 1 with real headroom is not the sentinel either.
        let withHeadroom = EngineV2Translation.admissionErrorMessage(
            for: CBv2KVError.capacityExhausted(needed: 1, available: 512))
        #expect(!withHeadroom.contains("queue full"))
    }

    @Test("backendIneligible → non-retryable generation failure")
    func backendIneligibleIsNotRetryable() async {
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.backendIneligible(reason: "sinks unsupported")
            ))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        guard case .error(let message)? = events.first else {
            Issue.record("expected a single .error event, got \(events)")
            return
        }
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .generationFailed(message))
    }

    @Test("unknown submit error → generic failure, never claims capacity")
    func unknownErrorIsGeneric() {
        struct Boom: Error {}
        let message = EngineV2Translation.admissionErrorMessage(for: Boom())
        #expect(!message.contains("token_budget_exhausted"))
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .generationFailed(message))
    }

    @Test("duplicate request id is rejected with the legacy planner message")
    func duplicateRequestId() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        _ = await bridge.submit(request: makeRequest(), requestId: "req-dup")
        let (events, _) = await record(
            await bridge.submit(request: makeRequest(), requestId: "req-dup")
        )
        #expect(events == [.error("token_budget_exhausted: duplicate request ID")])
        // Only the first submit reached the engine.
        #expect(engine.submitted.count == 1)
        // Deterministic client fault (400), not a retryable capacity error.
        if case .error(let message)? = events.first {
            let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            #expect(classified == .requestRejected(message))
        }
    }
}


// MARK: - Capacity mapping

@Suite("EngineV2 capacity: CBv2CapacitySnapshot → BackendSlotCapacity")
struct EngineV2CapacityTests {

    @Test("budget fields follow the legacy committed/worst-case contract; activeTokens stays engine truth")
    func snapshotMapping() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 2,
                waitingRequests: 3,
                kvBytesInUse: 4_000_000,
                kvBytesCapacity: 40_000_000,
                activeTokens: 1000,
                stepsExecuted: 12345
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        // Two accepted long-max_tokens requests whose KV has barely
        // materialized: committed worst case = (5+100) + (3+200) = 308.
        _ = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 100),
            requestId: "req-cap-a")
        _ = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 200),
            requestId: "req-cap-b")
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.model == "gemma-4-27b-it")
        #expect(slot.state == "running")
        #expect(slot.numRunning == 2)
        #expect(slot.numWaiting == 3)
        // Engine truth: the real KV-resident token count, NOT the worst case.
        #expect(slot.activeTokens == 1000)
        // Coordinator admission-gate fields: the COMMITTED worst-case
        // reservation (legacy `activeTokenBudgetUsed` semantics) — a request
        // that has only materialized a prefix still holds its full budget.
        #expect(slot.maxTokensPotential == 308)
        #expect(slot.activeTokenBudgetUsed == 308)
        #expect(slot.queuedTokenBudget == 0)
        // Budget ceiling: the engine's byte capacity in tokens.
        #expect(slot.activeTokenBudgetMax == 10000)   // 40 MB / 4000 B-per-token
        #expect(slot.kvBytesPerToken == 4000)
        #expect(slot.maxConcurrency == 4)
        // The engine's own monotonic step counter flows straight through.
        #expect(slot.stepsExecuted == 12345)
        #expect(!slot.wedgeSuspected)
    }

    @Test("idle when nothing runs; budget gate disengaged when kvBytesPerToken unknown")
    func idleAndFallback() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0,
                waitingRequests: 0,
                kvBytesInUse: 123,
                kvBytesCapacity: 456,
                activeTokens: 17
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 0)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.state == "idle")
        // Engine truth flows through; no committed requests ⇒ zero budget
        // used, and an unknown rate reports budgetMax 0 so the coordinator's
        // budget gate disengages instead of trusting an invented budget.
        #expect(slot.activeTokens == 17)
        #expect(slot.activeTokenBudgetUsed == 0)
        #expect(slot.activeTokenBudgetMax == 0)
    }

    @Test("fixed and block-rounded request bytes are reflected in heartbeat tokens")
    func fixedAndAuxiliaryHeartbeatAccounting() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 1, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 40_000, activeTokens: 1))
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: 100,
            fixedRequestBytes: 250,
            auxiliaryBytesPerToken: 20,
            auxiliaryTokenGranularity: 4,
            auxiliaryTokenAllocationPadding: 1)
        _ = await bridge.submitTokenized(
            promptTokens: [1], request: makeRequest(maxTokens: 4),
            requestId: "req-fixed-aux")

        #expect(await bridge.requestReservationBytes(tokenCount: 5) == 810)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.maxTokensPotential == 5)
        #expect(slot.activeTokenBudgetUsed == 9)
        #expect(slot.activeTokenBudgetMax == 390)
    }

    @Test("finished requests release their committed budget from the heartbeat")
    func budgetReleasedOnFinish() async {
        let engine = ScriptedCBv2Engine(
            script: .stream([
                .delta(text: "x", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
            ]),
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 40_000_000, activeTokens: 0
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 100),
            requestId: "req-cap-done"))
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.activeTokenBudgetUsed == 0)
        #expect(slot.maxTokensPotential == 0)
    }

    @Test("wedge counters flow into the slot (admits / first tokens / engine steps)")
    func wedgeCountersInSlot() async {
        let engine = ScriptedCBv2Engine(
            script: .stream([
                .delta(text: "hello", tokens: [10], logprobs: nil),
                .finished(
                    reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
            ]),
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: 42
            ))
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submit(request: makeRequest()))
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.admits == 1)
        #expect(slot.firstTokensEmitted == 1)
        // Loop progress is the ENGINE's monotonic step counter (published in
        // the capacity snapshot every step), not an event-count proxy.
        #expect(slot.stepsExecuted == 42)
    }

    @Test("wedge trips only when the engine step counter flatlines under hanging admits")
    func wedgeRequiresStepFlatline() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 3, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: 100
            ))
        let bridge = makeBridge(engine: engine)
        let t0 = ContinuousClock.Instant.now
        // Three admits that never produce a first token.
        for i in 0..<3 {
            _ = await bridge.submit(request: makeRequest(), requestId: "req-hang-\(i)")
        }
        // Baseline heartbeat: step counter first observed at 100.
        _ = await bridge.backendSlotCapacity(now: t0)
        // 11s later, counter still 100 → frozen loop + 3 hanging admits over
        // the stall threshold ⇒ wedge suspected; slot derates to "crashed".
        let wedged = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(11)))
        #expect(wedged.wedgeSuspected)
        #expect(wedged.state == "crashed")
        // The counter advancing is proof of loop progress: same hanging
        // admits, but a moving engine is a slow prefill — NOT a wedge.
        engine.capacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 3, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: 101
        )
        let recovered = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(22)))
        #expect(!recovered.wedgeSuspected)
        #expect(recovered.stepsExecuted == 101)
    }

    @Test("runtime capacity summary aggregates registered bridges")
    func runtimeCapacitySummary() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 1, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 10
            ))
        let bridge = makeBridge(engine: engine)
        let runtime = EngineV2Runtime()

        // Empty registry (v2 off) → empty summary, legacy heartbeat unchanged.
        let empty = await runtime.capacitySummary()
        #expect(empty.slots.isEmpty)
        #expect(empty.activeRequests == 0)

        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)
        _ = await bridge.submit(request: makeRequest(), requestId: "req-1")
        let summary = await runtime.capacitySummary()
        #expect(summary.slots.count == 1)
        #expect(summary.slots.first?.model == "gemma-4-27b-it")
        #expect(summary.activeRequests == 1)

        await runtime.unregister(modelId: "gemma-4-27b-it")
        let after = await runtime.capacitySummary()
        #expect(after.slots.isEmpty)
    }

    @Test("budget max clamps to the live fleet budget; nil clamp preserves the raw grant")
    func budgetMaxClampsToLiveFleetBudget() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 40_000_000, activeTokens: 0
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        // No clamp (unit callers / no fleet context): construction grant.
        let raw = await bridge.backendSlotCapacity()
        #expect(raw.activeTokenBudgetMax == 10000)
        // Fleet shrank the live budget below the grant: report the clamp.
        let clamped = await bridge.backendSlotCapacity(kvBytesBudgetClamp: 20_000_000)
        #expect(clamped.activeTokenBudgetMax == 5000)
        // A clamp ABOVE the grant never inflates the report.
        let above = await bridge.backendSlotCapacity(kvBytesBudgetClamp: 80_000_000)
        #expect(above.activeTokenBudgetMax == 10000)
        // Degenerate negative clamp reports 0, never traps.
        let negative = await bridge.backendSlotCapacity(kvBytesBudgetClamp: -1)
        #expect(negative.activeTokenBudgetMax == 0)
    }

    @Test("runtime summary recomputes each bridge's budget from live fleet residency")
    func runtimeSummaryAppliesFleetClamp() async {
        let gib: UInt64 = 1024 * 1024 * 1024
        let physical = 64 * gib
        let weights = Int(8 * gib)
        let rate = 4096
        let grant = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: physical)
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: grant, activeTokens: 0
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: rate)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)

        // Fleet unchanged since construction: reported max == the grant.
        let alone = await runtime.capacitySummary(
            fleetKV: EngineV2Runtime.FleetKVContext(
                totalResidentWeightBytes: UInt64(weights), physicalBytes: physical))
        #expect(alone.slots.first?.activeTokenBudgetMax == Int64(grant / rate))

        // A 12 GiB model loaded later (legacy — subtracts nothing from the
        // grant): the reported max shrinks by exactly its weights in tokens.
        let laterWeights = 12 * gib
        let grown = await runtime.capacitySummary(
            fleetKV: EngineV2Runtime.FleetKVContext(
                totalResidentWeightBytes: UInt64(weights) + laterWeights,
                physicalBytes: physical))
        #expect(grown.slots.first?.activeTokenBudgetMax
            == Int64((grant - Int(laterWeights)) / rate))

        // No fleet context (legacy callers): raw construction figures.
        let uncontexted = await runtime.capacitySummary()
        #expect(uncontexted.slots.first?.activeTokenBudgetMax == Int64(grant / rate))
    }
}

// MARK: - Config gating

// MARK: - Paged KV backend: capacity mapping, heartbeat bind, shared-gate skip

@Suite("EngineV2Bridge paged KV backend")
struct EngineV2BridgePagedKVTests {

    @Test("terminal kv_capacity_exhausted maps to the retryable capacity error")
    func terminalCapacityErrorMapsToTokenBudget() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .error(
                    CBv2KVError.capacityExhaustedFinishPrefix
                        + "capacityExhausted(needed: 9, available: 1)"),
                usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine, kvBackendKind: .paged)
        let (events, _) = await record(await bridge.submit(
            request: makeRequest(), requestId: "req-cap-1"))
        guard case .error(let message)? = events.last else {
            Issue.record("expected terminal error, got \(events)")
            return
        }
        // The canonical capacity prefix is what the scheduler-error
        // classifier (and the coordinator) string-match for retryable
        // 429-class handling — never an in-band 5xx.
        #expect(message.hasPrefix("token_budget_exhausted:"), "got: \(message)")
    }

    @Test("other terminal engine errors pass through unmapped")
    func terminalNonCapacityErrorPassesThrough() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .error("engine exploded"),
                usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(
            request: makeRequest(), requestId: "req-cap-2"))
        guard case .error(let message)? = events.last else {
            Issue.record("expected terminal error, got \(events)")
            return
        }
        #expect(message == "engine exploded")
    }

    @Test("heartbeat binds advertised capacity to backend pool truth")
    func heartbeatBindsToBackendCapacity() async {
        // Ledger grew past the construction-fixed pool (paged re-slice
        // GROW): the advertised token budget must bind to pool truth.
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 100_000, kvBytesBackendCapacity: 60_000,
                activeTokens: 0))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 1_000)
        #expect(await bridge.backendSlotCapacity().activeTokenBudgetMax == 60)
        // The fleet-residency clamp still binds from below when tighter.
        #expect(
            await bridge.backendSlotCapacity(kvBytesBudgetClamp: 40_000)
                .activeTokenBudgetMax == 40)
    }

    @Test("ledger-only reslice never claims physical reclaim or grows past the pool")
    func pagedResliceKeepsPhysicalTruth() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 60_000, kvBytesBackendCapacity: 60_000,
                activeTokens: 0))
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: 1_000,
            kvBackendKind: .paged)

        await bridge.updateKVBytesCapacity(20_000)
        #expect(engine.capacity().kvBytesCapacity == 20_000)
        #expect(engine.capacity().kvBytesBackendCapacity == 60_000)
        #expect(await bridge.kvBackendPoolBytes() == 60_000)
        #expect(await bridge.slotKVBytesClaim() == 60_000)
        #expect(await bridge.resliceAdmissionBytesClaim() == 20_000)

        // Growing the logical target cannot mint physical pages.
        await bridge.updateKVBytesCapacity(100_000)
        #expect(engine.capacity().kvBytesCapacity == 60_000)
        #expect(engine.capacity().kvBytesBackendCapacity == 60_000)
        #expect(await bridge.backendSlotCapacity().activeTokenBudgetMax == 60)
    }

    @Test("unknown backend capacity (0) does not bind")
    func heartbeatUnknownBackendCapacityNoBind() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 100_000, activeTokens: 0))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 1_000)
        #expect(await bridge.backendSlotCapacity().activeTokenBudgetMax == 100)
    }

    @Test("paged slots skip the per-request shared-KV reserve")
    func pagedSlotSkipsSharedKVReserve() async {
        // A reservation this large fails on ANY real machine (1 GiB per
        // token × thousands of tokens), so a CONTIGUOUS bridge rejects at
        // the shared gate before the engine ever sees the submit…
        let hugeRate = 1 << 30
        let budget = GlobalKVCacheBudget()
        let contiguousEngine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let contiguousBridge = makeBridge(
            engine: contiguousEngine, kvBytesPerToken: hugeRate, kvBudget: budget,
            kvBackendKind: .contiguous)
        let (contiguousEvents, _) = await record(await contiguousBridge.submit(
            request: makeRequest(), requestId: "req-gate-1"))
        guard case .error(let rejected)? = contiguousEvents.last else {
            Issue.record("expected shared-gate rejection, got \(contiguousEvents)")
            return
        }
        #expect(rejected.hasPrefix("token_budget_exhausted:"))
        #expect(contiguousEngine.submitted.isEmpty)

        // …while a PAGED bridge admits: its pool is construction-committed
        // and already counted once in MLX residency — a per-request
        // reservation on top would double-count and collapse the gate.
        let pagedEngine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let pagedBridge = makeBridge(
            engine: pagedEngine, kvBytesPerToken: hugeRate, kvBudget: budget,
            kvBackendKind: .paged)
        _ = await record(await pagedBridge.submit(
            request: makeRequest(), requestId: "req-gate-2"))
        #expect(pagedEngine.submitted.count == 1)
    }
}
