// Copyright © 2026 Eigen Labs.
//
// Provider-side wiring tests for the v0.7.5 v2 prefix cache (T-041):
//
//   * the slot factory's CARVE — `DARKBLOOM_PREFIX_CACHE` gate +
//     `DARKBLOOM_PREFIX_CACHE_MAX_GB` budget split out of the fleet-sized
//     KV grant, with the reduced capacity handed to the engine;
//   * the capacity-reduction AGREEMENT — engine snapshot, bridge budget
//     bookkeeping, and heartbeat `activeTokenBudgetMax` all reflect the
//     SAME reduced figure (the coordinator is never told about bytes the
//     cache will consume);
//   * co-residency accounting — a later slot is sized against the earlier
//     slot's TOTAL claim (engine ceiling + cache budget);
//   * per-request `cacheScope` → `CBv2Request.cacheSalt` plumbing through
//     the bridge (distinct scopes ⇒ distinct salts; same scope ⇒ stable
//     salt; "" ⇒ nil) — cross-scope non-reuse itself is engine-tested
//     upstream (CBv2EndToEndTests);
//   * the out-of-band usage signal (`prefixCacheHitTokens`) and the
//     `cached_tokens` SSE splice.
//
// Live-isolated style: scripted engines, stub tokenizer/container, no
// weights, no network (same shape as EngineV2ProductionWiringTests).

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Stubs (private copies of the wiring-test fixtures)

private final class PrefixScriptedEngine: CBv2Engine, @unchecked Sendable {
    enum Script {
        case stream([CBv2Event])
        case reportCapacity(Int)
    }

    private let lock = NSLock()
    private let script: Script
    private var _submitted: [CBv2Request] = []

    init(script: Script) { self.script = script }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { _submitted.append(request) }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        if case .stream(let events) = script {
            for event in events { continuation.yield(event) }
        }
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        let kv: Int
        if case .reportCapacity(let capacity) = script { kv = capacity } else { kv = 0 }
        return CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: kv, activeTokens: 0)
    }

    func shutdown() async {}
}

private struct PrefixStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
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
    ) throws -> [Int] { [1, 2, 3, 4, 5] }
}

private final class PrefixStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct PrefixStubProcessor: UserInputProcessor {
    struct Unsupported: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unsupported() }
}

private func makeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: PrefixStubLanguageModel(),
            processor: PrefixStubProcessor(),
            tokenizer: PrefixStubTokenizer()
        ))
}

private func makeLoop() throws -> ProviderLoop {
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
            provider: ProviderSettings(name: "prefix-cache-wiring-test", memoryReserveGB: 1),
            backend: BackendSettings(
                continuousBatching: true, idleTimeoutMins: 0, maxModelSlots: 2,
                engineV2: true),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

/// Thread-safe recorder for the kvBytesCapacity values handed to the hooks.
private final class GrantRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _granted: [Int] = []
    var granted: [Int] { lock.withLock { _granted } }
    func record(_ capacity: Int) { lock.withLock { _granted.append(capacity) } }
}

private let gib = 1_073_741_824

/// Hook env shared by the carve tests: v2 forced on, family globs widened,
/// cache budget pinned to 1 GiB so assertions are machine-independent.
private func carveEnv(prefixCache: String? = nil, maxGB: String? = "1") -> [String: String] {
    var env = [
        "DARKBLOOM_ENGINE_V2": "1",
        "DARKBLOOM_ENGINE_V2_MODELS": "gemma-4*,gpt-oss*",
    ]
    if let prefixCache { env["DARKBLOOM_PREFIX_CACHE"] = prefixCache }
    if let maxGB { env["DARKBLOOM_PREFIX_CACHE_MAX_GB"] = maxGB }
    return env
}

// MARK: - Slot-factory carve

@Suite("EngineV2 prefix cache: slot-factory carve")
struct EngineV2PrefixCacheCarveTests {

