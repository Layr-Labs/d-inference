// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 PRODUCTION-WIRING tests — live-isolated style:
// scripted in-process `CBv2Engine` stubs, a fabricated `ModelContainer`
// over a stub `LanguageModel`, isolated `EngineV2Runtime` instances.
// No model weights, no network, no prod anything.
//
// v0.7.5 ONE-ENGINE semantics under test:
//
//   * Slot build (`ProviderLoop.resliceAndBuildEngineV2Slot`, the
//     `ensureModelLoaded` call site): ALWAYS builds a v2 bridge — no flag,
//     no allowlist; construction failure THROWS (ERROR `engine_v2_refusal`
//     telemetry) and restores co-resident engines' KV grants exactly.
//   * KV re-slicing: a second model shrinks the first engine's grant to
//     its fair share; Σ(grants) ≤ the fleet KV budget; unload grows the
//     survivors back; a slice below the serviceability floor REFUSES the
//     load.
//   * Request routing (`MultiModelBatchSchedulerEngine`): both production
//     inits route text through the bridge; an entry with NO bridge is a
//     hard internal error (the fail-loud backstop — the legacy engine is
//     deleted).
//   * Heartbeat/cancellation: the runtime summary is the ONLY slot source;
//     grants are read live (post-re-slice), never construction-time.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Scripted CBv2Engine stub (same shape as EngineV2BridgeTests)

private final class WiringScriptedEngine: CBv2Engine, @unchecked Sendable {
    enum Script {
        case throwOnSubmit(any Error)
        case stream([CBv2Event])
        case manual
    }

    private let lock = NSLock()
    private let script: Script
    private var _submitted: [CBv2Request] = []
    private var _cancelled: [CBv2RequestID] = []
    private var _shutdownCalls = 0
    private var _manualContinuation: AsyncStream<CBv2Event>.Continuation?
    private var _kvBytesCapacity: Int
    private var _capacityUpdates: [Int] = []
    /// Construction-fixed physical backend capacity (paged contract: the
    /// preallocated pool never resizes; 0 = unknown/contiguous stub).
    private let kvBytesBackendCapacity: Int

    init(script: Script, kvBytesCapacity: Int = 0, kvBytesBackendCapacity: Int = 0) {
        self.script = script
        self._kvBytesCapacity = kvBytesCapacity
        self.kvBytesBackendCapacity = kvBytesBackendCapacity
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }
    var manualContinuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { _manualContinuation }
    }
    /// Every `updateKVBytesCapacity` value, in order — the re-slice trail.
    var capacityUpdates: [Int] { lock.withLock { _capacityUpdates } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let script = lock.withLock { () -> Script in
            _submitted.append(request)
            return self.script
        }
        switch script {
        case .throwOnSubmit(let error):
            throw error
        case .stream(let events):
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            for event in events { continuation.yield(event) }
            continuation.finish()
            return stream
        case .manual:
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            lock.withLock { _manualContinuation = continuation }
            return stream
        }
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { _cancelled.append(id) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: max(0, _submitted.count - _cancelled.count),
                waitingRequests: 0,
                kvBytesInUse: 0, kvBytesCapacity: _kvBytesCapacity,
                kvBytesBackendCapacity: kvBytesBackendCapacity, activeTokens: 0)
        }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            _kvBytesCapacity = max(0, bytes)
            _capacityUpdates.append(max(0, bytes))
        }
    }

    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

// MARK: - Stub tokenizer / language model / container

private struct WiringStubTokenizer: MLXLMCommon.Tokenizer {
    var templateTokens: [Int] = [1, 2, 3, 4, 5]
    /// When set, `decode` returns this verbatim — lets the think-open
    /// injection tests simulate a Qwen3.6-style rendered prompt tail
    /// (`…assistant\n<think>\n`) without touching the default per-id
    /// behavior the logprob assertions rely on.
    var decodeOverride: String?

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
    /// Deterministic per-id text ("t<id>") so logprob-entry conversion is
    /// assertable (mirrors the EngineV2BridgeTests stub).
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        if let decodeOverride { return decodeOverride }
        return tokenIds.map { "t\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? {
        if id == 2 { return "</s>" }
        guard id >= 0, id < 128, let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        templateTokens
    }
}

/// Minimal `LanguageModel` so a real `ModelContainer` can exist in tests.
/// Never forward-passed: the slot-build tests run with hooks installed
/// (container snapshot skipped) and the routing tests never touch it.
private final class WiringStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct WiringStubProcessorError: Error {}

private struct WiringStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw WiringStubProcessorError()
    }
}

private func makeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: WiringStubLanguageModel(),
            processor: WiringStubProcessor(),
            tokenizer: WiringStubTokenizer()
        ))
}

// MARK: - Telemetry capture

private final class WiringTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }
}

// MARK: - Builder-call counter

private final class BuilderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func increment() { lock.withLock { _calls += 1 } }
}

/// Thread-safe recorder for the kvBytesCapacity grants handed to the hooks.
private final class GrantRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _granted: [Int] = []
    var granted: [Int] { lock.withLock { _granted } }
    func record(_ capacity: Int) { lock.withLock { _granted.append(capacity) } }
}

// MARK: - Shared builders

private let wiringGiB: UInt64 = 1024 * 1024 * 1024
/// Deterministic machine memory for every re-slice in this file.
private let wiringPhysicalBytes: UInt64 = 64 * wiringGiB
/// makeWiringLoop's configured reserve (memory_reserve_gb = 1).
private let wiringReserveBytes: UInt64 = 1 * wiringGiB

private func makeWiringLoop(
    engineV2MaxConcurrent: UInt64 = 4,
    engineV2MaxConcurrentByModel: [String: UInt64] = [:],
    kvBackend: String = "auto"
) throws -> ProviderLoop {
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
            provider: ProviderSettings(name: "engine-v2-wiring-test", memoryReserveGB: 1),
            backend: BackendSettings(
                idleTimeoutMins: 0, maxModelSlots: 3,
                engineV2MaxConcurrent: engineV2MaxConcurrent,
                engineV2MaxConcurrentByModel: engineV2MaxConcurrentByModel,
                engineV2KVBackend: kvBackend),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func makeBridge(
    engine: WiringScriptedEngine,
    modelId: String = "gemma-4-26b-qat-4bit",
    kvBytesPerToken: Int = 0,
    kvBackendKind: EngineV2KVBackendKind = .contiguous
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(WiringStubTokenizer()),
        eosTokenIds: [2],
        kvBytesPerToken: kvBytesPerToken,
        kvBackendKind: kvBackendKind
    )
}

private func makeConstraintVerifiedWiringTokenizer() -> TokenizerHandle {
    TokenizerHandle(
        WiringStubTokenizer(),
        toolConstraintContractVerified: true)
}

private func makeSizing(
    weightsGiB: UInt64, kvRate: Int = 20_480, maxContext: Int = 131_072
) -> SlotSizingSnapshot {
    SlotSizingSnapshot(
        weightsBytes: Int(weightsGiB * wiringGiB),
        fp16KVBytesPerToken: kvRate,
        maxContextLength: maxContext,
        defaultMaxTokens: 4096)
}

private func makeOpenAIRequest(model: String = "gemma-4-26b-qat-4bit") -> OpenAIChatCompletionRequest {
    OpenAIChatCompletionRequest(
        model: model,
        messages: [OpenAIChatMessage(role: .user, content: .text("hi"))]
    )
}

/// Collect a server-engine event stream into a comparable shape.
private enum RecordedServerEvent: Equatable {
    case content(String)
    case info(prompt: Int, completion: Int)
}

private func recordServerStream(
    _ stream: AsyncThrowingStream<MLXServerGenerationEvent, Error>
) async throws -> [RecordedServerEvent] {
    var events: [RecordedServerEvent] = []
    for try await event in stream {
        switch event {
        case .content(let text):
            events.append(.content(text))
        case .info(let info):
            events.append(.info(prompt: info.promptTokens, completion: info.completionTokens))
        case .toolCall:
            continue
        }
    }
    return events
}

// MARK: - Slot build (the ensureModelLoaded call site)

