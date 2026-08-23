// Copyright © 2026 Eigen Labs.
//
// Shared deterministic fixtures for focused EngineV2 production-wiring tests.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore
// MARK: - Scripted CBv2Engine stub (same shape as EngineV2BridgeTests)

final class ProductionWiringScriptedEngine: CBv2Engine, @unchecked Sendable {
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

struct ProductionWiringStubTokenizer: MLXLMCommon.Tokenizer {
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
final class ProductionWiringStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

struct ProductionWiringStubProcessorError: Error {}

struct ProductionWiringStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw ProductionWiringStubProcessorError()
    }
}

func productionMakeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: ProductionWiringStubLanguageModel(),
            processor: ProductionWiringStubProcessor(),
            tokenizer: ProductionWiringStubTokenizer()
        ))
}

// MARK: - Telemetry capture

final class ProductionWiringTelemetrySink: @unchecked Sendable {
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

final class ProductionBuilderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func increment() { lock.withLock { _calls += 1 } }
}

/// Thread-safe recorder for the kvBytesCapacity grants handed to the hooks.
final class ProductionGrantRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _granted: [Int] = []
    var granted: [Int] { lock.withLock { _granted } }
    func record(_ capacity: Int) { lock.withLock { _granted.append(capacity) } }
}

// MARK: - Shared builders

let productionWiringGiB: UInt64 = 1024 * 1024 * 1024
/// Deterministic machine memory for every re-slice in this file.
let productionWiringPhysicalBytes: UInt64 = 64 * productionWiringGiB
/// makeWiringLoop's configured reserve (memory_reserve_gb = 1).
let productionWiringReserveBytes: UInt64 = 1 * productionWiringGiB

func productionMakeWiringLoop(
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

func productionMakeBridge(
    engine: ProductionWiringScriptedEngine,
    modelId: String = "gemma-4-26b-qat-4bit",
    kvBytesPerToken: Int = 0,
    kvBackendKind: EngineV2KVBackendKind = .contiguous
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
        eosTokenIds: [2],
        kvBytesPerToken: kvBytesPerToken,
        kvBackendKind: kvBackendKind
    )
}

func productionMakeConstraintVerifiedWiringTokenizer() -> TokenizerHandle {
    TokenizerHandle(
        ProductionWiringStubTokenizer(),
        toolConstraintContractVerified: true)
}

func productionMakeSizing(
    weightsGiB: UInt64, kvRate: Int = 20_480, maxContext: Int = 131_072
) -> SlotSizingSnapshot {
    SlotSizingSnapshot(
        weightsBytes: Int(weightsGiB * productionWiringGiB),
        fp16KVBytesPerToken: kvRate,
        maxContextLength: maxContext,
        defaultMaxTokens: 4096)
}

func productionMakeOpenAIRequest(model: String = "gemma-4-26b-qat-4bit") -> OpenAIChatCompletionRequest {
    OpenAIChatCompletionRequest(
        model: model,
        messages: [OpenAIChatMessage(role: .user, content: .text("hi"))]
    )
}

/// Collect a server-engine event stream into a comparable shape.
enum ProductionRecordedServerEvent: Equatable {
    case content(String)
    case info(prompt: Int, completion: Int)
}

func productionRecordServerStream(
    _ stream: AsyncThrowingStream<MLXServerGenerationEvent, Error>
) async throws -> [ProductionRecordedServerEvent] {
    var events: [ProductionRecordedServerEvent] = []
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

    /// Install slot A via the real build path, returning its engine + the
    /// grants recorder.
    func productionBuildAndInstallSlotA(
        _ loop: ProviderLoop, runtime: EngineV2Runtime, recorder: ProductionGrantRecorder,
        engines: @escaping @Sendable (String, Int) -> ProductionWiringScriptedEngine
    ) async throws -> (bridge: EngineV2Bridge, engine: ProductionWiringScriptedEngine, sizing: SlotSizingSnapshot) {
        let enginesBox = ProductionEngineBox()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: productionWiringPhysicalBytes,
                makeEngine: { modelId, grant in
                    recorder.record(grant)
                    let engine = engines(modelId, grant)
                    enginesBox.append(engine)
                    return engine
                }))
        let sizingA = productionMakeSizing(weightsGiB: 15, kvRate: 20_480, maxContext: 262_144)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            sizing: sizingA
        )
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        return (bridgeA, enginesBox.all[0], sizingA)
    }

    final class ProductionEngineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _engines: [ProductionWiringScriptedEngine] = []
        var all: [ProductionWiringScriptedEngine] { lock.withLock { _engines } }
        func append(_ engine: ProductionWiringScriptedEngine) { lock.withLock { _engines.append(engine) } }
    }
    func productionHeartbeatSlot(
        kind: EngineV2KVBackendKind,
        fallbackReason: String?
    ) async throws -> BackendSlotCapacity {
        let bridge = try EngineV2Factory.makeBridge(
            modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
            eosTokenIds: [2],
            makeEngine: {
                EngineV2Factory.ProductionBuild(
                    engine: ProductionWiringScriptedEngine(script: .manual),
                    fixedRequestBytes: 0,
                    kvBackendKind: kind,
                    kvBackendFallbackReason: fallbackReason)
            })
        return await bridge.backendSlotCapacity()
    }
