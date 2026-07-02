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
                makeEngine: { _ in
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
                makeEngine: { _ in
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
                environment: ["DARKBLOOM_ENGINE_V2": "1"],
                eosTokenIds: [2],
                makeEngine: { _ in engine }))

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
            case .info(let prompt, let completion, _):
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

    @Test("VLM slot: silently legacy even when flag on + name allowlisted (no WARN noise)")
    func vlmSlotStaysLegacySilently() async throws {
        let loop = try makeWiringLoop(engineV2Enabled: true)
        let runtime = EngineV2Runtime()
        let counter = BuilderCallCounter()
        let telemetry = WiringTelemetrySink()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: ["DARKBLOOM_ENGINE_V2": "1"],
                emitTelemetry: telemetry.callback(),
                makeEngine: { _ in
                    counter.increment()
                    return WiringScriptedEngine(script: .manual)
                }))

        // Name matches the gemma-4* allowlist, but the slot is a VLM — the
        // loaded module is a vision wrapper the v2 engine can never serve,
        // so this must be a SILENT legacy fallback (no per-load WARN).
        let bridge = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it-vision",
            modelType: "gemma4",
            isVLM: true,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(WiringStubTokenizer()),
            scheduler: BatchScheduler()
        )
        #expect(bridge == nil)
        #expect(counter.calls == 0)
        #expect(telemetry.events.isEmpty)
        #expect(await runtime.bridge(forModel: "gemma-4-27b-it-vision") == nil)
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
                makeEngine: { _ in throw InitFailure() }))

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