@Suite("EngineV2 production wiring: v2-only slot build")
struct EngineV2SlotBuildTests {

    @Test("production selects adaptive depth only for request-stateful assistants")
    func productionMTPDepthModeFollowsDrafterCapability() {
        #expect(
            MTPAutomaticVerificationPolicy.fixedDraftTokens(
                usesRequestStatefulDrafter: true) == nil)
        #expect(
            MTPAutomaticVerificationPolicy.fixedDraftTokens(
                usesRequestStatefulDrafter: false)
                == MTPAutomaticVerificationPolicy.initialDraftTokens)
    }

    @Test("slot build is unconditional: builds, registers, and streams translated events")
    func slotBuildAlwaysBuildsRegistersAndStreams() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: wiringPhysicalBytes,
                makeEngine: { _, _ in engine }))

        let bridge = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: makeSizing(weightsGiB: 15)
        )

        // Registered with the runtime BEFORE the slot goes live.
        #expect(await runtime.bridge(forModel: "gemma-4-26b-qat-4bit") === bridge)

        // The bridge streams the translated events (legacy GenerationEvent
        // framing) from the scripted engine.
        var sawChunk = false
        var sawInfo = false
        let stream = await bridge.submit(
            request: ChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit",
                messages: [ChatMessage(role: "user", content: "hi")]))
        for await event in stream {
            switch event {
            case .chunk(let text):
                #expect(text == "Hello")
                sawChunk = true
            case .info(let prompt, let completion, _, _):
                #expect(prompt == 5)
                #expect(completion == 1)
                sawInfo = true
            case .error(let message):
                Issue.record("unexpected error event: \(message)")
            case .terminal(let cause, let message, _, _):
                Issue.record("unexpected terminal event: \(cause.rawValue) \(message)")
            }
        }
        #expect(sawChunk)
        #expect(sawInfo)
        #expect(engine.submitted.count == 1)
        // Tokenization went through the tokenizer's chat-template path.
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    @Test("single-model box gets the FULL fleet KV budget (never a static split)")
    func singleModelGetsFullBudget() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: wiringPhysicalBytes,
                makeEngine: { _, grant in
                    recorder.record(grant)
                    return WiringScriptedEngine(script: .manual, kvBytesCapacity: grant)
                }))

        let sizing = makeSizing(weightsGiB: 15)
        _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizing
        )
        let expected = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizing.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        #expect(recorder.granted == [Int(expected)])
    }

    @Test("engine construction failure THROWS + ERROR engine_v2_refusal; nothing registered")
    func constructionFailureRefusesLoudly() async throws {
        struct InitFailure: Error {}
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let telemetry = WiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: wiringPhysicalBytes,
                makeEngine: { _, _ in throw InitFailure() }))

        await #expect(throws: InitFailure.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: makeStubContainer(),
                tokenizer: TokenizerHandle(WiringStubTokenizer()),
                sizing: makeSizing(weightsGiB: 12, kvRate: 24_576)
            )
        }
        // Nothing registered — the load fails; there is no legacy fallback.
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        #expect(events.first?.severity == .error)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_refusal")
        #expect(events.first?.fields?["reason"]?.description == "engine_init_failed")
        #expect(events.first?.fields?["model"]?.description == "gpt-oss-20b")
        #expect(events.first?.fields?["error_class"]?.description.contains("InitFailure") == true)
    }


    @Test("production factory: unsupported model class throws (→ refusal)")
    func productionFactoryRejectsUnsupportedModel() {
        // A module that is neither Gemma4TextModel nor GPTOSSModel must throw
        // BEFORE any engine machinery is built — the factory catch turns this
        // into the ERROR refusal.
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.makeProductionEngine(
                model: WiringStubLanguageModel(),
                tokenizer: WiringStubTokenizer(),
                kvBytesCapacity: 1 << 20,
                maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent)
            )
        }
    }

    @Test("production factory: zero KV headroom throws (→ refusal)")
    func productionFactoryRejectsZeroKVHeadroom() {
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.makeProductionEngine(
                model: WiringStubLanguageModel(),
                tokenizer: WiringStubTokenizer(),
                kvBytesCapacity: 0,
                maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent)
            )
        }
    }

    @Test("kvBytesCapacity clamp: a ceiling above physical RAM is capped")
    func kvBytesCapacityClamp() {
        let physical: UInt64 = 16 * 1024 * 1024 * 1024  // 16 GiB
        // A sane budget passes through untouched.
        #expect(EngineV2Factory.clampKVBytesCapacity(
            4 * 1024 * 1024 * 1024, physicalBytes: physical) == 4 * 1024 * 1024 * 1024)
        // A ceiling larger than physical is clamped to physical.
        #expect(EngineV2Factory.clampKVBytesCapacity(
            Int.max, physicalBytes: physical) == Int(physical))
        // Negative degrades to 0 (the > 0 guard then rejects it upstream).
        #expect(EngineV2Factory.clampKVBytesCapacity(-1, physicalBytes: physical) == 0)
    }

    @Test("configured concurrency reaches the bridge (box-wide + per-model override)")
    func concurrencyConfigReachesBridge() async throws {
        let loop = try makeWiringLoop(
            engineV2MaxConcurrent: 6,
            engineV2MaxConcurrentByModel: ["gpt-oss-20b": 2])
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: wiringPhysicalBytes,
                makeEngine: { _, grant in
                    WiringScriptedEngine(script: .manual, kvBytesCapacity: grant)
                }))

        // Per-model override wins for gpt-oss-20b…
        let gptoss = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: makeSizing(weightsGiB: 12, kvRate: 24_576)
        )
        #expect(await gptoss.backendSlotCapacity().maxConcurrency == 2)

        // …and the box-wide value covers everything else. Heartbeat
        // max_concurrency reports the effective per-slot value.
        let gemma = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: makeSizing(weightsGiB: 15)
        )
        #expect(await gemma.backendSlotCapacity().maxConcurrency == 6)
    }
}

// MARK: - KV re-slicing across loads/unloads

@Suite("EngineV2 production wiring: KV re-slicing", .serialized)
struct EngineV2ReslicingWiringTests {

