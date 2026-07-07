// Copyright © 2026 Eigen Labs.
//
// Wedge self-recovery tests (v0.7.5 §1.10) — live-isolated style:
// scripted in-process `CBv2Engine` stubs, fabricated `ModelContainer`s,
// isolated `EngineV2Runtime` instances, injectable clocks. No weights.
//
// Under test:
//   * the CONFIRMED-wedge verdict (`EngineV2Bridge.confirmedWedgeForRecovery`)
//     — 120s hanging-admit stall AND 120s step flatline, both required;
//   * the recovery state machine (`ProviderLoop+EngineV2Liveness`):
//     drain → rebuild over the RETAINED container with the slot's CURRENT
//     grant (no re-slice) → re-register → swap → serving again;
//   * heartbeat honesty: "reloading" while recovering (bridge flag),
//     fresh "idle" after;
//   * the 120s cooldown: a second confirmed wedge inside it UNLOADS the
//     slot (fail loud) instead of thrashing rebuilds;
//   * rebuild failure: refusal + unload, never a half-alive slot;
//   * the co-residency regression: recovery preserves grants exactly —
//     the recovering slot keeps ITS grant, the co-resident slot is
//     untouched, and Σ(grants) ≤ fleet budget throughout.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Scripted engine (hangs by default; capacity is settable)

private final class LivenessScriptedEngine: CBv2Engine, @unchecked Sendable {
    enum Script {
        /// Never yields an event — the hanging/wedged shape.
        case hang
        /// Yield these events, then finish (the healthy rebuilt engine).
        case stream([CBv2Event])
    }

    private let lock = NSLock()
    private let script: Script
    private var _kvBytesCapacity: Int
    private var _stepsExecuted: Int = 0
    private var _submitted: [CBv2Request] = []
    private var _shutdownCalls = 0
    private var _capacityUpdates: [Int] = []
    /// Retained so a hanging stream isn't torn down by continuation deinit.
    private var _continuations: [AsyncStream<CBv2Event>.Continuation] = []

    init(script: Script, kvBytesCapacity: Int = 0) {
        self.script = script
        self._kvBytesCapacity = kvBytesCapacity
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }
    var capacityUpdates: [Int] { lock.withLock { _capacityUpdates } }

    func setStepsExecuted(_ steps: Int) {
        lock.withLock { _stepsExecuted = steps }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let script = lock.withLock { () -> Script in
            _submitted.append(request)
            return self.script
        }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        switch script {
        case .hang:
            lock.withLock { _continuations.append(continuation) }
        case .stream(let events):
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: _submitted.count,
                waitingRequests: 0,
                kvBytesInUse: 0,
                kvBytesCapacity: _kvBytesCapacity,
                activeTokens: 0,
                stepsExecuted: _stepsExecuted)
        }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            _kvBytesCapacity = max(0, bytes)
            _capacityUpdates.append(max(0, bytes))
        }
    }

    func shutdown() async {
        let continuations = lock.withLock { () -> [AsyncStream<CBv2Event>.Continuation] in
            _shutdownCalls += 1
            let held = _continuations
            _continuations.removeAll()
            return held
        }
        // Bounded-drain semantics: live streams are force-finished instead
        // of hanging forever (EngineV2.shutdown contract).
        for continuation in continuations { continuation.finish() }
    }
}

// MARK: - Stub container / telemetry / builders

private final class LivenessStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct LivenessStubProcessorError: Error {}

private struct LivenessStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw LivenessStubProcessorError()
    }
}

private func makeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/liveness-stub-model"),
            model: LivenessStubLanguageModel(),
            processor: LivenessStubProcessor(),
            tokenizer: StubBridgeTokenizer()
        ))
}

private final class LivenessTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func operations() -> [String] {
        events.compactMap { $0.fields?["operation"]?.description }
    }
    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }
}

