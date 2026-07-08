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
    /// Live admission ceiling — MUTABLE so re-slice shrinks/grows land
    /// exactly as they do on the real engine (`updateKVBytesCapacity`).
    private var _kvBytesCapacity: Int

    init(script: Script) {
        self.script = script
        if case .reportCapacity(let capacity) = script {
            self._kvBytesCapacity = capacity
        } else {
            self._kvBytesCapacity = 0
        }
    }

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
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: _kvBytesCapacity, activeTokens: 0)
        }
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock { _kvBytesCapacity = max(0, bytes) }
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
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
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

/// Deterministic re-slice inputs (the same shape the unwind suite uses):
/// the hooks' `physicalMemoryBytes` pins the fleet budget, `memoryReserveGB:
/// 1` in `makeLoop` pins the reserve, so grants are machine-independent.
private let carvePhysicalBytes: UInt64 = 64 * UInt64(gib)
private let carveReserveBytes: UInt64 = 1 * UInt64(gib)

/// The slot's re-slice grant when ALONE on the box: the full fleet KV
/// budget for its weights (single-model boxes keep the whole budget).
private func rawGrant(weights: Int) -> Int {
    Int(UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: carvePhysicalBytes,
        residentWeightBytes: UInt64(max(0, weights)),
        configReserveBytes: carveReserveBytes))
}

private func makeSizing(
    weightsBytes: Int, kvRate: Int, maxContext: Int = 131_072
) -> SlotSizingSnapshot {
    SlotSizingSnapshot(
        weightsBytes: weightsBytes,
        fp16KVBytesPerToken: kvRate,
        maxContextLength: maxContext,
        defaultMaxTokens: 4096)
}

/// Hook env shared by the carve tests: cache budget pinned to 1 GiB so
/// assertions are machine-independent. The RAM tier is OPT-IN as of
/// v0.7.5, so funded-path tests must opt in explicitly — the helper's
/// default `prefixCache: "1"` models an opted-in box; pass nil to leave
/// the flag ABSENT (the fleet default). (The old `DARKBLOOM_ENGINE_V2*`
/// selection keys are gone — every slot is v2.)
private func carveEnv(
    prefixCache: String? = "1", maxGB: String? = "1", ssdTier: String? = "0"
) -> [String: String] {
    var env: [String: String] = [:]
    if let prefixCache { env["DARKBLOOM_PREFIX_CACHE"] = prefixCache }
    if let maxGB { env["DARKBLOOM_PREFIX_CACHE_MAX_GB"] = maxGB }
    // v0.7.5 SSD offload: the SSD tier is default-ON and WINS over the RAM
    // opt-in (no tier composition), so the RAM-carve tests here must kill
    // it explicitly to reach the `.ram` mode they exercise. Pass nil to
    // model a box with the SSD tier at its default.
    if let ssdTier { env["DARKBLOOM_PREFIX_CACHE_SSD"] = ssdTier }
    return env
}

// MARK: - Slot-factory carve

@Suite("EngineV2 prefix cache: slot-factory carve")
struct EngineV2PrefixCacheCarveTests {