    init() {
        // unloadModel / updateAggregateCapacity read MLX GPU counters.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    /// Install slot A via the real build path, returning its engine + the
    /// grants recorder.
    private func buildAndInstallSlotA(
        _ loop: ProviderLoop, runtime: EngineV2Runtime, recorder: GrantRecorder,
        engines: @escaping @Sendable (String, Int) -> WiringScriptedEngine
    ) async throws -> (bridge: EngineV2Bridge, engine: WiringScriptedEngine, sizing: SlotSizingSnapshot) {
        let enginesBox = EngineBox()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: wiringPhysicalBytes,
                makeEngine: { modelId, grant in
                    recorder.record(grant)
                    let engine = engines(modelId, grant)
                    enginesBox.append(engine)
                    return engine
                }))
        let sizingA = makeSizing(weightsGiB: 15, kvRate: 20_480, maxContext: 262_144)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingA
        )
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        return (bridgeA, enginesBox.all[0], sizingA)
    }

    private final class EngineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _engines: [WiringScriptedEngine] = []
        var all: [WiringScriptedEngine] { lock.withLock { _engines } }
        func append(_ engine: WiringScriptedEngine) { lock.withLock { _engines.append(engine) } }
    }

    @Test("second load shrinks A to its fair share; Σ(grants) ≤ fleet budget")
    func secondLoadShrinksFirstEngine() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let (bridgeA, engineA, sizingA) = try await buildAndInstallSlotA(
            loop, runtime: runtime, recorder: recorder,
            engines: { _, grant in WiringScriptedEngine(script: .manual, kvBytesCapacity: grant) })
        let grantA0 = await bridgeA.engineKVBytesCapacity()

        // Load B (gpt-oss): A must SHRINK to its fair share before B's
        // engine is built, and B's grant is its own fair share.
        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingB
        )
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")

        // Expected fair shares from the same pure policy.
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: "gemma-4-26b-qat-4bit",
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b",
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget)

        let grantA1 = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        #expect(grantA1 == targets["gemma-4-26b-qat-4bit"])
        #expect(grantB == targets["gpt-oss-20b"])
        #expect(grantA1 < grantA0)
        #expect(UInt64(grantA1 + grantB) <= fleetBudget)
        // The shrink flowed through the engine's resize hook.
        #expect(engineA.capacityUpdates.last == grantA1)
        // Both models share ∝ rate × min(context, 131_072): gemma's 262k
        // context is capped, so the weights are 20480×131072 vs 24576×131072
        // — gemma gets the SMALLER share despite the longer context.
        #expect(grantA1 < grantB)
    }

    @Test("unload grows the survivor back to the FULL fleet budget")
    func unloadRegrowsSurvivor() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let (bridgeA, engineA, sizingA) = try await buildAndInstallSlotA(
            loop, runtime: runtime, recorder: recorder,
            engines: { _, grant in WiringScriptedEngine(script: .manual, kvBytesCapacity: grant) })

        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingB
        )
        await runtime.register(modelId: "gpt-oss-20b", bridge: bridgeB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        let shrunkA = await bridgeA.engineKVBytesCapacity()

        // Unload B: A grows back to the full budget under ITS weights alone.
        await loop.unloadModel("gpt-oss-20b")
        let grownA = await bridgeA.engineKVBytesCapacity()
        let fullBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        #expect(grownA == Int(fullBudget))
        #expect(grownA > shrunkA)
        #expect(engineA.capacityUpdates.last == grownA)
    }

    @Test("all-paged co-residency: the shrink strands physical KV, the regrow is deferred, and both residues are measured")
    func allPagedCoResidencyStrandsThenDefers() async throws {
        // THE POST-FLIP SHAPE. Once `.auto` resolves `.paged` there is no
        // contiguous slot left to contrast against — BOTH co-resident slots
        // are paged — so the surviving asymmetry is not paged-vs-contiguous.
        // It is between a slot's CONSTRUCTION-FIXED pool and the fair share
        // the fleet re-slicer keeps moving underneath it.
        //
        // Each pool here is smaller than the logical grant its slot was
        // built with: the production shape since #535, where
        // `PagedKVPhysicalCapacityPolicy` bounds physical capacity by useful
        // concurrent context, machine size, and live headroom — never by the
        // grant. (The stale premise in §15 of the migration plan, that a
        // lone paged slot commits ~the whole fleet budget as slabs, predates
        // that policy: it was written in #531 and bounded in #535.)
        //
        // The drill:
        //   1. A loads alone at the FULL fleet budget and materializes a
        //      pool sized for the box as it looked THEN;
        //   2. B arrives and the share is re-cut. A's pool is now LARGER
        //      than A's share — the surplus is STRANDED: re-promised to B on
        //      paper, still held by A's slabs in Metal;
        //   3. B leaves and A's share returns to the whole budget, far past
        //      the pool, which cannot grow — the regrow is DEFERRED.
        // Not one byte moves either way today. Both residues are now
        // MEASURED, which is exactly what a pool resize consumes and the
        // only signal an operator gets with no canary fleet.
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let telemetry = WiringTelemetrySink()
        let enginesBox = EngineBox()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: wiringPhysicalBytes,
                kvBackendKindByModel: [
                    "gemma-4-26b-qat-4bit": .paged,
                    "gpt-oss-20b": .paged,
                ],
                makeEngine: { _, grant in
                    recorder.record(grant)
                    let engine = WiringScriptedEngine(
                        script: .manual,
                        kvBytesCapacity: grant,
                        // Demand-shaped pool, capped below the logical grant.
                        kvBytesBackendCapacity: grant * 3 / 5)
                    enginesBox.append(engine)
                    return engine
                }))

        let sizingA = makeSizing(weightsGiB: 15, kvRate: 20_480, maxContext: 262_144)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingA)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        let engineA = enginesBox.all[0]
        let grantA0 = recorder.granted[0]
        let poolA = grantA0 * 3 / 5
        #expect(await bridgeA.kvBackendKind == .paged)
        #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
        // A lone slot has not been re-sliced, so there is no residue to
        // report yet — its ceiling IS its pool, by construction.
        #expect(await bridgeA.pagedPoolResizeShortfall() == nil)

        // ---- Load paged B: A's ledger shrinks past its own pool. ----
        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        #expect(await bridgeB.kvBackendKind == .paged)

        let fleetBudget2 = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: "gemma-4-26b-qat-4bit",
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b",
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget2)
        let targetA = try #require(targets["gemma-4-26b-qat-4bit"])
        let targetB = try #require(targets["gpt-oss-20b"])

        // The ledger contract is unchanged: the shrink reaches the engine
        // unclamped and the pool does not move a byte.
        #expect(targetA < poolA)
        #expect(engineA.capacityUpdates.last == targetA)
        #expect(await bridgeA.engineKVBytesCapacity() == targetA)
        #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
        #expect(await bridgeB.engineKVBytesCapacity() == targetB)

        // …and the shrink's residue is now named: physical KV A still owns
        // after its share was cut. A ledger-only shrink frees nothing, so
        // callers must never bank these bytes.
        let afterLoad = try #require(await bridgeA.pagedPoolResizeShortfall())
        #expect(afterLoad.poolBytes == poolA)
        #expect(afterLoad.requestedBytes == targetA)
        #expect(afterLoad.strandedBytes == poolA - targetA)
        #expect(afterLoad.deferredGrowthBytes == 0)
        #expect(!afterLoad.isExact)

        // DEFECT PIN (migration plan §15). This is the whole reason a pool
        // resize is a release blocker: Σ(logical grants) ≤ fleet budget
        // still holds, but Σ(PHYSICAL pools) does not — A's slabs were
        // sized against a box that no longer exists. When the resize lands
        // this assertion MUST be inverted, not deleted.
        let poolB = await bridgeB.kvBackendPoolBytes()
        #expect(UInt64(targetA + targetB) <= fleetBudget2)
        #expect(UInt64(poolA) + poolB > fleetBudget2)

        // ---- Unload B: the regrow is deferred, not honoured. ----
        await loop.unloadModel("gpt-oss-20b")
        let regrowTarget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        #expect(regrowTarget > UInt64(poolA))
        #expect(engineA.capacityUpdates.last == poolA)
        #expect(await bridgeA.engineKVBytesCapacity() == poolA)
        #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
        #expect(await bridgeA.slotKVBytesClaim() == poolA)

        let afterUnload = try #require(await bridgeA.pagedPoolResizeShortfall())
        #expect(afterUnload.requestedBytes == Int(regrowTarget))
        #expect(afterUnload.deferredGrowthBytes == Int(regrowTarget) - poolA)
        #expect(afterUnload.strandedBytes == 0)

        // Both residues surfaced, in order, as operator-visible signals —
        // the substitute for a canary fleet.
        let clamps = telemetry.events.filter {
            $0.fields?["operation"]?.description == "paged_pool_resize_clamped"
        }
        #expect(clamps.map { $0.fields?["reason"]?.description } == [
            "unreclaimed_shrink", "deferred_grow",
        ])
        #expect(clamps.allSatisfy { $0.severity == .warn })
        #expect(clamps.allSatisfy { $0.fields?["kv_backend"]?.description == "paged" })
        #expect(clamps.allSatisfy {
            $0.fields?["model"]?.description == "gemma-4-26b-qat-4bit"
        })
        // Raw bytes, never a ratio (Main's ruling): the denominator ships
        // with every delta, so share-of-pool is derivable and the overflow
        // magnitude survives — a clamped ratio would read 1.0 for both of
        // these and lose exactly the number co-residency is diagnosed by.
        // The allowlist filter is applied at the producer, so an unmirrored
        // key would vanish silently; asserting the values back is what
        // proves all three cleared it.
        #expect(clamps.allSatisfy {
            $0.fields?["pool_bytes"]?.description == String(poolA)
        })
        let shrinkEvent = try #require(clamps.first)
        #expect(shrinkEvent.fields?["pool_stranded_bytes"]?.description
            == String(poolA - targetA))
        #expect(shrinkEvent.fields?["pool_deferred_growth_bytes"]?.description == "0")
        let regrowEvent = try #require(clamps.last)
        #expect(regrowEvent.fields?["pool_deferred_growth_bytes"]?.description
            == String(Int(regrowTarget) - poolA))
        #expect(regrowEvent.fields?["pool_stranded_bytes"]?.description == "0")
    }

    @Test("mixed paged+contiguous: only the contiguous survivor can actually take its regrow")
    func mixedPagedContiguousResliceIsLedgerOnly() async throws {
        // A mixed box stays reachable after the flip: `.auto` degrades to
        // contiguous whenever `PagedKVPhysicalCapacityPolicy` cannot carve a
        // ≥1 GiB pool, which is the normal outcome for the SECOND load on a
        // small box. So this pins what mixed now means, rather than the
        // pre-flip paged-vs-contiguous contrast that a paged default erases.
        //
        // Slot A is PAGED with a demand-capped physical pool SMALLER than
        // its logical grant; slot B is contiguous. The ProviderLoop-driven
        // load/unload re-slice must:
        //   * shrink/grow ONLY admission ledgers,
        //   * keep A's physical pool byte-for-byte constant, and
        //   * let the CONTIGUOUS survivor take its regrow in full — the one
        //     thing its paged neighbour cannot do (see
        //     `allPagedCoResidencyStrandsThenDefers`), and the reason a
        //     paged-by-default fleet loses capacity that a mixed one keeps.
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let enginesBox = EngineBox()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: wiringPhysicalBytes,
                kvBackendKindByModel: ["gemma-4-26b-qat-4bit": .paged],
                makeEngine: { modelId, grant in
                    recorder.record(grant)
                    let engine = WiringScriptedEngine(
                        script: .manual,
                        kvBytesCapacity: grant,
                        // Paged slot: pool capped below the logical grant.
                        kvBytesBackendCapacity: modelId == "gemma-4-26b-qat-4bit"
                            ? grant * 3 / 5 : 0)
                    enginesBox.append(engine)
                    return engine
                }))

        let sizingA = makeSizing(weightsGiB: 15, kvRate: 20_480, maxContext: 262_144)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingA)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        let engineA = enginesBox.all[0]
        let grantA0 = recorder.granted[0]
        let poolA = UInt64(grantA0 * 3 / 5)
        #expect(await bridgeA.kvBackendKind == .paged)
        #expect(await bridgeA.kvBackendPoolBytes() == poolA)
        // Fleet accounting reads pool truth for the paged slot, not the
        // (larger) logical ledger.
        #expect(await bridgeA.slotKVBytesClaim() == Int(poolA))

        // Load contiguous B: A's admission ledger shrinks to its fair
        // share; the physical pool is untouched.
        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        let engineB = enginesBox.all[1]
        #expect(await bridgeB.kvBackendKind == .contiguous)

        let fleetBudget2 = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: "gemma-4-26b-qat-4bit",
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b",
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget2)
        let targetA = try #require(targets["gemma-4-26b-qat-4bit"])
        let targetB = try #require(targets["gpt-oss-20b"])
        // The two-model fair share sits below the pool here, so the shrink
        // reaches the engine unclamped — and the pool still never moved.
        #expect(UInt64(targetA) < poolA)
        #expect(engineA.capacityUpdates.last == targetA)
        #expect(await bridgeA.engineKVBytesCapacity() == targetA)
        #expect(await bridgeA.kvBackendPoolBytes() == poolA)
        #expect(await bridgeB.engineKVBytesCapacity() == targetB)
        // The paged slot is holding physical KV its share no longer covers.
        #expect(
            await bridgeA.pagedPoolResizeShortfall()?.strandedBytes
                == Int(poolA) - targetA)
        // A contiguous slot resizes ledger and physical capacity together,
        // so it has no residue to report at all.
        #expect(await bridgeB.pagedPoolResizeShortfall() == nil)

        // Unload the PAGED slot: the contiguous survivor's regrow target is
        // the FULL fleet budget under its own weights, and — unlike its
        // paged neighbour, whose identical regrow clamps to pool truth — it
        // takes every byte.
        await loop.unloadModel("gemma-4-26b-qat-4bit")
        let regrowB = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingB.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        #expect(regrowB > UInt64(targetB))
        #expect(engineB.capacityUpdates.last == Int(regrowB))
        #expect(await bridgeB.engineKVBytesCapacity() == Int(regrowB))
        #expect(await bridgeB.slotKVBytesClaim() == Int(regrowB))
        #expect(await bridgeB.pagedPoolResizeShortfall() == nil)
    }

    @Test("restore-on-throw: B's construction failure restores A's grant EXACTLY")
    func constructionFailureRestoresGrants() async throws {
        struct BFailure: Error {}
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let (bridgeA, engineA, _) = try await buildAndInstallSlotA(
            loop, runtime: runtime, recorder: recorder,
            engines: { _, grant in WiringScriptedEngine(script: .manual, kvBytesCapacity: grant) })
        let grantA0 = await bridgeA.engineKVBytesCapacity()

        // Swap the hooks: B's builder throws AFTER A has been shrunk.
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: wiringPhysicalBytes,
                makeEngine: { _, _ in throw BFailure() }))

        await #expect(throws: BFailure.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: makeStubContainer(),
                tokenizer: TokenizerHandle(WiringStubTokenizer()),
                sizing: makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
            )
        }

        // A was shrunk for the attempt, then restored to the EXACT prior
        // grant — the capacityUpdates trail shows shrink → restore.
        #expect(await bridgeA.engineKVBytesCapacity() == grantA0)
        let updates = engineA.capacityUpdates
        #expect(updates.count == 2)
        #expect(updates.first ?? 0 < grantA0)
        #expect(updates.last == grantA0)
        // B never registered.
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
    }

    @Test("serviceability floor: a slice below 1 GiB per slot REFUSES the load (reslice_floor)")
    func resliceFloorRefusesLoad() async throws {
        // A 16 GiB "machine": cap = min(0.9×16, 16−2) = 14 GiB. After slot
        // A's 6 GiB of weights the budget is 14 − 6 − 5.5 (activation
        // reserve) = 2.5 GiB — A loads. Adding B's 6 GiB zeroes it
        // (14 − 12 − 5.5 < 0), so any two-way slice lands below the 1 GiB
        // floor. (An 8 GiB machine no longer works as this fixture: its
        // 6 GiB cap minus the 5.5 GiB reserve cannot clear the floor for
        // even ONE slot — the deliberate consequence of the v0.8.0 reserve
        // raise for the smallest boxes.)
        let tinyPhysical: UInt64 = 16 * wiringGiB
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let telemetry = WiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: tinyPhysical,
                makeEngine: { _, grant in
                    WiringScriptedEngine(script: .manual, kvBytesCapacity: grant)
                }))

        // Slot A exists with a small grant already.
        let sizingA = makeSizing(weightsGiB: 6, kvRate: 20_480)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingA
        )
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        let grantA0 = await bridgeA.engineKVBytesCapacity()

        // Loading B would slice both below the serviceability floor →
        // REFUSED (503-shaped modelLoadFailed), A untouched, ERROR telemetry
        // with reason reslice_floor.
        await #expect(throws: InferenceError.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: makeStubContainer(),
                tokenizer: TokenizerHandle(WiringStubTokenizer()),
                sizing: makeSizing(weightsGiB: 6, kvRate: 24_576)
            )
        }
        #expect(await bridgeA.engineKVBytesCapacity() == grantA0)
        let refusal = telemetry.events.first {
            $0.fields?["operation"]?.description == "engine_v2_refusal"
        }
        #expect(refusal?.severity == .error)
        #expect(refusal?.fields?["reason"]?.description == "reslice_floor")
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
    }

    @Test("regression: a regrow parked on the re-slice gate cannot interleave mid-load")
    func regrowParkedOnGateCannotInterleaveMidLoad() async throws {
        // The reviewer-flagged race: the idle monitor's unloadModel →
        // resliceGrowSurvivors runs from its own task, NOT under the
        // isLoadingAny load gate. Without the re-slice gate it could run
        // in the middle of a load's shrink → build → install stretch —
        // recompute over the survivor ALONE (the newcomer's slot isn't
        // installed yet) and re-inflate it to the full single-model budget
        // while the newcomer holds its own grant: Σ(grants) > fleet budget.
        //
        // Deterministic shape: hold the gate via the seam (standing in for
        // an in-flight load), park a regrow behind it, install the
        // newcomer while the gate is held (as the real load does), then
        // release. The parked regrow must (a) mutate NOTHING while the
        // gate is held and (b) recompute over BOTH slots after release.
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let (bridgeA, engineA, sizingA) = try await buildAndInstallSlotA(
            loop, runtime: runtime, recorder: recorder,
            engines: { _, grant in WiringScriptedEngine(script: .manual, kvBytesCapacity: grant) })
        let updatesBeforeRace = engineA.capacityUpdates.count

        // "Load in flight": the gate is held, A already shrunk to its
        // two-model share and B's engine built with its own grant — but
        // B's slot not yet installed (the exact mid-stretch state).
        await loop.acquireResliceGateForTesting()
        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: wiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: wiringReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: "gemma-4-26b-qat-4bit",
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b",
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget)
        let targetA = try #require(targets["gemma-4-26b-qat-4bit"])
        let targetB = try #require(targets["gpt-oss-20b"])
        await bridgeA.updateKVBytesCapacity(targetA)  // the load's shrink

        // The idle-unload regrow fires NOW, mid-stretch.
        let regrow = Task { await loop.resliceGrowSurvivorsForTesting() }
        // Give it ample time to run if it were NOT parked (without the
        // gate it completes in microseconds and re-inflates A).
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            engineA.capacityUpdates.count == updatesBeforeRace + 1,
            "regrow must be parked while the gate is held — no grant mutation")
        #expect(await bridgeA.engineKVBytesCapacity() == targetA)

        // The load completes its stretch: B's engine + slot installed,
        // gate released.
        let engineB = WiringScriptedEngine(script: .manual, kvBytesCapacity: targetB)
        let bridgeB = EngineV2Bridge(
            engine: engineB,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            eosTokenIds: [2])
        await runtime.register(modelId: "gpt-oss-20b", bridge: bridgeB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        await loop.releaseResliceGateForTesting()
        await regrow.value

        // The parked regrow recomputed over BOTH slots: fair shares stand
        // (no full-single-model re-inflation), Σ ≤ budget.
        let grantA = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        #expect(grantA == targetA, "regrow must not re-inflate A past its two-model share")
        #expect(grantB == targetB)
        #expect(UInt64(grantA + grantB) <= fleetBudget)
    }

    @Test("heartbeat reads CURRENT grants: budget max tracks the re-sliced ceiling")
    func heartbeatTracksReslicedGrants() async throws {
        let rate = 20_480
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = GrantRecorder()
        let (bridgeA, _, sizingA) = try await buildAndInstallSlotA(
            loop, runtime: runtime, recorder: recorder,
            engines: { _, grant in WiringScriptedEngine(script: .manual, kvBytesCapacity: grant) })
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridgeA)

        func v2BudgetMax() async throws -> Int64 {
            await loop.updateAggregateCapacity()
            let capacity = try #require(await loop.backendCapacityForTesting())
            let slot = try #require(
                capacity.slots.first(where: { $0.model == "gemma-4-26b-qat-4bit" }))
            return slot.activeTokenBudgetMax
        }

        // Alone on the box: the heartbeat reports the full-budget grant.
        let grantA0 = await bridgeA.engineKVBytesCapacity()
        #expect(try await v2BudgetMax() == Int64(grantA0 / rate))

        // A second v2 slot loads: A's engine grant is RE-SLICED (shrunk);
        // the heartbeat must report the CURRENT grant, not the construction
        // figure.
        let sizingB = makeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            sizing: sizingB
        )
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")

        let grantA1 = await bridgeA.engineKVBytesCapacity()
        #expect(grantA1 < grantA0)
        #expect(try await v2BudgetMax() == Int64(grantA1 / rate))
        // The heartbeat carries BOTH v2 slots (and nothing else).
        await loop.updateAggregateCapacity()
        let capacity = try #require(await loop.backendCapacityForTesting())
        #expect(Set(capacity.slots.map(\.model)) == ["gemma-4-26b-qat-4bit", "gpt-oss-20b"])
        _ = sizingA
    }
}