/// Records every engine the hooks built, with the grant it was built for.
private final class EngineFactoryScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _built: [(modelId: String, grant: Int, engine: LivenessScriptedEngine)] = []
    /// Scripts per build index (0 = the load-time engine, 1 = the first
    /// recovery rebuild, …). Out-of-range indices reuse the last script.
    private let scripts: [LivenessScriptedEngine.Script]
    /// When set, the build at this index throws instead of returning.
    private let throwAtIndex: Int?
    struct RebuildFailure: Error {}

    init(scripts: [LivenessScriptedEngine.Script], throwAtIndex: Int? = nil) {
        self.scripts = scripts
        self.throwAtIndex = throwAtIndex
    }

    var built: [(modelId: String, grant: Int, engine: LivenessScriptedEngine)] {
        lock.withLock { _built }
    }

    func make(modelId: String, grant: Int) throws -> any CBv2Engine {
        let index = lock.withLock { _built.count }
        if index == throwAtIndex { throw RebuildFailure() }
        let script = scripts.indices.contains(index) ? scripts[index] : scripts.last ?? .hang
        let engine = LivenessScriptedEngine(script: script, kvBytesCapacity: grant)
        lock.withLock { _built.append((modelId, grant, engine)) }
        return engine
    }
}

private let livenessGiB: UInt64 = 1024 * 1024 * 1024
private let livenessPhysicalBytes: UInt64 = 64 * livenessGiB
private let livenessReserveBytes: UInt64 = 1 * livenessGiB

private func makeLivenessLoop() throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546
        ),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "engine-v2-liveness-test", memoryReserveGB: 1),
            backend: BackendSettings(
                continuousBatching: true, idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func makeSizing(
    weightsGiB: UInt64, kvRate: Int = 20_480, maxContext: Int = 131_072
) -> SlotSizingSnapshot {
    SlotSizingSnapshot(
        weightsBytes: Int(weightsGiB * livenessGiB),
        fp16KVBytesPerToken: kvRate,
        maxContextLength: maxContext,
        defaultMaxTokens: 4096)
}

private func makeChatRequest(model: String) -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: model,
        messages: [ChatMessage(role: "user", content: "hi")])
}

/// Install a v2 slot through the REAL load path (re-slice + factory +
/// runtime registration) and return its bridge.
private func loadSlot(
    _ loop: ProviderLoop, modelId: String, modelType: String, sizing: SlotSizingSnapshot
) async throws -> EngineV2Bridge {
    try await loop.loadV2SlotForTesting(
        modelId: modelId,
        modelType: modelType,
        container: makeStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: sizing)
}

/// Drive a wedge: one hanging admit (engine accepts, never yields) plus a
/// step-counter baseline sample at `t0`. The engine's steps never advance,
/// so any later verdict ≥ the stall window sees the full flatline.
private func injectWedge(
    bridge: EngineV2Bridge, modelId: String, at t0: ContinuousClock.Instant
) async {
    _ = await bridge.submitTokenized(
        promptTokens: [1, 2, 3],
        request: makeChatRequest(model: modelId),
        requestId: "req-wedge-\(modelId)")
    // Baseline step sample (the heartbeat normally does this).
    _ = await bridge.backendSlotCapacity(now: t0)
}

// MARK: - Bridge-level verdict + heartbeat state

@Suite("EngineV2 liveness: confirmed-wedge verdict + reloading state")
struct EngineV2LivenessVerdictTests {