    /// The raw (pre-carve) grant the sizing pass computes for a fresh slot
    /// on THIS machine, mirroring the slot factory's derivation.
    private func rawGrant(weights: Int) -> Int {
        EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], configReserveBytes: UInt64(1 * gib))
    }

    @Test("gate off (DARKBLOOM_PREFIX_CACHE=0): no carve, zero budget on the bridge")
    func gateOffNoCarve() async throws {
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: carveEnv(prefixCache: "0"),
                eosTokenIds: [2],
                makeEngine: { _, kv in
                    recorder.record(kv)
                    return PrefixScriptedEngine(script: .reportCapacity(kv))
                }))

        let weights = 1 * gib
        let scheduler = BatchScheduler()
        await scheduler._setModelWeightBytesForTest(weights)
        await scheduler._setKVRatesForTest(kvBytesPerToken: 4096, fp16KVBytesPerToken: 4096)
        let bridge = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            scheduler: scheduler))

        #expect(recorder.granted == [rawGrant(weights: weights)])
        #expect(bridge.prefixCacheBudgetBytes == 0)
    }

    @Test("funding gate: threshold 0 (never fund) leaves the full grant with live KV")
    func fundingThresholdZeroUnfunded() async throws {
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        var env = carveEnv()  // master gate ON, 1 GiB budget available
        env["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS"] = "0"
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: env,
                eosTokenIds: [2],
                makeEngine: { _, kv in
                    recorder.record(kv)
                    return PrefixScriptedEngine(script: .reportCapacity(kv))
                }))

        let weights = 1 * gib
        let scheduler = BatchScheduler()
        await scheduler._setModelWeightBytesForTest(weights)
        await scheduler._setKVRatesForTest(kvBytesPerToken: 4096, fp16KVBytesPerToken: 4096)
        let bridge = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            scheduler: scheduler))

        // Unfunded through the SLOT FACTORY: engine handed the raw grant,
        // no budget on the bridge, claim == engine capacity.
        #expect(recorder.granted == [rawGrant(weights: weights)])
        #expect(bridge.prefixCacheBudgetBytes == 0)
        #expect(await bridge.slotKVBytesClaim() == rawGrant(weights: weights))
    }

    @Test("factory adoption-bound resolver: unknown model families report 0 (fundable)")
    func factoryAdoptionBoundUnknownModel() {
        // Only Gemma4TextModel/GPTOSSModel carry CBv2 layer kinds; anything
        // else is bound-0 by policy (documented: such models throw
        // unsupportedModel at engine build before a cache could matter).
        #expect(EngineV2Factory.adoptionBoundTokens(model: PrefixStubLanguageModel()) == 0)
    }

    @Test("gate on: the engine is handed the grant MINUS the funded budget")
    func carveReducesEngineCapacity() async throws {
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: carveEnv(),  // default-on gate, 1 GiB budget
                eosTokenIds: [2],
                makeEngine: { _, kv in
                    recorder.record(kv)
                    return PrefixScriptedEngine(script: .reportCapacity(kv))
                }))

        let weights = 1 * gib
        let scheduler = BatchScheduler()
        await scheduler._setModelWeightBytesForTest(weights)
        await scheduler._setKVRatesForTest(kvBytesPerToken: 4096, fp16KVBytesPerToken: 4096)
        let bridge = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            scheduler: scheduler))

        let raw = rawGrant(weights: weights)
        // Exact composition through the policy the factory uses.
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: raw, requestedBudgetBytes: 1 * gib, kvBytesPerToken: 4096)
        #expect(carve.prefixCacheBudgetBytes == 1 * gib)
        #expect(recorder.granted == [carve.engineKVBytesCapacity])
        #expect(recorder.granted == [raw - 1 * gib])
        #expect(bridge.prefixCacheBudgetBytes == 1 * gib)
        // Conservation: nothing lost, nothing invented.
        #expect(await bridge.slotKVBytesClaim() == raw)
    }

    @Test("agreement: engine snapshot, bridge bookkeeping, and heartbeat budget all reflect the reduction")
    func capacityReductionAgreement() async throws {
        // `updateAggregateCapacity` samples MLX.GPU memory gauges, which
        // initializes Metal — colocate the metallib next to the test bundle
        // (same bootstrap the live suites use; scripts/fetch-metallib.sh
        // must have run once).
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let loop = try makeLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        let recorder = GrantRecorder()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: carveEnv(),
                eosTokenIds: [2],
                makeEngine: { _, kv in
                    recorder.record(kv)
                    return PrefixScriptedEngine(script: .reportCapacity(kv))
                }))

        let rate = 4096
        let weights = 1 * gib
        let scheduler = BatchScheduler()
        await scheduler._setModelWeightBytesForTest(weights)
        await scheduler._setKVRatesForTest(kvBytesPerToken: rate, fp16KVBytesPerToken: rate)
        let bridge = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            scheduler: scheduler))
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            scheduler: scheduler,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            engineV2: bridge,
            modelType: "gpt_oss")

        let raw = rawGrant(weights: weights)
        let reduced = raw - 1 * gib

        // (1) Engine truth: the admission ceiling IS the reduced figure.
        #expect(await bridge.engineKVBytesCapacity() == reduced)
        // (2) Bridge bookkeeping: budget + claim reconstruct the raw grant.
        #expect(bridge.prefixCacheBudgetBytes == 1 * gib)
        #expect(await bridge.slotKVBytesClaim() == raw)
        // (3) Heartbeat: activeTokenBudgetMax reports the REDUCED capacity
        // in tokens — the live clamp (which subtracts the slot's own cache
        // budget from fleet reality) must agree with the construction
        // reduction, not shrink it further and not restore it.
        await loop.updateAggregateCapacity()
        let capacity = try #require(await loop.backendCapacityForTesting())
        let slot = try #require(capacity.slots.first(where: { $0.model == "gpt-oss-20b" }))
        #expect(slot.activeTokenBudgetMax == Int64(reduced / rate))
    }

    @Test("co-residency: a later slot is sized against the earlier slot's TOTAL claim (engine + cache)")
    func secondSlotSubtractsFullClaim() async throws {
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: carveEnv(),
                eosTokenIds: [2],
                makeEngine: { _, kv in
                    recorder.record(kv)
                    return PrefixScriptedEngine(script: .reportCapacity(kv))
                }))

        // Slot A: 1 GiB weights, 1 GiB cache budget carved.
        let weightsA = 1 * gib
        let schedulerA = BatchScheduler()
        await schedulerA._setModelWeightBytesForTest(weightsA)
        await schedulerA._setKVRatesForTest(kvBytesPerToken: 4096, fp16KVBytesPerToken: 4096)
        let bridgeA = try #require(await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gemma-4-27b-it",
            modelType: "gemma4_text",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            scheduler: schedulerA))
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            scheduler: schedulerA,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            engineV2: bridgeA,
            modelType: "gemma4_text")

        // Slot B loads with A resident.
        let weightsB = 2 * gib
        let schedulerB = BatchScheduler()
        await schedulerB._setModelWeightBytesForTest(weightsB)
        await schedulerB._setKVRatesForTest(kvBytesPerToken: 4096, fp16KVBytesPerToken: 4096)
        _ = await loop.makeEngineV2BridgeForSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            scheduler: schedulerB)

        let granted = recorder.granted
        #expect(granted.count == 2)
        let claimA = granted[0] + bridgeA.prefixCacheBudgetBytes
        // B's raw grant subtracts A's weights AND A's TOTAL claim — if only
        // A's (reduced) engine ceiling were subtracted, the bytes A's cache
        // pins would be granted to B (the T-041 double-spend this test
        // exists to prevent). The carve then splits B's raw grant again.
        let rawB = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weightsB,
            coResidentWeightBytes: UInt64(weightsA),
            existingEngineKVCapacities: [claimA],
            configReserveBytes: UInt64(1 * gib))
        let carveB = PrefixCachePolicy.carve(
            slotKVBytesCapacity: rawB, requestedBudgetBytes: 1 * gib, kvBytesPerToken: 4096)
        #expect(granted[1] == carveB.engineKVBytesCapacity)
    }
}