// MARK: - Request routing (inference handler + local endpoint shapes)

@Suite("EngineV2 production wiring: request routing")
struct EngineV2RequestRoutingTests {

    @Test("coordinator registryProvider path routes through the bridge")
    func coordinatorPathRoutesThroughBridge() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .delta(text: " world", tokens: [11], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: makeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        let events = try await recordServerStream(stream)
        #expect(events.dropLast() == [.content("Hello"), .content(" world")])
        #expect(events.last == .info(prompt: 5, completion: 2))
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    /// Builds a provider engine whose stub tokenizer "renders" the given
    /// prompt tail, backed by a scripted close-only (Qwen3.6-style)
    /// thinking stream.
    private func makeThinkProbeEngine(
        decodedTail: String
    ) -> (WiringScriptedEngine, MultiModelBatchSchedulerEngine) {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "step one ", tokens: [10], logprobs: nil),
            .delta(text: "step two</think>Answer", tokens: [11], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine, modelId: "qwen3.6-test")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "qwen3.6-test": .init(
                        tokenizer: TokenizerHandle(
                            WiringStubTokenizer(decodeOverride: decodedTail)),
                        modelType: "qwen3_next",
                        engineV2Bridge: bridge)
                ]
            })
        return (engine, providerEngine)
    }

    @Test("a pre-opened think prompt injects a synthetic <think> ahead of close-only output")
    func preOpenedThinkPromptInjectsSyntheticOpen() async throws {
        let (engine, providerEngine) = makeThinkProbeEngine(
            decodedTail: "<|im_start|>assistant\n<think>\n")
        var request = makeOpenAIRequest(model: "qwen3.6-test")
        request.stream = true
        request.reasoningParser = .qwen3

        let stream = try await providerEngine.streamChatCompletion(request: request)
        let events = try await recordServerStream(stream)
        // The marker precedes the model's output; the downstream streaming
        // think parser consumes it as a state transition and then streams
        // each reasoning delta the moment it arrives (the TTFT fix).
        #expect(events == [
            .content("<think>"),
            .content("step one "),
            .content("step two</think>Answer"),
            .info(prompt: 5, completion: 2),
        ])
        // The marker is synthetic — it must never reach the engine/prompt.
        #expect(engine.submitted.count == 1)
    }

    @Test("no injection without a pre-opened think tail")
    func plainPromptTailDoesNotInject() async throws {
        let (_, providerEngine) = makeThinkProbeEngine(
            decodedTail: "<|im_start|>assistant\n")
        var request = makeOpenAIRequest(model: "qwen3.6-test")
        request.stream = true
        request.reasoningParser = .qwen3

        let stream = try await providerEngine.streamChatCompletion(request: request)
        let events = try await recordServerStream(stream)
        #expect(events.first == .content("step one "))
    }

    @Test("no injection for a non-think reasoning parser even with a pre-opened tail")
    func nonThinkParserDoesNotInject() async throws {
        let (_, providerEngine) = makeThinkProbeEngine(
            decodedTail: "<|im_start|>assistant\n<think>\n")
        var request = makeOpenAIRequest(model: "qwen3.6-test")
        request.stream = true
        request.reasoningParser = .gemma4

        let stream = try await providerEngine.streamChatCompletion(request: request)
        let events = try await recordServerStream(stream)
        #expect(events.first == .content("step one "))
    }

    @Test("required tool choice installs a CBv2 grammar before submission")
    func requiredToolChoiceInstallsGrammar() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "plain answer", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: makeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("hello"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.required))

        var emitted: [MLXServerGenerationEvent] = []
        do {
            let stream = try await providerEngine.streamChatCompletion(request: request)
            for try await event in stream {
                emitted.append(event)
            }
            Issue.record("scripted engine bypass should still fail validation")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(
                error == .toolChoiceViolation(
                    "required tool_choice produced visible text before a tool call"))
        }
        #expect(emitted.isEmpty)
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].tokenConstraint?.mode == .required)
    }

    @Test("required tool choice rejects an unpinned template contract before submit")
    func requiredToolChoiceRejectsUnpinnedTemplate() async throws {
        let engine = WiringScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("hello"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.required))

        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected pinned prompt-contract rejection")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(
                error == .invalidToolPayload(
                    "inference-enforced tool_choice requires the pinned Gemma prompt contract"))
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("required Qwen tool choice is parsed and validated before exposure")
    func requiredQwenToolChoiceUsesFailClosedPostValidation() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(
                text: "<tool_call>\n<function=get_weather>\n</function>\n</tool_call>",
                tokens: [10], logprobs: nil),
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "qwen3.8-27b-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "qwen3_5",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "qwen3.8-27b-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [.init(function: .init(name: "get_weather"))],
            toolChoice: .mode(.required),
            toolCallParser: "qwen3_coder")

        let stream = try await providerEngine.streamChatCompletion(request: request)
        var events: [MLXServerGenerationEvent] = []
        for try await event in stream { events.append(event) }

        #expect(events.contains { event in
            guard case .toolCall(let call) = event else { return false }
            return call.function.name == "get_weather"
                && call.function.arguments.isEmpty
        })
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].tokenConstraint == nil)
    }

    @Test("required Qwen tool choice rejects a non-XML parser before submit")
    func requiredQwenToolChoiceRejectsParserOverride() async throws {
        let engine = WiringScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "qwen3.8-27b-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "qwen3_5",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "qwen3.8-27b-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [.init(function: .init(name: "get_weather"))],
            toolChoice: .mode(.required),
            toolCallParser: "json")

        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected Qwen parser mismatch rejection")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == .invalidToolPayload(
                "inference-enforced Qwen tool_choice requires the qwen3_coder tool parser"))
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("auto mode returns malformed tagged output as visible text")
    func autoToolParseFallbackIsVisible() async throws {
        let malformed =
            #"<|tool_call>call:bad{payload:[}<tool_call|>"#
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: malformed, tokens: [10], logprobs: nil),
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: makeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("hello"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.auto))

        let stream = try await providerEngine.streamChatCompletion(request: request)
        var content = ""
        for try await event in stream {
            if case .content(let text) = event { content += text }
        }
        #expect(content == malformed)
        #expect(engine.submitted.first?.tokenConstraint == nil)
    }

    @Test("named tool choice rejects a parsed different function")
    func namedToolChoiceRejectsDifferentFunction() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(
                text: "<tool_call><function=get_current_weather>"
                    + "<parameter=location>Boston</parameter></function></tool_call>",
                tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: makeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .function(name: "calculate"))

        var emitted: [MLXServerGenerationEvent] = []
        do {
            let stream = try await providerEngine.streamChatCompletion(request: request)
            for try await event in stream {
                emitted.append(event)
            }
            Issue.record("expected named tool_choice mismatch")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(
                error == .toolChoiceViolation(
                    "named tool_choice produced visible text before a tool call"))
        }
        #expect(emitted.isEmpty)
    }

    @Test("constrained Gemma rejects a mismatched parser before submit")
    func constrainedToolChoiceRejectsParserOverride() async throws {
        let engine = WiringScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.required),
            toolCallParser: "json")
        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected parser mismatch rejection")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == .invalidToolPayload(
                "inference-enforced Gemma tool_choice requires the gemma tool parser"))
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("forced tool choice rejects multimodal requests before media work")
    func forcedToolChoiceRejectsMultimodalRequest() async throws {
        let engine = WiringScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        container: makeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })
        for choice: OpenAIToolChoice in [
            .mode(.required), .function(name: "calculate"),
        ] {
            let request = OpenAIChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit",
                messages: [.init(
                    role: .user,
                    content: .parts([
                        .text("describe"),
                        .imageURL("data:image/png;base64,AA=="),
                    ]))],
                tools: [.init(function: .init(name: "calculate"))],
                toolChoice: choice)

            do {
                _ = try await providerEngine.streamChatCompletion(request: request)
                Issue.record("expected forced multimodal tool choice rejection")
            } catch let error as MultiModelBatchSchedulerEngineError {
                #expect(error == .invalidToolPayload(
                    "inference-enforced tool_choice is not supported for multimodal requests"))
            }
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("tool choice none is admitted on the multimodal path")
    func noneToolChoiceIsAdmittedForMultimodalRequest() async throws {
        let engine = WiringScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        container: makeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(
                role: .user,
                content: .parts([
                    .text("describe"),
                    .imageURL("data:image/png;base64,AA=="),
                ]))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.none))

        // `none` hides the tools from the prompt and is enforced after
        // generation, so the media path constrains nothing and must admit it.
        // The request gets far enough to decode the (deliberately truncated)
        // PNG payload, which is exactly the step past the tool-choice guard.
        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected the stub media payload to fail decoding")
        } catch let error as MediaIngest.MediaError {
            #expect(error.description == "failed to decode image data into a CIImage")
        }
    }

    @Test("coordinator path threads cacheScope and logprobs plumbing into the bridge")
    func coordinatorPathThreadsSaltAndLogprobs() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(
                text: "Hello", tokens: [10],
                logprobs: [CBv2TokenLogprob(token: 10, logprob: -0.25)]),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let channel = EngineV2LogprobsChannel()
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            },
            cacheScope: "tenant-hash",
            engineV2Logprobs: EngineV2LogprobsPlumbing(topLogprobs: 3, channel: channel)
        )
        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        _ = try await recordServerStream(stream)
        #expect(engine.submitted.count == 1)
        // TB-007: the tenant scope rode through as the per-request cache
        // salt (inert — production builds the v2 engine with the prefix
        // cache off).
        #expect(engine.submitted[0].cacheSalt == "tenant-hash")
        // The logprobs plumbing flipped the sampling translation on.
        #expect(engine.submitted[0].sampling.topLogprobs == 3)
        // Entries reached the per-request channel in OpenAI shape.
        let entries = channel.drain()
        #expect(entries.count == 1)
        #expect(entries[0].token == "t10")
        #expect(entries[0].logprob == -0.25)
    }

    @Test("coordinator path threads sealed-body logit_bias and seed into the engine")
    func coordinatorPathThreadsSamplingOverrides() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            },
            // The shape `ProviderLoop.extractSamplingOverrides` produces from
            // a sealed body carrying {"logit_bias":{"7":-100,"junk":1},"seed":42}.
            engineV2Sampling: EngineV2SamplingOverrides(
                logitBias: ["7": -100, "junk": 1], seed: 42)
        )
        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        _ = try await recordServerStream(stream)
        #expect(engine.submitted.count == 1)
        // Parsed bias reached the engine ("junk" dropped, never guessed).
        #expect(engine.submitted[0].sampling.logitBias == [7: -100])
        #expect(engine.submitted[0].sampling.seed == 42)
    }

    @Test("local-endpoint acquire path routes through the bridge and releases the token")
    func localAcquirePathRoutesThroughBridge() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "local", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let released = BuilderCallCounter()
        let providerEngine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in
                MultiModelBatchSchedulerEngine.AcquiredModel(
                    tokenizer: TokenizerHandle(WiringStubTokenizer()),
                    releaseToken: OneShotRelease(
                        release: { _ in released.increment() }, modelId: modelId),
                    modelType: "gemma4",
                    engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(
                tokenizer: TokenizerHandle(WiringStubTokenizer()),
                modelType: "gemma4") },
            availableModels: { ["gemma-4-26b-qat-4bit"] }
        )

        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        let events = try await recordServerStream(stream)
        #expect(events.first == .content("local"))
        #expect(events.last == .info(prompt: 5, completion: 1))
        #expect(engine.submitted.count == 1)
        // The local reservation is dropped exactly once when the stream ends.
        #expect(released.calls == 1)
    }

    @Test("local-endpoint acquire path rejects forged internal schema metadata")
    func localAcquirePathRejectsForgedSchemaMetadata() async throws {
        let engine = WiringScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let released = BuilderCallCounter()
        let providerEngine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in
                MultiModelBatchSchedulerEngine.AcquiredModel(
                    tokenizer: TokenizerHandle(WiringStubTokenizer()),
                    releaseToken: OneShotRelease(
                        release: { _ in released.increment() }, modelId: modelId),
                    modelType: "gemma4",
                    engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(
                tokenizer: TokenizerHandle(WiringStubTokenizer()),
                modelType: "gemma4") },
            availableModels: { ["gemma-4-26b-qat-4bit"] }
        )
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    ToolSchemaNormalization.originalBooleanSchemaKey: .bool(true),
                ]),
            ]),
        ])
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))],
            tools: [OpenAITool(function: .init(
                name: "lookup", description: "Lookup", parameters: parameters))],
            toolChoice: .mode(.auto))

        do {
            let stream = try await providerEngine.streamChatCompletion(request: request)
            _ = try await recordServerStream(stream)
            Issue.record("forged internal schema metadata was accepted")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .invalidToolPayload = error else {
                Issue.record("expected invalidToolPayload, got \(error)")
                return
            }
        }
        #expect(engine.submitted.isEmpty)
        #expect(released.calls == 1)
    }

    @Test("VLM slot with a bridge: text-only request routes through the bridge")
    func vlmSlotTextRequestRoutesThroughBridge() async throws {
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine, modelId: "gemma-4-26b-qat-4bit")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        container: makeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(
            request: makeOpenAIRequest(model: "gemma-4-26b-qat-4bit"))
        let events = try await recordServerStream(stream)
        #expect(events.first == .content("Hello"))
        #expect(events.last == .info(prompt: 5, completion: 1))
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    @Test("fail-loud backstop: an entry with NO engine at all is a hard internal error")
    func noEngineEntryIsInternalError() async throws {
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "broken-model": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4")
                ]
            })

        do {
            let stream = try await providerEngine.streamChatCompletion(
                request: makeOpenAIRequest(model: "broken-model"))
            _ = try await recordServerStream(stream)
            Issue.record("expected the no-engine backstop to throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .generationFailed(let message) = error else {
                Issue.record("expected generationFailed, got \(error)")
                return
            }
            #expect(message.contains("no serving engine"))
            // 500 — a provider fault, never a silent degrade.
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 500)
        }
    }

    @Test("VLM slot with a bridge: image-bearing request never reaches the bridge")
    func vlmSlotMediaRequestBypassesBridge() async throws {
        // The media check sits ABOVE the bridge branch (ordering contract in
        // MultiModelBatchSchedulerEngine.streamChatCompletion): an
        // image-bearing request on a bridge-carrying VLM slot must take the
        // media path — here it fails inside that path (stub container /
        // throwing processor), which is exactly the proof: the scripted v2
        // engine must never see a TEXT-path submission.
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "must-not-appear", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine, modelId: "gemma-4-26b-qat-4bit")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        container: makeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })

        // A real, round-trip-verified 1x1 PNG so hasMedia + media validation
        // both engage (same fixture as MediaIngestTests).
        let tinyPNG =
            "data:image/png;base64,"
            + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
            + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
            + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
            + "AElFTkSuQmCC"
        let mediaRequest = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [
                OpenAIChatMessage(
                    role: .user,
                    content: .parts([
                        .text("what is this?"),
                        .imageURL(tinyPNG),
                    ]))
            ]
        )

        // The vision path errors on the stub fixtures (throwing processor) —
        // either shape proves the routing; what must NOT happen is a silent
        // success through the bridge's TEXT path.
        do {
            let stream = try await providerEngine.streamChatCompletion(request: mediaRequest)
            _ = try await recordServerStream(stream)
            Issue.record("media request unexpectedly succeeded on stub fixtures")
        } catch {
            // expected: media path surfaced its failure
        }
        // The v2 vision seam MAY have attempted a multimodal submission
        // (production plumbing); what it must never do is serve the request
        // through the TEXT tokenization path. With the throwing stub
        // processor nothing was ever submitted at all.
        #expect(engine.submitted.isEmpty)
    }

    @Test("cancelling the consumer cancels the engine-minted v2 request id")
    func cancellationPropagatesToBridge() async throws {
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        let consumer = Task {
            for try await _ in stream {}
        }
        // Wait until the request reaches the engine, then cancel the consumer.
        for _ in 0..<200 where engine.submitted.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.submitted.count == 1)
        consumer.cancel()
        _ = try? await consumer.value

        // Task cancellation propagates: outer stream → engine wrapper
        // (cancelUpstream → bridge.cancel) and/or the bridge stream's own
        // onTermination — either way the ENGINE-minted id gets cancelled.
        for _ in 0..<200 where engine.cancelled.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.cancelled.first == engine.submitted.first?.id)
    }
}