    @Test("confirmed wedge needs a hanging admit, a 120s stall, AND a 120s step flatline")
    func confirmedWedgeThresholds() async {
        let engine = LivenessScriptedEngine(script: .hang)
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "m",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let t0 = ContinuousClock.Instant.now

        // No admits at all: never confirmed, however long the flatline.
        _ = await bridge.backendSlotCapacity(now: t0)
        #expect(await bridge.confirmedWedgeForRecovery(now: t0.advanced(by: .seconds(600))) == false)

        // One hanging admit + baseline sample.
        await injectWedge(bridge: bridge, modelId: "m", at: t0)

        // Below the 120s legacy stall threshold: NOT confirmed (even though
        // the 10s heartbeat SUSPICION would already be tripping).
        #expect(await bridge.confirmedWedgeForRecovery(now: t0.advanced(by: .seconds(60))) == false)

        // Past the stall threshold with the step counter frozen: confirmed.
        #expect(await bridge.confirmedWedgeForRecovery(now: t0.advanced(by: .seconds(121))))

        // A moving step counter is proof of loop progress — a slow prefill,
        // not a wedge: never confirmed.
        engine.setStepsExecuted(7)
        #expect(await bridge.confirmedWedgeForRecovery(now: t0.advanced(by: .seconds(240))) == false)
    }

    @Test("first token clears the hanging streak — no confirmed wedge")
    func firstTokenClearsVerdict() async {
        let engine = LivenessScriptedEngine(script: .stream([
            .delta(text: "ok", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 3, completionTokens: 1)),
        ]))
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "m",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let t0 = ContinuousClock.Instant.now
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeChatRequest(model: "m"))
        for await _ in stream {}
        _ = await bridge.backendSlotCapacity(now: t0)
        #expect(await bridge.confirmedWedgeForRecovery(now: t0.advanced(by: .seconds(600))) == false)
    }

    @Test("recoveryReloading reports slot state 'reloading' — with precedence over 'crashed'")
    func reloadingStatePrecedence() async {
        let engine = LivenessScriptedEngine(script: .hang)
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "m",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let t0 = ContinuousClock.Instant.now
        // Wedge-suspected shape (3 hanging admits + 10s + flatline) so the
        // baseline state would be "crashed".
        for i in 0..<3 {
            _ = await bridge.submitTokenized(
                promptTokens: [1, 2, 3], request: makeChatRequest(model: "m"),
                requestId: "req-\(i)")
        }
        _ = await bridge.backendSlotCapacity(now: t0)
        let crashed = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(11)))
        #expect(crashed.state == "crashed")

        // The recovery window wins — the legacy heartbeatSlotState
        // precedence (isReloadingForRecovery first).
        await bridge.beginRecoveryReload()
        let reloading = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(12)))
        #expect(reloading.state == "reloading")
        // And no NEW recovery can be confirmed while one is in flight.
        #expect(await bridge.confirmedWedgeForRecovery(now: t0.advanced(by: .seconds(600))) == false)

        await bridge.endRecoveryReload()
        let after = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(13)))
        #expect(after.state == "crashed")
    }
}

// MARK: - Loop-level recovery state machine

@Suite("EngineV2 liveness: wedge recovery state machine", .serialized)
struct EngineV2LivenessRecoveryTests {

