// Copyright © 2026 Eigen Labs.
//
// Shared scripted EngineV2 bridge fixtures for focused unit-test suites.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon

@testable import ProviderCore

// MARK: - Scripted CBv2Engine stub

/// In-process scripted engine. Thread-safe via NSLock so the bridge actor
/// and the test can both touch it.
final class ScriptedCBv2Engine: CBv2Engine, @unchecked Sendable {
    enum Script {
        /// Throw from `submit` (admission failure).
        case throwOnSubmit(any Error)
        /// Yield these events, then finish the stream. Include a
        /// `.finished` event for a normal terminal; omit it to simulate an
        /// engine teardown mid-request.
        case stream([CBv2Event])
        /// The test drives the event continuation by hand.
        case manual
    }

    private let lock = NSLock()
    private var script: Script
    private var _submitted: [CBv2Request] = []
    private var _cancelled: [CBv2RequestID] = []
    private var _shutdownCalls = 0
    /// ALL manual continuations, in submit order — retained so an earlier
    /// request's event stream is not torn down (continuation deinit ⇒
    /// stream finish) when a later manual submit arrives.
    private var _manualContinuations: [AsyncStream<CBv2Event>.Continuation] = []
    var capacitySnapshot: CBv2CapacitySnapshot

    init(
        script: Script,
        capacity: CBv2CapacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0
        )
    ) {
        self.script = script
        self.capacitySnapshot = capacity
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }
    var manualContinuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { _manualContinuations.last }
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
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
            return stream
        case .manual:
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            lock.withLock { _manualContinuations.append(continuation) }
            return stream
        }
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { _cancelled.append(id) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock { capacitySnapshot }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            capacitySnapshot.kvBytesCapacity = max(0, bytes)
        }
    }

    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

// MARK: - Stub tokenizer

/// Fixed-output tokenizer: `applyChatTemplate` always yields
/// `templateTokens`; EOS resolves via the token table.
struct StubTokenizer: MLXLMCommon.Tokenizer {
    var templateTokens: [Int] = [1, 2, 3, 4, 5]
    var tokenTable: [String: Int] = ["</s>": 2, "<|eot|>": 7]
    var eosTokenString: String? = "</s>"
    var failTemplate = false

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
    /// Deterministic per-id text ("t<id>") so logprob-entry conversion
    /// (token string + UTF-8 bytes) is assertable.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { tokenTable[token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { eosTokenString }
    var unknownToken: String? { nil }

    struct TemplateError: Error {}

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        if failTemplate { throw TemplateError() }
        return templateTokens
    }
}

// MARK: - Telemetry capture

final class TelemetrySink: @unchecked Sendable {
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

// MARK: - Stream recording (fixture comparison shape)

/// Normalized event shape for fixture comparison. TPS is wall-clock
/// dependent so it is recorded separately, not part of the fixture.
enum RecordedEvent: Equatable, CustomStringConvertible {
    case chunk(String)
    case info(prompt: Int, completion: Int)
    case error(String)
    case terminal(cause: InferenceTerminalCause, prompt: Int, completion: Int)