// MARK: - Runtime guards (capacity + cancellation)

/// These tests drive the REAL `updateAggregateCapacity` / `unloadModel`
/// paths, which read MLX GPU counters — so the mlx.metallib must be
/// colocated with the test runner. CI uses the canonical source builder and
/// stages its result under `.build`; locally run
/// `./scripts/fetch-metallib.sh debug` once. Mirrors the `LiveInferenceFixtures` pattern.
@Suite("EngineV2 production wiring: runtime guards", .serialized)
struct EngineV2RuntimeGuardTests {

    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("capacity + cancellation never consult the runtime without slots")
    func emptySlotsSkipRuntime() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)

        #expect(await loop.hasEngineV2SlotsForTesting() == false)
        await loop.updateAggregateCapacity()
        await loop.handleCancellation(requestId: "req-none", receivedFromCoordinator: false)
        #expect(await runtime.consultCount == 0)
    }

    @Test("capacity summary is the ONLY slot source; v2 slot folds into the heartbeat")
    func capacityUsesOnlyTheRuntimeSummary() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4"
        )

        #expect(await loop.hasEngineV2SlotsForTesting())
        await loop.updateAggregateCapacity()
        #expect(await runtime.consultCount == 1)
        let capacity = await loop.backendCapacityForTesting()
        let v2Slot = capacity?.slots.first { $0.model == "gemma-4-26b-qat-4bit" }
        #expect(v2Slot != nil)
        // Exactly one heartbeat slot exists — the bridge's. No legacy fold
        // can double-report a model's capacity anymore.
        #expect(capacity?.slots.count == 1)
    }

    @Test("the daemon state file carries each slot's resolved KV backend and MTP posture")
    func daemonStateCarriesSlotPosture() async throws {
        // §16.5: `darkbloom status` / `doctor` read the state file, not the
        // live engine. If the resolved backend never reaches that file the
        // operator cannot answer "is this box on paged?" at all.
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)

        let pagedBridge = makeBridge(
            engine: WiringScriptedEngine(script: .manual),
            modelId: "gemma-4-26b-qat-4bit",
            kvBackendKind: .paged)
        // `.zero` disables the posture sampler; this test is about the state
        // file, not the telemetry producer.
        await pagedBridge.configureMTPStatus(
            MTPActivationStatus(
                configured: true, active: true, reason: nil, source: nil, revision: nil,
                artifactBytes: 0, assistantBytes: 0),
            metricsInterval: .zero)
        let contiguousBridge = makeBridge(
            engine: WiringScriptedEngine(script: .manual),
            modelId: "gpt-oss-20b",
            kvBackendKind: .contiguous)

        for (modelId, bridge) in [
            ("gemma-4-26b-qat-4bit", pagedBridge), ("gpt-oss-20b", contiguousBridge),
        ] {
            await runtime.register(modelId: modelId, bridge: bridge)
            await loop.installModelSlotForTesting(
                modelId: modelId,
                container: makeStubContainer(),
                tokenizer: TokenizerHandle(WiringStubTokenizer()),
                engineV2: bridge,
                modelType: "gemma4")
        }

        await loop.updateAggregateCapacity()
        let slots = try #require(await loop.currentDaemonState().slots)
        #expect(slots.map(\.model) == ["gemma-4-26b-qat-4bit", "gpt-oss-20b"])
        #expect(slots[0].kvBackend == "paged")
        #expect(slots[1].kvBackend == "contiguous")
        // A scripted engine is not a concrete EngineV2 and reports no MTP
        // metrics, so a configured-and-activated slot resolves to
        // enabled-but-not-producing. That is precisely the distinction the
        // operator surface exists to make: enabled != producing drafts, and
        // the reason must always be named.
        #expect(slots[0].mtpEnabled == true)
        #expect(slots[0].mtpActive == false)
        #expect(slots[0].mtpInactiveReason == MTPFallbackReason.engineInactive.rawValue)
        #expect(slots[1].mtpEnabled == false)
        #expect(slots.allSatisfy { $0.loadError == nil })
    }

    @Test("a refused explicit paged load reaches the state file as a non-serving slot")
    func daemonStateCarriesRefusedPagedLoad() async throws {
        // An explicit paged request that cannot be built REFUSES, so no
        // engine and no live slot survives. `recordModelLoadError` writes
        // the state file immediately, and the join turns that record into a
        // slot entry rather than leaving doctor to guess from absence.
        // `recordModelLoadError` writes the REAL state file, so redirect it
        // through the per-loop seam (a process-global DARKBLOOM_STATE_FILE
        // setenv would race concurrently running suites' daemon-state
        // writes into this file) — then read the bytes back, which is the
        // actual contract: the CLI decodes this file, it does not call
        // into the daemon.
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dstate-refused-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let loop = try makeWiringLoop(kvBackend: "paged")
        await loop.setDaemonStateFileForTesting(stateURL)
        await loop.recordModelLoadError(
            model: "gemma-4-26b-qat-4bit",
            message: "Model 'gemma-4-26b-qat-4bit' loaded but its v2 engine construction "
                + "failed: engine_v2: paged KV backend explicitly requested but unavailable "
                + "— kernel preflight failed — unloaded")

        let slots = try #require(DaemonStateFile.read(from: stateURL)?.slots)
        #expect(slots.count == 1)
        #expect(slots[0].model == "gemma-4-26b-qat-4bit")
        #expect(slots[0].kvBackend == nil, "no engine was built; naming a backend would be a lie")
        #expect(slots[0].kvBackendRequested == "paged")
        #expect(slots[0].loadError?.contains("explicitly requested but unavailable") == true)
    }

    @Test("model_load_time_ms rides the slot after recordModelLoadTime")
    func modelLoadTimeRidesTheSlot() async throws {
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await bridge.recordModelLoadTime(ms: 12_345)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.modelLoadTimeMs == 12_345)
    }

    @Test("cancellation fans out through the runtime to the owning bridge")
    func cancellationFansOutToBridge() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4"
        )

        // Submit under the coordinator request-id (held open by the manual
        // script) so the runtime fan-out has an owner to find.
        let stream = await bridge.submit(
            request: ChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-coord-1")
        let engineId = await bridge._testEngineRequestId(for: "req-coord-1")

        await loop.handleCancellation(requestId: "req-coord-1", receivedFromCoordinator: false)
        #expect(await runtime.consultCount >= 1)
        #expect(engine.cancelled.first == engineId)
        withExtendedLifetime(stream) {}
    }

    @Test("unloading a v2 slot unregisters the bridge and drains the engine")
    func unloadRetiresBridge() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-26b-qat-4bit", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4"
        )

        await loop.unloadModel("gemma-4-26b-qat-4bit")
        #expect(await runtime.bridge(forModel: "gemma-4-26b-qat-4bit") == nil)
        #expect(engine.shutdownCalls == 1)
        #expect(await loop.hasEngineV2SlotsForTesting() == false)
    }
}

