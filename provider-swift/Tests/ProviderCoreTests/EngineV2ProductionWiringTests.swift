// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 PRODUCTION-WIRING tests — live-isolated style:
// scripted in-process `CBv2Engine` stubs, a fabricated `ModelContainer`
// over a stub `LanguageModel`, isolated `EngineV2Runtime` instances.
// No model weights, no network, no prod anything.
//
// Covers the P1 integration gap (bridge implemented but never
// instantiated on production paths):
//
//   * Slot factory (`ProviderLoop.makeEngineV2BridgeForSlot`, the
//     `ensureModelLoaded` call site): flag-on + allowlisted model builds
//     a bridge via the factory seam AND registers it with the runtime;
//     flag-off / non-allowlisted returns nil without invoking the builder
//     or consulting the runtime; init failure falls back to legacy with
//     the WARN `engine_v2_fallback` telemetry event.
//   * Request routing (`MultiModelBatchSchedulerEngine`): both production
//     inits — the registryProvider shape used by the coordinator
//     inference handler and the atomic-acquire shape used by the local
//     endpoint — route generation through the bridge when present and
//     return the translated stream; the legacy scheduler path is
//     untouched when no bridge exists.
//   * Zero-overhead guards: `updateAggregateCapacity` and
//     `handleCancellation` consult the `EngineV2Runtime` ONLY when at
//     least one v2 slot exists (assert zero runtime consults flag-off);
//     with a v2 slot, capacity folds the bridge slot into the heartbeat
//     payload and cancellation fans out to the owning engine.

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

    init(script: Script) {
        self.script = script
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }
    var manualContinuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { _manualContinuation }
    }

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
        let running = lock.withLock { _submitted.count - _cancelled.count }
        return CBv2CapacitySnapshot(
            activeRequests: max(0, running), waitingRequests: 0,
            kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

// MARK: - Stub tokenizer / language model / container

private struct WiringStubTokenizer: MLXLMCommon.Tokenizer {
    var templateTokens: [Int] = [1, 2, 3, 4, 5]

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
    /// Deterministic per-id text ("t<id>") so logprob-entry conversion is
    /// assertable (mirrors the EngineV2BridgeTests stub).
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
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
/// Never forward-passed: the slot-factory tests run with hooks installed
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

// MARK: - Shared builders

private func makeWiringLoop(engineV2Enabled: Bool = false) throws -> ProviderLoop {
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
                continuousBatching: true, idleTimeoutMins: 0, maxModelSlots: 2,
                engineV2: engineV2Enabled),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func makeBridge(
    engine: WiringScriptedEngine,
    modelId: String = "gemma-4-27b-it"
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(WiringStubTokenizer()),
        eosTokenIds: [2]
    )
}

private func makeOpenAIRequest(model: String = "gemma-4-27b-it") -> OpenAIChatCompletionRequest {
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

// MARK: - Slot factory (the ensureModelLoaded call site)

@Suite("EngineV2 production wiring: model-load slot factory")
struct EngineV2SlotFactoryTests {

    @Test("flag off: no bridge, builder never invoked, runtime never consulted")
    func flagOffBuildsNothing() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: false)
        let runtime = EngineV2Runtime()
        let counter = BuilderCallCounter()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [:],
                makeEngine: { _, _ in
                    counter.increment()
                    return WiringScriptedEngine(script: .manual)
                }))

        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        #expect(bridge == nil)
        #expect(counter.calls == 0)
        #expect(await runtime.bridge(forModel: "gemma-4-27b-it") == nil)
        #expect(await runtime.consultCount == 0)
    }

    @Test("flag on + non-allowlisted model: legacy, builder never invoked")
    func flagOnNonAllowlistedStaysLegacy() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let counter = BuilderCallCounter()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [:],
                makeEngine: { _, _ in
                    counter.increment()
                    return WiringScriptedEngine(script: .manual)
                }))

        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "qwen3-8b",
            modelType: "qwen3",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        #expect(bridge == nil)
        #expect(counter.calls == 0)
        #expect(await runtime.bridge(forModel: "qwen3-8b") == nil)
    }

    @Test("flag on + allowlisted model: builds, registers, and streams translated events")
    func flagOnAllowlistedBuildsRegistersAndStreams() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: false)  // env flag wins
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    // The default allowlist is now the exact prod checkpoint ids;
                    // these wiring fixtures use family-glob test ids, so widen it.
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*,gpt-oss*",
                ],
                eosTokenIds: [2],
                makeEngine: { _, _ in engine }))

        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        let unwrapped = try #require(bridge)

        // Registered with the runtime BEFORE the slot goes live.
        #expect(await runtime.bridge(forModel: "gemma-4-27b-it") === unwrapped)

        // The bridge streams the translated events (legacy GenerationEvent
        // framing) from the scripted engine.
        var sawChunk = false
        var sawInfo = false
        let stream = await unwrapped.submit(
            request: ChatCompletionRequest(
                model: "gemma-4-27b-it",
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
            }
        }
        #expect(sawChunk)
        #expect(sawInfo)
        #expect(engine.submitted.count == 1)
        // Tokenization went through the tokenizer's chat-template path.
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    @Test("non-allowlisted VLM slot: silently legacy (no WARN noise, builder never invoked)")
    func nonAllowlistedVLMSlotStaysLegacySilently() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let counter = BuilderCallCounter()
        let telemetry = WiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1"
                    // DEFAULT allowlist (exact prod checkpoint ids) — the
                    // fixture id below is NOT on it.
                ],
                emitTelemetry: telemetry.callback(),
                makeEngine: { _, _ in
                    counter.increment()
                    return WiringScriptedEngine(script: .manual)
                }))

        // A VLM build that is NOT allowlisted (e.g. a bare vision conversion
        // an operator never staged) must be a SILENT legacy skip — no
        // extraction attempt, no per-load WARN spam.
        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it-vision-experimental",
            modelType: "gemma4",
            isVLM: true,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        #expect(bridge == nil)
        #expect(counter.calls == 0)
        #expect(telemetry.events.isEmpty)
        #expect(await runtime.bridge(forModel: "gemma-4-27b-it-vision-experimental") == nil)
    }

    @Test("allowlisted VLM slot: builds + registers a bridge (extraction seam via hooks)")
    func allowlistedVLMSlotBuildsBridge() async throws {
        // v0.7.2: allowlisted VLM slots are no longer gated out per-slot —
        // the factory attempts the weight-sharing text-model extraction and
        // serves TEXT through v2. The hooks' engine builder stands in for
        // the extraction+engine step.
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .manual)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*",
                ],
                eosTokenIds: [2],
                makeEngine: { _, _ in engine }))

        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-26b-8bit",
            modelType: "gemma4",
            isVLM: true,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        let unwrapped = try #require(bridge)
        #expect(await runtime.bridge(forModel: "gemma-4-26b-8bit") === unwrapped)
    }

    @Test("allowlisted VLM slot: extraction failure → legacy + WARN engine_v2_fallback")
    func allowlistedVLMExtractionFailureFallsBackWithWarn() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let telemetry = WiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*",
                ],
                emitTelemetry: telemetry.callback(),
                makeEngine: { _, _ in
                    // Stands in for any extraction failure (config decode,
                    // verify [.all] mismatch, forward-parity gate).
                    throw EngineV2VLMTextExtractionError.parityMismatch("scripted")
                }))

        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-26b-8bit",
            modelType: "gemma4",
            isVLM: true,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        #expect(bridge == nil)
        #expect(await runtime.bridge(forModel: "gemma-4-26b-8bit") == nil)
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        #expect(events.first?.severity == .warn)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_fallback")
        #expect(events.first?.fields?["model"]?.description == "gemma-4-26b-8bit")
        #expect(
            events.first?.fields?["error_class"]?.description
                .contains("EngineV2VLMTextExtractionError") == true)
    }

    @Test("production factory: unsupported model class throws (→ fallback)")
    func productionFactoryRejectsUnsupportedModel() {
        // A module that is neither Gemma4TextModel nor GPTOSSModel must throw
        // BEFORE any engine machinery is built — the factory catch turns this
        // into the WARN fallback.
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.makeProductionEngine(
                model: WiringStubLanguageModel(),
                tokenizer: WiringStubTokenizer(),
                kvBytesCapacity: 1 << 20
            )
        }
    }

    @Test("production factory: zero KV headroom throws (→ fallback)")
    func productionFactoryRejectsZeroKVHeadroom() {
        #expect(throws: EngineV2ProductionError.self) {
            _ = try EngineV2Factory.makeProductionEngine(
                model: WiringStubLanguageModel(),
                tokenizer: WiringStubTokenizer(),
                kvBytesCapacity: 0
            )
        }
    }

    @Test("kvBytesCapacity clamp: a ceiling above physical RAM is capped (fix #10)")
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

    @Test("kv_quant off: bridge sized at the scheduler rate, no kv_quant WARN")
    func kvQuantOffNoWarn() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let telemetry = WiringTelemetrySink()
        let engine = WiringScriptedEngine(script: .manual)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    // The default allowlist is now the exact prod checkpoint ids;
                    // these wiring fixtures use family-glob test ids, so widen it.
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*,gpt-oss*",
                ],
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                makeEngine: { _, _ in engine }))

        // Rates equal ⇒ kv_quant not engaged.
        let scheduler = BatchScheduler()
        await scheduler._setKVRatesForTest(
            kvBytesPerToken: 400_000, fp16KVBytesPerToken: 400_000)
        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: scheduler
        )
        _ = try #require(bridge)
        // No kv_quant WARN fired.
        #expect(telemetry.events.allSatisfy {
            $0.fields?["operation"]?.description != "engine_v2_kv_quant_unsupported"
        })
    }

    @Test("kv_quant on: WARN engine_v2_kv_quant_unsupported + fp16 sizing")
    func kvQuantOnWarnsAndSizesFP16() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let telemetry = WiringTelemetrySink()
        // A stream so the bridge admits + heartbeats; the capacity math uses
        // the fp16 rate the factory chose.
        let engine = WiringScriptedEngine(script: .manual)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    // The default allowlist is now the exact prod checkpoint ids;
                    // these wiring fixtures use family-glob test ids, so widen it.
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*,gpt-oss*",
                ],
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                makeEngine: { _, _ in engine }))

        // Quantized rate below fp16 ⇒ kv_quant engaged for this model.
        let scheduler = BatchScheduler()
        await scheduler._setKVRatesForTest(
            kvBytesPerToken: 100_000, fp16KVBytesPerToken: 400_000)
        let bridge = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: scheduler
        ))
        // WARN fired with allowlisted fields.
        let warn = telemetry.events.first {
            $0.fields?["operation"]?.description == "engine_v2_kv_quant_unsupported"
        }
        #expect(warn != nil)
        #expect(warn?.severity == .warn)
        #expect(warn?.kind == .engineHealth)
        #expect(warn?.fields?["backend"]?.description == "engine_v2")
        #expect(warn?.fields?["model"]?.description == "gemma-4-27b-it")
        // The bridge was sized at the fp16 rate (400_000), not the quantized
        // 100_000: the heartbeat slot reports kvBytesPerToken == fp16.
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.kvBytesPerToken == 400_000)
    }

    @Test("engine init failure: legacy fallback + WARN engine_v2_fallback telemetry")
    func initFailureFallsBackWithTelemetry() async throws {
        struct InitFailure: Error {}
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let telemetry = WiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [:],
                emitTelemetry: telemetry.callback(),
                makeEngine: { _, _ in throw InitFailure() }))

        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        #expect(bridge == nil)
        // Nothing registered — the slot serves legacy.
        #expect(await runtime.bridge(forModel: "gpt-oss-20b") == nil)
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        #expect(events.first?.severity == .warn)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_fallback")
        #expect(events.first?.fields?["backend"]?.description == "engine_v2")
        #expect(events.first?.fields?["error_class"]?.description.contains("InitFailure") == true)
    }
}