    var description: String {
        switch self {
        case .chunk(let s): return "chunk(\(s))"
        case .info(let p, let c): return "info(\(p),\(c))"
        case .error(let m): return "error(\(m))"
        case .terminal(let cause, let p, let c):
            return "terminal(\(cause.rawValue),\(p),\(c))"
        }
    }
}

func record(
    _ stream: AsyncStream<GenerationEvent>
) async -> (events: [RecordedEvent], tps: [Double]) {
    var events: [RecordedEvent] = []
    var tps: [Double] = []
    for await event in stream {
        switch event {
        case .chunk(let text):
            events.append(.chunk(text))
        case .info(let prompt, let completion, let tokensPerSecond, _):
            events.append(.info(prompt: prompt, completion: completion))
            tps.append(tokensPerSecond)
        case .error(let message):
            events.append(.error(message))
        case .terminal(let cause, _, let prompt, let completion):
            events.append(.terminal(cause: cause, prompt: prompt, completion: completion))
        }
    }
    return (events, tps)
}

func waitForBudgetRelease(
    _ budget: GlobalKVCacheBudget,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while await budget.outstandingReservedBytes() != 0 {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

// MARK: - Shared builders

func makeBridge(
    engine: any CBv2Engine,
    tokenizer: StubTokenizer = StubTokenizer(),
    modelId: String = "gemma-4-27b-it",
    eosTokenIds: Set<Int> = [2],
    extraEOSTokens: [String] = [],
    defaultMaxTokens: Int = 4096,
    kvBytesPerToken: Int = 0,
    fixedRequestBytes: Int = 0,
    auxiliaryBytesPerToken: Int = 0,
    auxiliaryTokenGranularity: Int = 1,
    auxiliaryTokenAllocationPadding: Int = 0,
    kvBudget: GlobalKVCacheBudget? = nil,
    ssdPrefixCache: SSDPrefixCache? = nil,
    kvBackendKind: EngineV2KVBackendKind = .contiguous,
    telemetry: TelemetrySink? = nil
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(tokenizer),
        eosTokenIds: eosTokenIds,
        extraEOSTokens: extraEOSTokens,
        defaultMaxTokens: defaultMaxTokens,
        maxConcurrentRequests: 4,
        kvBytesPerToken: kvBytesPerToken,
        fixedRequestBytes: fixedRequestBytes,
        auxiliaryBytesPerToken: auxiliaryBytesPerToken,
        auxiliaryTokenGranularity: auxiliaryTokenGranularity,
        auxiliaryTokenAllocationPadding: auxiliaryTokenAllocationPadding,
        kvBudget: kvBudget,
        ssdPrefixCache: ssdPrefixCache,
        kvBackendKind: kvBackendKind,
        emitTelemetry: telemetry?.callback()
    )
}

func makeRequest(
    temperature: Float? = nil,
    topP: Float? = nil,
    topK: Int? = nil,
    maxTokens: Int? = nil,
    repetitionPenalty: Float? = nil,
    presencePenalty: Float? = nil,
    frequencyPenalty: Float? = nil,
    stop: StopSequences? = nil,
    seed: UInt64? = nil,
    user: String? = nil,
    promptCacheKey: String? = nil,
    logitBias: [String: Float]? = nil,
    logprobs: Bool? = nil,
    topLogprobs: Int? = nil
) -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: "gemma-4-27b-it",
        messages: [ChatMessage(role: "user", content: "hi")],
        temperature: temperature,
        top_p: topP,
        top_k: topK,
        max_tokens: maxTokens,
        repetition_penalty: repetitionPenalty,
        presence_penalty: presencePenalty,
        frequency_penalty: frequencyPenalty,
        stop: stop,
        seed: seed,
        user: user,
        prompt_cache_key: promptCacheKey,
        logit_bias: logitBias,
        logprobs: logprobs,
        top_logprobs: topLogprobs
    )
}

func makeBridgeStagedCache(
    parent: URL,
    budget: GlobalKVCacheBudget
) async throws -> (cache: SSDPrefixCache, prompt: [Int]) {
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let root = parent.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
    try SSDBlockStore.prepareModelRoot(dedicatedRoot: parent, modelRoot: root)
    let layerKinds = [
        CBv2LayerKind(attention: .full, headDim: 4, kvHeads: 1, queryHeads: 1)
    ]
    let cache = SSDPrefixCache(
        config: .init(
            modelId: "bridge-stage-model",
            promptContractID: "bridge-stage-contract",
            weightHash: "bridge-stage-weight",
            blockSize: 8,
            adoptionBoundTokens: 0,
            nominalFullKVBytesPerToken: 16,
            layoutEpoch: SSDBlockStore.layoutEpoch(blockSize: 8, layerKinds: layerKinds),
            root: root,
            dedicatedRoot: parent,
            ttlSeconds: 900,
            minEffectiveTokens: 8,
            maxStageBytes: 1 << 20,
            maxStageMillis: 10_000,
            nowSeconds: { 10_000 }),
        kekKey: SymmetricKey(size: .bits256),
        kvBudget: budget,
        diskBudget: SSDDiskBudget(),
        maxWriteBytesPerDay: 0,
        diskBudgetBytes: { 1 << 20 })
    let tokenCount = 64
    let shape = [1, 1, tokenCount, 4]
    let keys = MLXArray(0 ..< shape.reduce(1, *)).reshaped(shape).asType(.float16)
    let values = keys + 1
    eval(keys, values)
    cache.donate(
        tokens: Array(0 ..< tokenCount),
        snapshots: [(keys: keys, values: values, offset: tokenCount)],
        layerKinds: layerKinds,
        cacheSalt: "scope")
    await cache.waitForWritesForTesting()
    guard cache.index.count == 8 else {
        cache.close()
        throw BridgeFixtureError.cacheDidNotPersist
    }
    return (cache, Array(0 ..< tokenCount) + [999])
}

enum BridgeFixtureError: Error {
    case cacheDidNotPersist
}

/// Deterministic shared budgets driven by SCRIPTED memory snapshots (never
/// the real machine's memory) — live-isolated per the testing rules.
enum TestBudgets {
    /// A budget with plenty of headroom: 8 GiB box, nothing used.
    /// Effective cap = min(0.9 × 8 GiB, 8 GiB − 2 GiB) = 6 GiB.
    static func ample() -> GlobalKVCacheBudget {
        let gib: UInt64 = 1024 * 1024 * 1024
        return GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(total: 8 * gib, active: 0, cache: 0, systemAvailable: 8 * gib)
            })
    }

    /// A budget with ZERO headroom: everything under the cap already used.
    static func exhausted() -> GlobalKVCacheBudget {
        let gib: UInt64 = 1024 * 1024 * 1024
        return GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(total: 8 * gib, active: 8 * gib, cache: 0, systemAvailable: 0)
            })
    }
}