// MARK: - KV-backend degrade → heartbeat

/// The KV-backend degrade is DELIBERATE and unchanged by these tests; what
/// they pin is that it stops being SILENT. The path under test is the real
/// one, end to end inside the provider: `ProductionBuild.kvBackendFallbackReason`
/// → `EngineV2Factory.makeBridge` → `EngineV2Bridge` → `backendSlotCapacity()`
/// → `BackendSlotCapacity.kv_backend_fallback_reason` on the heartbeat wire.
///
/// It rides the HEARTBEAT, not the telemetry-event sink, on purpose: the
/// once-per-construction `engine_v2_kv_backend` event is best-effort and
/// droppable, so a fleet that misses it books a degraded slot as a
/// deliberately-contiguous one for the life of the slot.
@Suite("EngineV2 production wiring: KV-backend degrade is visible on the heartbeat")
struct EngineV2KVBackendFallbackHeartbeatTests {

    private func heartbeatSlot(
        kind: EngineV2KVBackendKind,
        fallbackReason: String?
    ) async throws -> BackendSlotCapacity {
        let bridge = try EngineV2Factory.makeBridge(
            modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            eosTokenIds: [2],
            makeEngine: {
                EngineV2Factory.ProductionBuild(
                    engine: WiringScriptedEngine(script: .manual),
                    fixedRequestBytes: 0,
                    kvBackendKind: kind,
                    kvBackendFallbackReason: fallbackReason)
            })
        return await bridge.backendSlotCapacity()
    }