// MARK: - Salt plumbing (cacheScope → CBv2Request.cacheSalt)

@Suite("EngineV2 prefix cache: salt plumbing")
struct EngineV2PrefixCacheSaltTests {

    private func makeBridge(engine: PrefixScriptedEngine) -> EngineV2Bridge {
        EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            eosTokenIds: [2])
    }

    private func drain(_ stream: AsyncStream<GenerationEvent>) async {
        for await _ in stream {}
    }

    @Test("distinct scopes ⇒ distinct salts; same scope ⇒ stable salt; empty ⇒ nil")
    func saltScoping() async throws {
        let engine = PrefixScriptedEngine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        let request = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")])

        // The exact scope derivation the inference handler applies to
        // prompt_cache_key / user (SHA-256 → hex).
        let scopeA = ChatCompletionRequest.scopeHash("tenant-key-A")
        let scopeB = ChatCompletionRequest.scopeHash("tenant-key-B")
        #expect(scopeA != scopeB, "distinct keys must produce distinct scopes")
        #expect(scopeA == ChatCompletionRequest.scopeHash("tenant-key-A"), "scope is stable")

        for (id, scope) in [("r1", scopeA), ("r2", scopeA), ("r3", scopeB), ("r4", "")] {
            await drain(await bridge.submitTokenized(
                promptTokens: [1, 2, 3], request: request, requestId: id, cacheScope: scope))
        }

        let salts = engine.submitted.map(\.cacheSalt)
        #expect(salts.count == 4)
        // Same scope ⇒ byte-identical salt (stable across submissions).
        #expect(salts[0] == salts[1])
        #expect(salts[0] == scopeA)
        // Different scope ⇒ different salt (cross-scope reuse impossible —
        // the engine folds the salt into the first block hash; upstream
        // CBv2EndToEndTests prove the non-reuse itself).
        #expect(salts[2] == scopeB)
        #expect(salts[0] != salts[2])
        // Unscoped ⇒ nil (cache-level namespace, pre-salt hash vectors).
        #expect(salts[3] == nil)
    }
}