    /// Install hooks with the given environment; every scripted engine
    /// reports the capacity it was built with and records it.
    private func installHooks(
        _ loop: ProviderLoop, environment: [String: String], recorder: GrantRecorder
    ) async {
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: environment,
                eosTokenIds: [2],
                physicalMemoryBytes: carvePhysicalBytes,
                makeEngine: { _, kv in
                    recorder.record(kv)
                    return PrefixScriptedEngine(script: .reportCapacity(kv))
                }))
    }

    /// Build a slot through the production re-slice path (the same
    /// orchestration `ensureModelLoaded` drives) and return its bridge.
    private func buildSlot(
        _ loop: ProviderLoop,
        modelId: String,
        modelType: String,
        sizing: SlotSizingSnapshot
    ) async throws -> EngineV2Bridge {
        try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: modelId,
            modelType: modelType,
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            sizing: sizing)
    }

    @Test("DEFAULT (env absent): DORMANT — no carve, full grant to live KV, zero budget")
    func defaultDormantNoCarve() async throws {
        // The v0.7.5 fleet default: DARKBLOOM_PREFIX_CACHE is ABSENT, so the
        // carve must be a passthrough — the engine is handed the raw
        // re-slice grant, the bridge carries no budget, and (production
        // path) no cache instance or stats logger would exist: the zero
        // budget pinned here is exactly what makes `makePrefixCache` return
        // nil and the stats-logger start get skipped in the slot factory.
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        // Both flags ABSENT — the true fleet default. The SSD tier is
        // default-ON but carves ZERO memory (and hooks build no production
        // cache instance), so the carve must still be a passthrough.
        await installHooks(
            loop, environment: carveEnv(prefixCache: nil, ssdTier: nil), recorder: recorder)

        let weights = 1 * gib
        let bridge = try await buildSlot(
            loop, modelId: "gpt-oss-20b", modelType: "gpt_oss",
            sizing: makeSizing(weightsBytes: weights, kvRate: 4096))

        #expect(recorder.granted == [rawGrant(weights: weights)])
        #expect(bridge.prefixCacheBudgetBytes == 0)
        #expect(await bridge.slotKVBytesClaim() == rawGrant(weights: weights))
        // The composition the production path executes on this budget:
        #expect(PrefixCachePolicy.makePrefixCache(modelId: "gpt-oss-20b", budgetBytes: 0) == nil)
    }

    @Test("explicit off (DARKBLOOM_PREFIX_CACHE=0): same dormant outcome")
    func gateOffNoCarve() async throws {
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        await installHooks(loop, environment: carveEnv(prefixCache: "0"), recorder: recorder)

        let weights = 1 * gib
        let bridge = try await buildSlot(
            loop, modelId: "gpt-oss-20b", modelType: "gpt_oss",
            sizing: makeSizing(weightsBytes: weights, kvRate: 4096))

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
        await installHooks(loop, environment: env, recorder: recorder)

        let weights = 1 * gib
        let bridge = try await buildSlot(
            loop, modelId: "gpt-oss-20b", modelType: "gpt_oss",
            sizing: makeSizing(weightsBytes: weights, kvRate: 4096))

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
        await installHooks(loop, environment: carveEnv(), recorder: recorder)

        let weights = 1 * gib
        let bridge = try await buildSlot(
            loop, modelId: "gpt-oss-20b", modelType: "gpt_oss",
            sizing: makeSizing(weightsBytes: weights, kvRate: 4096))

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
        await installHooks(loop, environment: carveEnv(), recorder: recorder)

        let rate = 4096
        let weights = 1 * gib
        let sizing = makeSizing(weightsBytes: weights, kvRate: rate)
        let bridge = try await buildSlot(
            loop, modelId: "gpt-oss-20b", modelType: "gpt_oss", sizing: sizing)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            engineV2: bridge,
            sizing: sizing,
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
        // reduction, not shrink it further and not restore it. (The clamp
        // recomputes against the hooks' pinned 64 GiB — the SAME memory
        // figure the grant arithmetic used (`updateAggregateCapacity`
        // honors `engineV2SlotHooks.physicalMemoryBytes`) — so the
        // construction grant is the binding term on any machine, CI
        // included.)
        await loop.updateAggregateCapacity()
        let capacity = try #require(await loop.backendCapacityForTesting())
        let slot = try #require(capacity.slots.first(where: { $0.model == "gpt-oss-20b" }))
        #expect(slot.activeTokenBudgetMax == Int64(reduced / rate))
    }

    @Test("co-residency re-slice: totals flow as CLAIMS — Σ(engine ceilings + cache budgets) ≤ fleet budget")
    func secondSlotResliceKeepsClaimInvariant() async throws {
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        await installHooks(loop, environment: carveEnv(), recorder: recorder)

        // Slot A: alone on the box, 1 GiB cache budget carved out of the
        // full single-model grant.
        let weightsA = 1 * gib
        let sizingA = makeSizing(weightsBytes: weightsA, kvRate: 4096)
        let bridgeA = try await buildSlot(
            loop, modelId: "gemma-4-27b-it", modelType: "gemma4_text", sizing: sizingA)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4_text")
        let rawA = rawGrant(weights: weightsA)
        #expect(await bridgeA.slotKVBytesClaim() == rawA)

        // Slot B loads with A resident: the re-slice reads A's TOTAL claim
        // (engine + cache — `slotKVBytesClaim`), computes fair-share TOTAL
        // targets for both, shrinks A (its fixed cache budget riding
        // inside), and hands B its total — which the factory carves again.
        let weightsB = 2 * gib
        let sizingB = makeSizing(weightsBytes: weightsB, kvRate: 4096)
        let bridgeB = try await buildSlot(
            loop, modelId: "gpt-oss-20b", modelType: "gpt_oss", sizing: sizingB)

        // Expected totals from the SAME pure policy the loop ran.
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: carvePhysicalBytes,
            residentWeightBytes: UInt64(weightsA + weightsB),
            configReserveBytes: carveReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(modelId: "gemma-4-27b-it", fp16KVBytesPerToken: 4096,
                      maxContextLength: 131_072)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b", fp16KVBytesPerToken: 4096,
                maxContextLength: 131_072),
            fleetKVBudgetBytes: fleetBudget)
        let targetA = try #require(targets["gemma-4-27b-it"])
        let targetB = try #require(targets["gpt-oss-20b"])

        // A: shrunk to its TOTAL target; the fixed 1 GiB cache budget is
        // netted out of the ENGINE ceiling by the bridge translation. If
        // the shrink had been applied to the bare engine ceiling instead,
        // A's claim would exceed its target by the cache budget — the
        // T-041 double-spend this test exists to prevent.
        #expect(await bridgeA.slotKVBytesClaim() == targetA)
        #expect(await bridgeA.engineKVBytesCapacity() == targetA - 1 * gib)
        // B: its total was carved by the factory (cache funded again).
        let carveB = PrefixCachePolicy.carve(
            slotKVBytesCapacity: targetB, requestedBudgetBytes: 1 * gib,
            kvBytesPerToken: 4096)
        #expect(recorder.granted.last == carveB.engineKVBytesCapacity)
        #expect(await bridgeB.slotKVBytesClaim() == targetB)

        // THE INVARIANT (T-041 × re-slice): Σ over slots of
        // (engine ceiling + funded cache budget) ≤ the fleet KV budget.
        let claimSum = await bridgeA.slotKVBytesClaim() + bridgeB.slotKVBytesClaim()
        #expect(UInt64(claimSum) <= fleetBudget)
    }

    @Test("failed-load unwind with a CARVED survivor: restore lands on the claim, Σ ≤ budget throughout")
    func carvedSurvivorRestoredAfterFailedLoad() async throws {
        struct BFailure: Error {}
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        let recorder = GrantRecorder()
        await installHooks(loop, environment: carveEnv(), recorder: recorder)

        // A alone, carved: claim = full grant, engine = grant − 1 GiB.
        let weightsA = 1 * gib
        let sizingA = makeSizing(weightsBytes: weightsA, kvRate: 4096)
        let bridgeA = try await buildSlot(
            loop, modelId: "gemma-4-27b-it", modelType: "gemma4_text", sizing: sizingA)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-27b-it",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4_text")
        let rawA = rawGrant(weights: weightsA)
        let engineA0 = await bridgeA.engineKVBytesCapacity()
        #expect(engineA0 == rawA - 1 * gib)

        // B's engine build fails AFTER A was shrunk: the restore must land
        // A back on its exact previous TOTAL claim — engine ceiling back to
        // claim − cache budget, never claim itself (which would leak the
        // cache's bytes into live KV and push Σ past the budget).
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                environment: carveEnv(),
                eosTokenIds: [2],
                physicalMemoryBytes: carvePhysicalBytes,
                makeEngine: { _, _ in throw BFailure() }))
        await #expect(throws: BFailure.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: "gpt-oss-20b",
                modelType: "gpt_oss",
                container: makeStubContainer(),
                tokenizer: TokenizerHandle(PrefixStubTokenizer()),
                sizing: makeSizing(weightsBytes: 2 * gib, kvRate: 4096))
        }

        #expect(await bridgeA.slotKVBytesClaim() == rawA)
        #expect(await bridgeA.engineKVBytesCapacity() == engineA0)
        #expect(UInt64(await bridgeA.slotKVBytesClaim())
            <= UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: carvePhysicalBytes,
                residentWeightBytes: UInt64(weightsA),
                configReserveBytes: carveReserveBytes))
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