    @Test("a degraded slot reports the reason on EVERY heartbeat")
    func degradedSlotReportsTheReason() async throws {
        let slot = try await heartbeatSlot(
            kind: .contiguous,
            fallbackReason: "kernel_preflight: paged kernels unavailable")
        // The resolved kind is contiguous — the degrade really happened and
        // the slot really serves contiguous. That is exactly why the kind
        // alone cannot carry the signal.
        #expect(slot.kvBackend == "contiguous")
        #expect(slot.kvBackendFallbackReason == "kernel_preflight: paged kernels unavailable")

        // …and it survives the wire, where the coordinator reads it.
        let encoded = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: encoded)
        #expect(decoded.kvBackendFallbackReason == slot.kvBackendFallbackReason)
    }

    @Test("a slot that did NOT degrade omits the field entirely")
    func cleanSlotOmitsTheField() async throws {
        // Same resolved kind as the degraded slot above — an operator who
        // configured contiguous. This half matters as much as the other: a
        // field that is always present is not a signal.
        let chosen = try await heartbeatSlot(kind: .contiguous, fallbackReason: nil)
        #expect(chosen.kvBackend == "contiguous")
        #expect(chosen.kvBackendFallbackReason == nil)
        let chosenJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(chosen)) as? [String: Any]
        #expect(chosenJSON?["kv_backend_fallback_reason"] == nil)

        // A paged slot that got what it asked for is likewise silent.
        let paged = try await heartbeatSlot(kind: .paged, fallbackReason: nil)
        #expect(paged.kvBackend == "paged")
        #expect(paged.kvBackendFallbackReason == nil)
    }

    @Test("the kill switch degrade is reported, not hidden")
    func killSwitchDegradeIsReported() async throws {
        // `DARKBLOOM_CBV2_PAGED_KV=0` on a paged-configured fleet is a
        // deliberate rollback, and the fleet still has to SEE that the slot it
        // is measuring is not the backend it configured.
        let slot = try await heartbeatSlot(kind: .contiguous, fallbackReason: "kill_switch")
        #expect(slot.kvBackendFallbackReason == "kill_switch")
    }

    @Test("an over-long reason is clamped, keeping the class the fleet groups on")
    func longReasonIsClamped() async throws {
        // The reasons interpolate arbitrary MLX/Metal error text and this
        // rides every heartbeat of every slot, unlike the once-per-load event.
        let cap = EngineV2Bridge.maxHeartbeatFallbackReasonLength
        let long = "ineligible: " + String(repeating: "x", count: cap * 4)
        let slot = try await heartbeatSlot(kind: .contiguous, fallbackReason: long)
        let reported = try #require(slot.kvBackendFallbackReason)
        #expect(reported.count == cap)
        // Truncated from the TAIL, so the leading class survives.
        #expect(reported.hasPrefix("ineligible:"))

        // The clamp must not turn "no degrade" into an empty-string degrade.
        #expect(EngineV2Bridge.heartbeatFallbackReason(nil) == nil)
    }
}