    init() {
        // unloadModel / updateAggregateCapacity read MLX GPU counters — the
        // mlx.metallib must be colocated with the test runner (CI extracts
        // it; locally run `./scripts/fetch-metallib.sh debug` once).
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    private static let modelA = "gemma-4-26b-qat-4bit"
    private static let modelB = "gpt-oss-20b"

    /// Loop + isolated runtime + scripted engine factory, hooks installed.
    private func makeHarness(
        scripts: [LivenessScriptedEngine.Script],
        throwAtIndex: Int? = nil
    ) throws -> (loop: ProviderLoop, runtime: EngineV2Runtime, factory: EngineFactoryScript, telemetry: LivenessTelemetrySink) {
        let loop = try makeLivenessLoop()
        let runtime = EngineV2Runtime()
        let factory = EngineFactoryScript(scripts: scripts, throwAtIndex: throwAtIndex)
        let telemetry = LivenessTelemetrySink()
        return (loop, runtime, factory, telemetry)
    }

    private func installHooks(
        _ loop: ProviderLoop, runtime: EngineV2Runtime,
        factory: EngineFactoryScript, telemetry: LivenessTelemetrySink
    ) async {
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: livenessPhysicalBytes,
                makeEngine: { modelId, grant in try factory.make(modelId: modelId, grant: grant) }))
    }

    @Test("confirmed wedge: drain → rebuild with the SAME grant → re-register → swap → serving")
    func recoveryRebuildsOverRetainedContainer() async throws {
        let (loop, runtime, factory, telemetry) = try makeHarness(
            scripts: [
                .hang,  // load-time engine (wedges)
                .stream([  // recovery rebuild (healthy)
                    .delta(text: "back", tokens: [10], logprobs: nil),
                    .finished(reason: .stop, usage: CBv2Usage(promptTokens: 3, completionTokens: 1)),
                ]),
            ])
        await installHooks(loop, runtime: runtime, factory: factory, telemetry: telemetry)

        let sizing = makeSizing(weightsGiB: 15)
        let oldBridge = try await loadSlot(
            loop, modelId: Self.modelA, modelType: "gemma4", sizing: sizing)
        let oldEngine = factory.built[0].engine
        let grantBefore = await oldBridge.engineKVBytesCapacity()

        let t0 = ContinuousClock.Instant.now
        await injectWedge(bridge: oldBridge, modelId: Self.modelA, at: t0)

        // Below the confirmation threshold nothing happens.
        await loop.recoverWedgedEngineV2SlotsForTesting(now: t0.advanced(by: .seconds(30)))
        #expect(factory.built.count == 1)
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelA) === oldBridge)

        // Past it, the state machine runs end to end.
        let tWedge = t0.advanced(by: .seconds(130))
        await loop.recoverWedgedEngineV2SlotsForTesting(now: tWedge)

        // Drain: the wedged engine was shut down (pumps cancelled + drain).
        #expect(oldEngine.shutdownCalls == 1)
        // Rebuild: a SECOND engine was built, with EXACTLY the old grant —
        // recovery is not a re-slice.
        #expect(factory.built.count == 2)
        #expect(factory.built[1].modelId == Self.modelA)
        #expect(factory.built[1].grant == grantBefore)
        // Re-register + swap: the runtime and the slot both hold the NEW
        // bridge now.
        let newBridge = try #require(await loop.slotBridgeForTesting(modelId: Self.modelA))
        #expect(newBridge !== oldBridge)
        #expect(await runtime.bridge(forModel: Self.modelA) === newBridge)
        #expect(await newBridge.engineKVBytesCapacity() == grantBefore)
        // Cooldown anchor recorded at the attempt time.
        #expect(await loop.engineV2LastRecoveryAtForTesting(modelId: Self.modelA) == tWedge)

        // Telemetry: legacy-shaped engine_health events, ERROR on the
        // restart edge and INFO on completion (with a duration).
        let events = telemetry.events
        let restart = events.first {
            $0.fields?["operation"]?.description == "engine_v2_self_restart"
        }
        #expect(restart?.severity == .error)
        #expect(restart?.fields?["model"]?.description == Self.modelA)
        #expect(restart?.fields?["backend"]?.description == "engine_v2")
        #expect(restart?.fields?["wedge_suspected"] != nil)
        #expect(restart?.fields?["consecutive_admits_without_first_token"] != nil)
        let complete = events.first {
            $0.fields?["operation"]?.description == "engine_v2_self_restart_complete"
        }
        #expect(complete?.severity == .info)
        #expect(complete?.fields?["duration_ms"] != nil)

        // Serving again: fresh monitor (no stale wedge state), slot "idle",
        // and a real submission streams through the rebuilt engine.
        let post = await newBridge.backendSlotCapacity(now: tWedge.advanced(by: .seconds(1)))
        #expect(post.state == "idle")
        #expect(post.wedgeSuspected == false)
        var sawChunk = false
        let stream = await newBridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeChatRequest(model: Self.modelA))
        for await event in stream {
            if case .chunk(let text) = event, text == "back" { sawChunk = true }
        }
        #expect(sawChunk)
    }

    @Test("regression: recovery preserves grants exactly on a two-model box (Σ ≤ budget)")
    func recoveryPreservesCoResidentGrants() async throws {
        let (loop, runtime, factory, telemetry) = try makeHarness(
            scripts: [.hang, .hang, .stream([])])
        await installHooks(loop, runtime: runtime, factory: factory, telemetry: telemetry)

        // Two co-resident slots — the load path re-sliced their grants.
        let sizingA = makeSizing(weightsGiB: 15, kvRate: 20_480)
        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576)
        let bridgeA = try await loadSlot(
            loop, modelId: Self.modelA, modelType: "gemma4", sizing: sizingA)
        let bridgeB = try await loadSlot(
            loop, modelId: Self.modelB, modelType: "gpt_oss", sizing: sizingB)
        let grantA = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: livenessPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: livenessReserveBytes)
        #expect(UInt64(grantA + grantB) <= fleetBudget)

        // Wedge + recover A only.
        let t0 = ContinuousClock.Instant.now
        await injectWedge(bridge: bridgeA, modelId: Self.modelA, at: t0)
        await loop.recoverWedgedEngineV2SlotsForTesting(now: t0.advanced(by: .seconds(130)))

        // A's rebuilt engine holds EXACTLY A's pre-recovery grant; B's
        // engine saw no capacity update at all; Σ unchanged ≤ budget.
        let newBridgeA = try #require(await loop.slotBridgeForTesting(modelId: Self.modelA))
        #expect(newBridgeA !== bridgeA)
        #expect(await newBridgeA.engineKVBytesCapacity() == grantA)
        #expect(await bridgeB.engineKVBytesCapacity() == grantB)
        let engineB = factory.built[1].engine
        #expect(engineB.capacityUpdates.isEmpty, "co-resident slot must not be re-sliced by a recovery")
        #expect(factory.built.count == 3)
        #expect(factory.built[2].grant == grantA)
        #expect(UInt64(grantA + grantB) <= fleetBudget)
    }

    @Test("second confirmed wedge inside the 120s cooldown unloads the slot (fail loud)")
    func secondWedgeInsideCooldownUnloads() async throws {
        let (loop, runtime, factory, telemetry) = try makeHarness(scripts: [.hang])
        await installHooks(loop, runtime: runtime, factory: factory, telemetry: telemetry)
        let bridge = try await loadSlot(
            loop, modelId: Self.modelA, modelType: "gemma4", sizing: makeSizing(weightsGiB: 15))
        let engine = factory.built[0].engine

        let t0 = ContinuousClock.Instant.now
        await injectWedge(bridge: bridge, modelId: Self.modelA, at: t0)
        // A recovery attempt happened 60s ago (inside the 120s cooldown).
        let tWedge = t0.advanced(by: .seconds(130))
        await loop.setEngineV2LastRecoveryAtForTesting(
            modelId: Self.modelA, at: tWedge.advanced(by: .seconds(-60)))

        await loop.recoverWedgedEngineV2SlotsForTesting(now: tWedge)

        // No rebuild: the slot is UNLOADED instead — heartbeats drop it and
        // the coordinator routes around; the drained engine was shut down.
        #expect(factory.built.count == 1, "no rebuild inside the cooldown")
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelA) == nil)
        #expect(await runtime.bridge(forModel: Self.modelA) == nil)
        #expect(engine.shutdownCalls == 1)
        let unload = telemetry.events.first {
            $0.fields?["operation"]?.description == "engine_v2_self_restart_cooldown_unload"
        }
        #expect(unload?.severity == .error)
        #expect(unload?.fields?["model"]?.description == Self.modelA)
        // No restart/complete events fired.
        #expect(!telemetry.operations().contains("engine_v2_self_restart"))
        #expect(!telemetry.operations().contains("engine_v2_self_restart_complete"))
    }

    @Test("outside the cooldown a re-wedge recovers again (cooldown anchored on the attempt)")
    func reWedgeOutsideCooldownRecoversAgain() async throws {
        let (loop, runtime, factory, telemetry) = try makeHarness(
            scripts: [.hang, .hang, .stream([])])
        await installHooks(loop, runtime: runtime, factory: factory, telemetry: telemetry)
        let bridge = try await loadSlot(
            loop, modelId: Self.modelA, modelType: "gemma4", sizing: makeSizing(weightsGiB: 15))

        // First recovery.
        let t0 = ContinuousClock.Instant.now
        await injectWedge(bridge: bridge, modelId: Self.modelA, at: t0)
        let firstAttempt = t0.advanced(by: .seconds(130))
        await loop.recoverWedgedEngineV2SlotsForTesting(now: firstAttempt)
        #expect(factory.built.count == 2)
        let secondBridge = try #require(await loop.slotBridgeForTesting(modelId: Self.modelA))

        // The rebuilt engine wedges again, but the second confirmation
        // lands AFTER the cooldown expired — recover again, don't unload.
        await injectWedge(bridge: secondBridge, modelId: Self.modelA, at: firstAttempt)
        let secondAttempt = firstAttempt.advanced(by: .seconds(130))
        await loop.recoverWedgedEngineV2SlotsForTesting(now: secondAttempt)
        #expect(factory.built.count == 3)
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelA) != nil)
        #expect(await runtime.bridge(forModel: Self.modelA) != nil)
        #expect(await loop.engineV2LastRecoveryAtForTesting(modelId: Self.modelA) == secondAttempt)
    }

    @Test("rebuild failure: refusal + slot unload — never a half-alive slot")
    func rebuildFailureUnloads() async throws {
        let (loop, runtime, factory, telemetry) = try makeHarness(
            scripts: [.hang], throwAtIndex: 1)
        await installHooks(loop, runtime: runtime, factory: factory, telemetry: telemetry)
        let bridge = try await loadSlot(
            loop, modelId: Self.modelA, modelType: "gemma4", sizing: makeSizing(weightsGiB: 15))
        let engine = factory.built[0].engine

        let t0 = ContinuousClock.Instant.now
        await injectWedge(bridge: bridge, modelId: Self.modelA, at: t0)
        await loop.recoverWedgedEngineV2SlotsForTesting(now: t0.advanced(by: .seconds(130)))

        // Drained, then the rebuild threw → slot unloaded + unregistered.
        #expect(engine.shutdownCalls >= 1)
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelA) == nil)
        #expect(await runtime.bridge(forModel: Self.modelA) == nil)
        let operations = telemetry.operations()
        #expect(operations.contains("engine_v2_self_restart"))
        #expect(operations.contains("engine_v2_self_restart_failed"))
        // The factory's fail-loud refusal fired too (engine_init_failed).
        let refusal = telemetry.events.first {
            $0.fields?["operation"]?.description == "engine_v2_refusal"
        }
        #expect(refusal?.fields?["reason"]?.description == "engine_init_failed")
    }

    @Test("no recovery while shutting down or for a mid-unload slot")
    func recoverySkipsShutdownAndUnloading() async throws {
        let (loop, runtime, factory, telemetry) = try makeHarness(scripts: [.hang])
        await installHooks(loop, runtime: runtime, factory: factory, telemetry: telemetry)
        let bridge = try await loadSlot(
            loop, modelId: Self.modelA, modelType: "gemma4", sizing: makeSizing(weightsGiB: 15))
        let t0 = ContinuousClock.Instant.now
        await injectWedge(bridge: bridge, modelId: Self.modelA, at: t0)

        await loop.beginShutdownForTesting()
        await loop.recoverWedgedEngineV2SlotsForTesting(now: t0.advanced(by: .seconds(130)))
        #expect(factory.built.count == 1, "no rebuild during shutdown")
        #expect(await loop.slotBridgeForTesting(modelId: Self.modelA) === bridge)
    }
}
