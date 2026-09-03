// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore


@Suite("EngineV2 shared-budget KV accounting")
struct EngineV2SharedBudgetTests {

    @Test("an in-flight v2 request reserves its worst-case KV in the shared budget, released on finish")
    func recordsAndReleasesReservation() async {
        // Manual script so the request stays in-flight until we drive the terminal.
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        // 4000 B/token × (5 prompt + 16 maxTokens) = 84_000 bytes.
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        #expect(await budget.outstandingReservedBytes() == 0)

        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-acct-1")
        // No-gap invariant: the reservation is taken atomically WITH (in fact
        // strictly before) engine admission, so it is already visible the
        // instant submit returns — before the pump task runs and before the
        // stream is consumed. No polling: a concurrent model-load gate can
        // never observe zero in the window between engine admission and the
        // pump starting.
        #expect(await budget.outstandingReservedBytes() == 84_000)
        // Consume the stream on a separate task so the pump runs to terminal.
        let consumer = Task { await record(stream) }

        // Terminal → the reservation is released.
        engine.manualContinuation?.yield(
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)))
        engine.manualContinuation?.finish()
        _ = await consumer.value
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("teardown without a terminal still releases the reservation")
    func teardownReleasesReservation() async {
        // A stream that yields no terminal, then closes (engine torn down).
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "partial", tokens: [10], logprobs: nil)
        ]))
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-acct-2"))
        // The stream closed without a terminal — the pump's teardown path
        // must still have released the reservation.
        #expect(await budget.outstandingReservedBytes() == 0)
        let counters = await bridge._testCounters()
        #expect(counters.active == 0)
    }

    @Test("no reservation when kvBytesPerToken is unknown (0)")
    func noReservationWhenRateUnknown() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 0, kvBudget: budget)
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8),
            requestId: "req-acct-3")
        let consumer = Task { await record(stream) }
        // Give the pump time to run; with an unknown rate nothing is recorded.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await budget.outstandingReservedBytes() == 0)
        engine.manualContinuation?.yield(
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 3, completionTokens: 0)))
        engine.manualContinuation?.finish()
        _ = await consumer.value
    }

    @Test("shared-budget gate: exhausted pool rejects as capacity BEFORE the engine sees the request")
    func sharedBudgetGateRejectsBeforeEngine() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.exhausted()
        let telemetry = TelemetrySink()
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: 4000,
            kvBudget: budget,
            telemetry: telemetry)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-gate-1"))
        // Single canonical capacity error (5 prompt + 16 max = 21 tokens).
        #expect(events == [.error(
            "token_budget_exhausted: request requires 21 tokens "
                + "but the shared KV budget has no headroom")])
        // The gate fired BEFORE submission: the engine never saw the request,
        // and no bookkeeping leaked.
        #expect(engine.submitted.isEmpty)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(!telemetry.events.contains {
            $0.fields?["operation"]?.description == "prefix_cache_replay"
        })
        let counters = await bridge._testCounters()
        #expect(counters.active == 0)
        // Classified exactly like the legacy KV-reserve rejection: retryable
        // capacity (→ 429/503 upstream), so the coordinator reroutes.
        if case .error(let message)? = events.first {
            let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            #expect(classified == .tokenBudgetExhausted(message))
        }
    }

    @Test("shared-budget gate: another request's live reservation blocks a worst case that no longer fits")
    func sharedBudgetGateSeesOtherLiveReservations() async {
        // A pool with exactly 200_000 bytes of live headroom: 3 GiB box at
        // capFraction 1.0 ⇒ effective cap = 3 GiB − 2 GiB OS floor = 1 GiB;
        // MLX usage pinned 200_000 bytes below that cap.
        let budget = GlobalKVCacheBudget(
            capFraction: 1.0,
            activationReserveBytes: 0,
            memorySnapshot: {
                let gib: UInt64 = 1024 * 1024 * 1024
                return .init(
                    total: 3 * gib, active: gib - 200_000, cache: 0,
                    systemAvailable: 200_000)
            })
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        // First request: 21 tokens × 4000 = 84_000 bytes — fits.
        let first = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-gate-a")
        #expect(engine.submitted.count == 1)
        // Second identical worst case would need another 84_000 with only
        // 116_000 left… fits. Third does not (232_000 > 200_000).
        let second = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-gate-b")
        #expect(engine.submitted.count == 2)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-gate-c"))
        #expect(engine.submitted.count == 2)  // third never reached the engine
        if case .error(let message)? = events.first {
            #expect(message.hasPrefix("token_budget_exhausted:"))
        } else {
            Issue.record("expected a capacity error, got \(events)")
        }
        withExtendedLifetime((first, second)) {}
        await bridge.shutdown()
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("degenerate maxTokens <= 0 skips the gate (engine finishes it without KV)")
    func degenerateRequestSkipsGate() async {
        // Even on an EXHAUSTED pool, a request that can allocate no KV must
        // not be capacity-rejected by the gate — the engine's own degenerate
        // path finishes it immediately (immediate .length terminal).
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .length, usage: CBv2Usage(promptTokens: 3, completionTokens: 0))
        ]))
        let budget = TestBudgets.exhausted()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 0),
            requestId: "req-degenerate"))
        // Reached the engine (no gate rejection), reserved nothing.
        #expect(engine.submitted.count == 1)
        #expect(events == [.info(prompt: 3, completion: 0)])
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("engine rejection after the gate releases the shared reservation")
    func engineRejectionReleasesSharedReservation() async {
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.capacityExhausted(needed: 5120, available: 1024)))
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-gate-2"))
        // The engine's own rejection surfaced (its private ledger stays
        // authoritative for its slot)…
        #expect(events == [.error(
            "token_budget_exhausted: request requires 5120 tokens but only 1024 available")])
        // …and the shared reservation taken by the gate was rolled back, so
        // a rejected request can never pin shared headroom.
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("native rate is reserved on cache miss, disabled cache, and staged hit exactly once")
    func nativeRateCoversEveryCacheStateWithoutDoubleReservation() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("bridge-native-states-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let budget = TestBudgets.ample()
        let fixture = try await makeBridgeStagedCache(parent: parent, budget: budget)
        defer { fixture.cache.close() }
        let engine = ScriptedCBv2Engine(script: .manual)
        let nativeRate = 4_000
        let requestBytes = UInt64(nativeRate * (fixture.prompt.count + 1))
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: nativeRate,
            kvBudget: budget,
            ssdPrefixCache: fixture.cache)

        let missPrompt = fixture.prompt.map { $0 + 10_000 }
        let miss = await bridge.submitTokenized(
            promptTokens: missPrompt,
            request: makeRequest(maxTokens: 1),
            requestId: "req-native-miss",
            cacheScope: "scope")
        #expect(fixture.cache.bytesInUse == 0)
        #expect(await budget.outstandingReservedBytes() == requestBytes)
        engine.manualContinuation?.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: missPrompt.count, completionTokens: 0)))
        engine.manualContinuation?.finish()
        _ = await record(miss)
        #expect(await budget.outstandingReservedBytes() == 0)

        let disabled = await bridge.submitTokenized(
            promptTokens: fixture.prompt,
            request: makeRequest(maxTokens: 1),
            requestId: "req-native-disabled",
            cacheScope: "scope",
            cacheEnabled: false)
        #expect(fixture.cache.bytesInUse == 0)
        #expect(await budget.outstandingReservedBytes() == requestBytes)
        engine.manualContinuation?.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: fixture.prompt.count, completionTokens: 0)))
        engine.manualContinuation?.finish()
        _ = await record(disabled)
        #expect(await budget.outstandingReservedBytes() == 0)

        let staged = await bridge.submitTokenized(
            promptTokens: fixture.prompt,
            request: makeRequest(maxTokens: 1),
            requestId: "req-native-staged",
            cacheScope: "scope")
        let stagedBytes = fixture.cache.bytesInUse
        #expect(stagedBytes > 0)
        #expect(
            await budget.outstandingReservedBytes()
                == requestBytes + UInt64(stagedBytes),
            "staging and the native request span are each reserved exactly once")
        engine.manualContinuation?.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: fixture.prompt.count, completionTokens: 0)))
        engine.manualContinuation?.finish()
        _ = await record(staged)
        #expect(await waitForBudgetRelease(budget))
        #expect(fixture.cache.bytesInUse == 0)
    }

    @Test("bridge records terminal saved-prefill truth exactly once")
    func terminalSavedPrefillUpdatesSSDStats() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("bridge-terminal-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let budget = TestBudgets.ample()
        let fixture = try await makeBridgeStagedCache(parent: parent, budget: budget)
        defer { fixture.cache.close() }
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .stop,
                usage: CBv2Usage(
                    promptTokens: fixture.prompt.count,
                    completionTokens: 0,
                    prefixCacheOutcome: .hit,
                    prefixCacheMatchedTokens: 64,
                    prefixCachePrefillTokensSaved: 7))
        ]))
        let bridge = makeBridge(
            engine: engine,
            ssdPrefixCache: fixture.cache)

        _ = await record(await bridge.submitTokenized(
            promptTokens: fixture.prompt,
            request: makeRequest(maxTokens: 1),
            requestId: "req-terminal-saved",
            cacheScope: "scope",
            cacheEnabled: false))
        #expect(fixture.cache.stats().tokensSaved == 7)
    }

    @Test("native request byte multiplication overflow rejects before engine submission")
    func nativeRateOverflowRejectsRequest() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: Int.max,
            kvBudget: budget)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1],
            request: makeRequest(maxTokens: 1),
            requestId: "req-native-overflow"))
        #expect(engine.submitted.isEmpty)
        #expect(events == [.error(
            "token_budget_exhausted: request requires 2 tokens "
                + "but the shared KV budget has no headroom")])
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("prompt plus max-token overflow rejects before cache staging")
    func tokenCountOverflowRejectsBeforeStaging() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("bridge-token-overflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let budget = TestBudgets.ample()
        let fixture = try await makeBridgeStagedCache(parent: parent, budget: budget)
        defer { fixture.cache.close() }
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: 4_000,
            kvBudget: budget,
            ssdPrefixCache: fixture.cache)

        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: fixture.prompt,
            request: makeRequest(maxTokens: Int.max),
            requestId: "req-token-overflow",
            cacheScope: "scope"))
        #expect(events == [.error("token_budget_exhausted: request token count overflow")])
        #expect(engine.submitted.isEmpty)
        #expect(fixture.cache.stats().stages == 0)
        #expect(await waitForBudgetRelease(budget))
        #expect(fixture.cache.bytesInUse == 0)
    }

    @Test("SSD staging never false-rejects a request that fits cold at the exact boundary")
    func stagingFallsBackToColdReservation() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("bridge-stage-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let kvBytesPerToken = 1_000_000
        let worstCaseTokens = 66  // 65 prompt + 1 completion
        let coldBytes = UInt64(kvBytesPerToken * worstCaseTokens)
        let gib: UInt64 = 1_073_741_824
        let budget = GlobalKVCacheBudget(
            capFraction: 1.0,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(
                    total: 3 * gib,
                    active: gib - coldBytes,
                    cache: 0,
                    systemAvailable: coldBytes)
            })
        let fixture = try await makeBridgeStagedCache(parent: parent, budget: budget)
        defer { fixture.cache.close() }
        let engine = ScriptedCBv2Engine(script: .manual)
        let telemetry = TelemetrySink()
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: kvBytesPerToken,
            kvBudget: budget,
            ssdPrefixCache: fixture.cache,
            telemetry: telemetry)
        let signal = EngineV2RequestUsageSignal()

        let stream = await bridge.submitTokenized(
            promptTokens: fixture.prompt,
            request: makeRequest(maxTokens: 1),
            requestId: "req-stage-boundary",
            cacheScope: "scope",
            usageSignal: signal)

        #expect(engine.submitted.count == 1, "cold-fit request must reach the engine")
        #expect(engine.submitted.first?.prefixCacheReceiptID != nil)
        #expect(fixture.cache.bytesInUse == 0, "optional staging must be abandoned before retry")
        #expect(await budget.outstandingReservedBytes() == coldBytes)
        #expect(telemetry.events.contains {
            $0.fields?["reason"]?.description == "shared_kv_capacity"
                && $0.fields?["prefix_cold_fallback"]?.description == "true"
        })

        let consumer = Task { await record(stream) }
        engine.manualContinuation?.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(
                promptTokens: fixture.prompt.count,
                completionTokens: 0,
                prefixCacheOutcome: .miss)))
        engine.manualContinuation?.finish()
        _ = await consumer.value
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("native-width rate rejects staged-to-cold fallback before over-admission")
    func nativeWidthRefusalRejectsRequest() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("bridge-native-width-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let nominalKVBytesPerToken = 1_000_000
        let nativeKVBytesPerToken = nominalKVBytesPerToken + 16
        let worstCaseTokens = 66
        let nominalBytes = UInt64(nominalKVBytesPerToken * worstCaseTokens)
        let gib: UInt64 = 1_073_741_824
        let budget = GlobalKVCacheBudget(
            capFraction: 1.0,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(
                    total: 3 * gib,
                    active: gib - nominalBytes,
                    cache: 0,
                    systemAvailable: nominalBytes)
            })
        let fixture = try await makeBridgeStagedCache(parent: parent, budget: budget)
        defer { fixture.cache.close() }
        let engine = ScriptedCBv2Engine(script: .manual)
        let telemetry = TelemetrySink()
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: nativeKVBytesPerToken,
            kvBudget: budget,
            ssdPrefixCache: fixture.cache,
            telemetry: telemetry)

        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: fixture.prompt,
            request: makeRequest(maxTokens: 1),
            requestId: "req-native-width",
            cacheScope: "scope"))
        #expect(engine.submitted.isEmpty)
        #expect(events == [.error(
            "token_budget_exhausted: request requires \(worstCaseTokens) tokens "
                + "but the shared KV budget has no headroom")])
        #expect(fixture.cache.bytesInUse == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(telemetry.events.contains {
            $0.fields?["reason"]?.description == "shared_kv_capacity"
                && $0.fields?["prefix_capacity_refusal"]?.description == "true"
        })
    }
}