// MARK: - Multi-slot KV capacity sizing (fleet-wide ceilings)

/// Engine stub that reports a construction-granted KV admission ceiling —
/// what the slot factory reads back (via
/// `EngineV2Bridge.engineKVBytesCapacity`) when sizing a LATER engine.
private final class CapacityReportingEngine: CBv2Engine, @unchecked Sendable {
    let kvBytesCapacity: Int
    init(kvBytesCapacity: Int) { self.kvBytesCapacity = kvBytesCapacity }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: kvBytesCapacity, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Thread-safe recorder for the kvBytesCapacity values handed to the hooks.
private final class CapacityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _granted: [Int] = []
    var granted: [Int] { lock.withLock { _granted } }
    func record(_ capacity: Int) { lock.withLock { _granted.append(capacity) } }
}

@Suite("EngineV2 production wiring: multi-slot KV capacity")
struct EngineV2MultiSlotCapacityTests {

    private static let gib: UInt64 = 1024 * 1024 * 1024

    @Test("pure sizing: the second engine's ceiling subtracts co-resident weights AND the first ceiling")
    func pureSizingSubtractsFleetResidency() {
        let physical = 64 * Self.gib
        let wA = Int(8 * Self.gib)
        let wB = Int(12 * Self.gib)
        // First engine, alone on the box: the whole budget under its weights.
        let capA = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: wA, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: physical)
        #expect(UInt64(capA) == UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: UInt64(wA)))
        // Second engine: fleet budget now counts BOTH models' weights, and
        // the first engine's construction-fixed grant comes off the top.
        // Here the first grant already consumed everything (kvBudget(wA+wB)
        // = capA − wB < capA), so the second slot gets 0 → the factory
        // throws noKVHeadroom and the slot serves via the legacy scheduler
        // (v2 effectively single-slot when the first engine took the pie).
        let capB = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: wB, coResidentWeightBytes: UInt64(wA),
            existingEngineKVCapacities: [capA], physicalBytes: physical)
        #expect(capB == 0)
        // The pre-fix behavior — sizing B as if ONLY its weights were
        // resident — would have granted far more than the fleet budget:
        let naiveB = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: UInt64(wB))
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: UInt64(wA) + UInt64(wB))
        #expect(UInt64(capA) + naiveB > fleetBudget)   // the bug this fixes
        #expect(UInt64(capA + capB)
            <= UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: physical, residentWeightBytes: UInt64(wA)))
    }

    @Test("pure sizing: two-slot ceilings sum exactly to the fleet budget when headroom remains")
    func pureSizingSumsWithinBudget() {
        let physical = 64 * Self.gib
        let wA = Int(8 * Self.gib)
        let wB = Int(4 * Self.gib)
        // First engine granted under a TIGHTER view (e.g. operator cap /
        // memory pressure at its load): 10 GiB ceiling.
        let capA = Int(10 * Self.gib)
        let capB = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: wB, coResidentWeightBytes: UInt64(wA),
            existingEngineKVCapacities: [capA], physicalBytes: physical)
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: UInt64(wA) + UInt64(wB))
        #expect(capB > 0)
        // Σ(ceilings) lands exactly ON the fleet-wide KV budget — the
        // process-wide invariant the pre-fix per-slot sizing violated.
        #expect(UInt64(capA + capB) == fleetBudget)
    }

    @Test("pure sizing honors memory_reserve_gb in both regimes (round-3 PR#499 P2)")
    func pureSizingHonorsMemoryReserve() {
        // 32 GiB box: cap = 0.9 × 32 = 28.8 GiB ⇒ cap-implied reserve 3.2 GiB.
        let physical = 32 * Self.gib
        let weights = Int(8 * Self.gib)
        let unreserved = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: physical)
        // Regime 1 — reserve BELOW the cap-implied reserve (2 GiB < 3.2 GiB):
        // the cap already holds back more; the configured reserve is a no-op.
        #expect(EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], configReserveBytes: 2 * Self.gib,
            physicalBytes: physical) == unreserved)
        // Regime 2 — reserve ABOVE the cap-implied reserve (the DEFAULT
        // memory_reserve_gb of 4 GiB on a 32 GiB box): the effective cap
        // drops to physical − reserve = 28 GiB, the same hold-back the
        // shared KV gate and the load gate apply, so the v2 ceiling can no
        // longer advertise capacity the shared gate would reject.
        let reserved = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], configReserveBytes: 4 * Self.gib,
            physicalBytes: physical)
        #expect(reserved < unreserved)
        #expect(UInt64(reserved) == UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: UInt64(weights),
            configReserveBytes: 4 * Self.gib))
        // Exact delta: the cap shrank by (configReserve − capImplied).
        let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: physical)
        let capImplied = physical - cap
        #expect(UInt64(unreserved - reserved) == 4 * Self.gib - capImplied)
    }

    @Test("live budget clamp: a later load shrinks the REPORTED budget, never the grant")
    func liveBudgetClampTracksFleetResidency() {
        let physical = 64 * Self.gib
        let wA = Int(8 * Self.gib)
        let grantA = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: wA, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: physical)
        // Nothing changed since construction ⇒ the current answer IS the
        // grant (no spurious shrink, and never inflation past the grant).
        #expect(EngineV2KVSizing.liveEngineKVBytesBudget(
            grantedKVBytesCapacity: grantA,
            totalResidentWeightBytes: UInt64(wA),
            otherEngineKVCapacities: [], physicalBytes: physical) == grantA)
        // A 12 GiB LEGACY model loads later (subtracts nothing from any v2
        // grant): the reported budget shrinks by exactly its weights.
        let wB = 12 * Self.gib
        #expect(EngineV2KVSizing.liveEngineKVBytesBudget(
            grantedKVBytesCapacity: grantA,
            totalResidentWeightBytes: UInt64(wA) + wB,
            otherEngineKVCapacities: [], physicalBytes: physical)
            == grantA - Int(wB))
        // A co-resident v2 engine's construction grant comes off the top the
        // same way the sizing pass subtracted it.
        let grantC = Int(4 * Self.gib)
        #expect(EngineV2KVSizing.liveEngineKVBytesBudget(
            grantedKVBytesCapacity: grantA,
            totalResidentWeightBytes: UInt64(wA) + wB,
            otherEngineKVCapacities: [grantC], physicalBytes: physical)
            == grantA - Int(wB) - grantC)
        // Fleet growth past the budget clamps to 0, never negative.
        #expect(EngineV2KVSizing.liveEngineKVBytesBudget(
            grantedKVBytesCapacity: grantA,
            totalResidentWeightBytes: physical,
            otherEngineKVCapacities: [], physicalBytes: physical) == 0)
        // The clamp can only ever SHRINK the report: with fleet residency
        // BELOW construction-time reality the grant still bounds the report.
        #expect(EngineV2KVSizing.liveEngineKVBytesBudget(
            grantedKVBytesCapacity: grantA,
            totalResidentWeightBytes: 0,
            otherEngineKVCapacities: [], physicalBytes: physical) == grantA)
    }

    @Test("pure sizing: degenerate inputs clamp to zero, never trap")
    func pureSizingDegenerateInputs() {
        // Grants already exceed the budget → 0, not negative.
        #expect(EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: Int(4 * Self.gib), coResidentWeightBytes: 0,
            existingEngineKVCapacities: [Int.max, Int.max],
            physicalBytes: 16 * Self.gib) == 0)
        // Negative weight/grant inputs are treated as 0.
        #expect(EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: -1, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [-5],
            physicalBytes: 16 * Self.gib)
            == Int(UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: 16 * Self.gib, residentWeightBytes: 0)))
        // Weights alone exceed the cap → 0 budget.
        #expect(EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: Int(20 * Self.gib), coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: 16 * Self.gib) == 0)
    }

    @Test("slot factory sizes a second v2 engine against the first slot's weights and ceiling")
    func slotFactoryUsesFleetResidency() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        let recorder = CapacityRecorder()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    // The default allowlist is now the exact prod checkpoint ids;
                    // these wiring fixtures use family-glob test ids, so widen it.
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*,gpt-oss*",
                    // This test pins the PURE fleet-sizing composition; the
                    // prefix cache is dormant by default (v0.7.5) and this
                    // explicit 0 keeps it so even if the default flips again.
                    // The carve's own composition is pinned in
                    // EngineV2PrefixCacheWiringTests.
                    "DARKBLOOM_PREFIX_CACHE": "0",
                ],
                eosTokenIds: [2],
                makeEngine: { _, kvBytesCapacity in
                    recorder.record(kvBytesCapacity)
                    return CapacityReportingEngine(kvBytesCapacity: kvBytesCapacity)
                }))

        // Slot A: 1 GiB of resident weights, empty fleet.
        let weightsA = Int(1 * Self.gib)
        let schedulerA = BatchScheduler()
        await schedulerA._setModelWeightBytesForTest(weightsA)
        let bridgeA = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: schedulerA))
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            scheduler: schedulerA,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeA,
            modelType: "gemma4_text")

        // Slot B: 2 GiB of weights, loaded WITH A resident.
        let weightsB = Int(2 * Self.gib)
        let schedulerB = BatchScheduler()
        await schedulerB._setModelWeightBytesForTest(weightsB)
        _ = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: schedulerB)

        let granted = recorder.granted
        #expect(granted.count == 2)
        // A was sized alone; B's ceiling subtracts A's weights AND A's
        // construction-fixed grant — the exact fleet-aware derivation
        // (computed here with the same pure helper on this machine's
        // physical memory, so the assertion is machine-independent). The
        // loop's configured memory_reserve_gb (1 GiB in makeWiringLoop)
        // threads into the derivation too (round-3 PR#499 P2).
        #expect(granted[0] == EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weightsA, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], configReserveBytes: 1 * Self.gib))
        #expect(granted[1] == EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weightsB,
            coResidentWeightBytes: UInt64(weightsA),
            existingEngineKVCapacities: [granted[0]],
            configReserveBytes: 1 * Self.gib))
        // And the fleet invariant: B's grant never lets the pair exceed the
        // budget A was granted under.
        #expect(granted[1] <= max(0, granted[0] - weightsB))
    }

    @Test("heartbeat budget max shrinks when a second slot's weights register later (round-3 PR#499 P2)")
    func heartbeatBudgetShrinksWhenSecondSlotLoads() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        let recorder = CapacityRecorder()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    // The default allowlist is now the exact prod checkpoint ids;
                    // these wiring fixtures use family-glob test ids, so widen it.
                    "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*,gpt-oss*",
                ],
                eosTokenIds: [2],
                makeEngine: { _, kvBytesCapacity in
                    recorder.record(kvBytesCapacity)
                    // The engine reports its construction grant back in the
                    // capacity snapshot, exactly like the production engine.
                    return CapacityReportingEngine(kvBytesCapacity: kvBytesCapacity)
                }))

        // Slot A: v2-served, 1 GiB of weights, a known per-token KV rate so
        // the heartbeat derives token budgets (bytes / rate).
        let rate = 4096
        let weightsA = Int(1 * Self.gib)
        let schedulerA = BatchScheduler()
        await schedulerA._setModelWeightBytesForTest(weightsA)
        await schedulerA._setKVRatesForTest(kvBytesPerToken: rate, fp16KVBytesPerToken: rate)
        let bridgeA = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: schedulerA))
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            scheduler: schedulerA,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridgeA,
            modelType: "gemma4_text")

        func v2BudgetMax() async throws -> Int64 {
            await loop.updateAggregateCapacity()
            let capacity = try #require(await loop.backendCapacityForTesting())
            let slot = try #require(
                capacity.slots.first(where: { $0.model == "gemma-4-27b-it" }))
            return slot.activeTokenBudgetMax
        }

        // Alone on the box the heartbeat reports the construction grant.
        let grant = try #require(recorder.granted.first)
        let before = try await v2BudgetMax()
        #expect(before == Int64(grant / rate))

        // A second slot's weights register LATER — a LEGACY (non-v2) slot,
        // which subtracts nothing from A's construction-fixed ceiling. The
        // heartbeat must nonetheless reflect fleet reality: the reported max
        // shrinks by exactly the newcomer's weights (in tokens), while A's
        // engine keeps its private grant.
        let weightsB = Int(2 * Self.gib)
        let schedulerB = BatchScheduler()
        await schedulerB._setModelWeightBytesForTest(weightsB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            scheduler: schedulerB,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: nil,
            modelType: "gpt_oss")

        let after = try await v2BudgetMax()
        // weightsB is a whole multiple of the rate, so the integer-division
        // shrink is exact: wB / rate tokens.
        #expect(before - after == Int64(weightsB / rate))
        #expect(after < before)
        // The clamp is heartbeat-side only: the engine's own snapshot still
        // carries the construction grant.
        #expect(await bridgeA.engineKVBytesCapacity() == grant)
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
        // The legacy scheduler here has NO model loaded: if routing fell
        // through to it, the stream would throw "No model loaded" instead
        // of producing the scripted content below.
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-27b-it": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4_text",
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
                    "gemma-4-27b-it": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4_text",
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
                    "gemma-4-27b-it": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4_text",
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
                    scheduler: BatchScheduler(),
                    tokenizer: TokenizerHandle(WiringStubTokenizer()),
                    releaseToken: OneShotRelease(
                        release: { _ in released.increment() }, modelId: modelId),
                    modelType: "gemma4_text",
                    engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in TokenizerHandle(WiringStubTokenizer()) },
            availableModels: { ["gemma-4-27b-it"] }
        )

        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        let events = try await recordServerStream(stream)
        #expect(events.first == .content("local"))
        #expect(events.last == .info(prompt: 5, completion: 1))
        #expect(engine.submitted.count == 1)
        // The local reservation is dropped exactly once when the stream ends.
        #expect(released.calls == 1)
    }

    @Test("VLM slot with a bridge: text-only request routes through the bridge")
    func vlmSlotTextRequestRoutesThroughBridge() async throws {
        // v0.7.2 per-request routing: a VLM slot may carry a v2 bridge built
        // over its extracted text model. TEXT requests must serve through
        // the bridge exactly like a text-slot bridge would.
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine, modelId: "gemma-4-26b-8bit")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-8bit": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        container: makeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(
            request: makeOpenAIRequest(model: "gemma-4-26b-8bit"))
        let events = try await recordServerStream(stream)
        #expect(events.first == .content("Hello"))
        #expect(events.last == .info(prompt: 5, completion: 1))
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    @Test("VLM slot with a bridge: image-bearing request never reaches the bridge")
    func vlmSlotMediaRequestBypassesBridge() async throws {
        // The media check sits ABOVE the bridge branch (ordering contract in
        // MultiModelBatchSchedulerEngine.streamChatCompletion): an
        // image-bearing request on a bridge-carrying VLM slot must take the
        // legacy vision path — here it fails inside that path (stub
        // container / model-less scheduler), which is exactly the proof:
        // the scripted v2 engine must never see a submission.
        let engine = WiringScriptedEngine(script: .stream([
            .delta(text: "must-not-appear", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine, modelId: "gemma-4-26b-8bit")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-8bit": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4",
                        container: makeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })

        // A real, round-trip-verified 1x1 PNG so hasMedia + media validation
        // both engage (same fixture as VLMRequestInferenceTests).
        let tinyPNG =
            "data:image/png;base64,"
            + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
            + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
            + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
            + "AElFTkSuQmCC"
        let mediaRequest = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-8bit",
            messages: [
                OpenAIChatMessage(
                    role: .user,
                    content: .parts([
                        .text("what is this?"),
                        .imageURL(tinyPNG),
                    ]))
            ]
        )

        // The vision path errors on the stub fixtures (model-less scheduler /
        // throwing processor) — either shape proves the routing; what must
        // NOT happen is a silent success through the bridge.
        do {
            let stream = try await providerEngine.streamChatCompletion(request: mediaRequest)
            _ = try await recordServerStream(stream)
            Issue.record("media request unexpectedly succeeded on stub fixtures")
        } catch {
            // expected: legacy vision path surfaced its failure
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("no bridge: the legacy scheduler path is taken unchanged")
    func legacyPathUntouchedWithoutBridge() async throws {
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-27b-it": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4_text")
                ]
            })

        // The model-less scheduler proves the request went to the LEGACY
        // engine: it fails with its "No model loaded" error, which the v2
        // bridge could never produce.
        let stream = try await providerEngine.streamChatCompletion(request: makeOpenAIRequest())
        await #expect(throws: (any Error).self) {
            _ = try await recordServerStream(stream)
        }
    }

    @Test("cancelling the consumer cancels the engine-minted v2 request id")
    func cancellationPropagatesToBridge() async throws {
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-27b-it": .init(
                        scheduler: BatchScheduler(),
                        tokenizer: TokenizerHandle(WiringStubTokenizer()),
                        modelType: "gemma4_text",
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

// MARK: - Zero-overhead runtime guards (capacity + cancellation)

/// These tests drive the REAL `updateAggregateCapacity` / `unloadModel`
/// paths, which read MLX GPU counters — so the mlx.metallib must be
/// colocated with the test runner. CI places it under `.build` (see
/// ci.yml "Extract mlx.metallib"); locally run `./scripts/fetch-metallib.sh
/// debug` once. Mirrors the `LiveInferenceFixtures` pattern.
@Suite("EngineV2 production wiring: runtime guards", .serialized)
struct EngineV2RuntimeGuardTests {

    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("capacity + cancellation never consult the runtime without v2 slots")
    func flagOffSkipsRuntime() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        // A legacy-only slot (engineV2: nil) must not flip the guard.
        await loop.installModelSlotForTesting(
            modelId: "qwen3-8b",
            scheduler: BatchScheduler(),
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer())
        )

        #expect(await loop.hasEngineV2SlotsForTesting() == false)
        await loop.updateAggregateCapacity()
        await loop.handleCancellation(requestId: "req-legacy", receivedFromCoordinator: false)
        #expect(await runtime.consultCount == 0)
    }

    @Test("capacity folds the v2 bridge slot into the heartbeat when a v2 slot exists")
    func capacityIncludesV2Slot() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            scheduler: BatchScheduler(),
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4_text"
        )

        #expect(await loop.hasEngineV2SlotsForTesting())
        await loop.updateAggregateCapacity()
        #expect(await runtime.consultCount == 1)
        let capacity = await loop.backendCapacityForTesting()
        let v2Slot = capacity?.slots.first { $0.model == "gemma-4-27b-it" }
        #expect(v2Slot != nil)
        // The bridge slot is AUTHORITATIVE for a v2-served model: the dormant
        // legacy scheduler must not also report (its extra slot would
        // advertise the same model's capacity twice and over-admit). Exactly
        // one heartbeat slot exists — the bridge's.
        #expect(capacity?.slots.count == 1)
    }

    @Test("cancellation fans out through the runtime to the owning bridge")
    func cancellationFansOutToBridge() async throws {
        let loop = try makeWiringLoop()
        let runtime = EngineV2Runtime()
        let engine = WiringScriptedEngine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            scheduler: BatchScheduler(),
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4_text"
        )

        // Submit under the coordinator request-id (held open by the manual
        // script) so the runtime fan-out has an owner to find.
        let stream = await bridge.submit(
            request: ChatCompletionRequest(
                model: "gemma-4-27b-it",
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
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            scheduler: BatchScheduler(),
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            engineV2: bridge,
            modelType: "gemma4_text"
        )

        await loop.unloadModel("gemma-4-27b-it")
        #expect(await runtime.bridge(forModel: "gemma-4-27b-it") == nil)
        #expect(engine.shutdownCalls == 1)
        #expect(await loop.hasEngineV2SlotsForTesting() == false)
    }
}