// MARK: - Usage signal + cached_tokens splice

@Suite("EngineV2 prefix cache: usage detail")
struct EngineV2PrefixCacheUsageTests {

    @Test("bridge records prefixCacheHitTokens into the per-request signal at the terminal")
    func usageSignalRecords() async throws {
        let engine = PrefixScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 300, completionTokens: 1, prefixCacheHitTokens: 256)),
        ]))
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            eosTokenIds: [2])
        let signal = EngineV2RequestUsageSignal()
        #expect(signal.prefixCacheHitTokens == nil, "unset until the terminal")

        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 300),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-usage",
            usageSignal: signal)
        for await _ in stream {}

        #expect(signal.prefixCacheHitTokens == 256)
    }

    @Test("injectCachedTokens: splices prompt_tokens_details into a usage frame, merge-not-clobber")
    func injectCachedTokens() throws {
        let usageFrame = """
            data: {"id":"c1","choices":[],"usage":{"prompt_tokens":300,"completion_tokens":9,"completion_tokens_details":{"reasoning_tokens":4}}}

            """
        let out = ProviderLoop.injectCachedTokens(into: usageFrame, cachedTokens: 256)
        let payload = try #require(out.split(separator: "\n").first?
            .replacingOccurrences(of: "data: ", with: ""))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let usage = try #require(obj["usage"] as? [String: Any])
        let details = try #require(usage["prompt_tokens_details"] as? [String: Any])
        #expect(details["cached_tokens"] as? Int == 256)
        // Neighbors untouched (counts + the reasoning splice's object).
        #expect(usage["prompt_tokens"] as? Int == 300)
        #expect(usage["completion_tokens"] as? Int == 9)
        let completionDetails = try #require(usage["completion_tokens_details"] as? [String: Any])
        #expect(completionDetails["reasoning_tokens"] as? Int == 4)
    }

    @Test("injectCachedTokens: merges into an existing prompt_tokens_details object")
    func injectMergesExistingDetails() throws {
        let frame = """
            data: {"usage":{"prompt_tokens":10,"prompt_tokens_details":{"audio_tokens":3}}}

            """
        let out = ProviderLoop.injectCachedTokens(into: frame, cachedTokens: 8)
        let payload = try #require(out.split(separator: "\n").first?
            .replacingOccurrences(of: "data: ", with: ""))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let details = try #require(
            (obj["usage"] as? [String: Any])?["prompt_tokens_details"] as? [String: Any])
        #expect(details["cached_tokens"] as? Int == 8)
        #expect(details["audio_tokens"] as? Int == 3, "existing detail keys survive")
    }

    @Test("injectCachedTokens: non-usage frames and zero hits pass through untouched")
    func injectPassThrough() {
        let contentFrame = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
        #expect(ProviderLoop.injectCachedTokens(into: contentFrame, cachedTokens: 5)
            == contentFrame)
        let done = "data: [DONE]\n\n"
        #expect(ProviderLoop.injectCachedTokens(into: done, cachedTokens: 5) == done)
        let usageFrame = "data: {\"usage\":{\"prompt_tokens\":10}}\n\n"
        #expect(ProviderLoop.injectCachedTokens(into: usageFrame, cachedTokens: 0) == usageFrame)
    }
}
