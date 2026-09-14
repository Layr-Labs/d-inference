// Copyright © 2026 Eigen Labs.
//
// Failure-unwind ORDERING regression tests (Codex review, v0.7.5):
// when a model B's load fails AFTER co-resident engines were shrunk —
// either at engine construction or at the post-bridge headroom guard —
// the newcomer's weights must stop being resident BEFORE survivor grants
// are restored/regrown. The old ordering restored first, leaving a window
// where Σ(engine grants) exceeded the true fleet budget while B's
// container was still retained (heartbeat/admission could transiently
// over-advertise — the gray-box class; the shared GlobalKVCacheBudget
// still gated real reservations, so this was over-ADVERTISING, not OOM).
//
// Observation seam: B's container is owned by an `EngineV2NewcomerBox`
// (exactly how `ensureModelLoaded` now holds it); the tests keep only a
// WEAK reference and record, at the instant each survivor-grant update
// lands on the engine, whether B's container was still alive. With the
// fix the restore/regrow updates observe a dead container; with the old
// ordering they observe a live one (verified failing before the fix).

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Probe engine (records grant updates + a caller-supplied probe)

private final class UnwindProbeEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var _kvBytesCapacity: Int
    private var _updates: [Int] = []
    /// Called synchronously INSIDE each `updateKVBytesCapacity`, i.e. at
    /// the exact instant the grant mutation lands.
    private let onUpdate: @Sendable (Int) -> Void

    init(kvBytesCapacity: Int, onUpdate: @escaping @Sendable (Int) -> Void = { _ in }) {
        self._kvBytesCapacity = kvBytesCapacity
        self.onUpdate = onUpdate
    }

    var updates: [Int] { lock.withLock { _updates } }
    var kvBytesCapacity: Int { lock.withLock { _kvBytesCapacity } }
    private var _shutdownCalls = 0
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
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
        lock.withLock {
            _kvBytesCapacity = max(0, bytes)
            _updates.append(max(0, bytes))
        }
        onUpdate(max(0, bytes))
    }
    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

// MARK: - Weak container observation

/// Lock-guarded weak holder so @Sendable probes can ask "is B's container
/// still alive?" at grant-update time (a bare `weak var` local cannot be
/// captured in a @Sendable closure).
private final class WeakContainerRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: AnyObject?
    init(_ value: AnyObject) { self._value = value }
    var isAlive: Bool { lock.withLock { _value != nil } }
}

/// Thread-safe trail of (grantBytes, newcomerAliveAtThatInstant).
private final class AlivenessTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(bytes: Int, newcomerAlive: Bool)] = []
    func record(bytes: Int, alive: Bool) {
        lock.withLock { _entries.append((bytes, alive)) }
    }
    var entries: [(bytes: Int, newcomerAlive: Bool)] { lock.withLock { _entries } }
}

// MARK: - Minimal container fixture

private final class UnwindStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct UnwindStubProcessorError: Error {}
private struct UnwindStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw UnwindStubProcessorError()
    }
}

private func makeUnwindStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/unwind-stub"),
            model: UnwindStubLanguageModel(),
            processor: UnwindStubProcessor(),
            tokenizer: StubBridgeTokenizer()
        ))
}

// MARK: - Shared fixtures

private let unwindGiB: UInt64 = 1024 * 1024 * 1024
private let unwindPhysicalBytes: UInt64 = 64 * unwindGiB
private let unwindReserveBytes: UInt64 = 1 * unwindGiB

private func makeUnwindLoop() throws -> ProviderLoop {
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
            provider: ProviderSettings(name: "unwind-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func sizing(weightsGiB: UInt64, kvRate: Int, maxContext: Int = 131_072) -> SlotSizingSnapshot {
    SlotSizingSnapshot(
        weightsBytes: Int(weightsGiB * unwindGiB),
        fp16KVBytesPerToken: kvRate,
        maxContextLength: maxContext,
        defaultMaxTokens: 4096)
}

// MARK: - Tests

@Suite("EngineV2 failure-unwind ordering (weights released before grant restore)", .serialized)
struct EngineV2ResliceUnwindTests {

    init() {
        // The unwind paths call MLX.Memory.clearCache(), which initializes
        // the MLX device — the metallib must sit next to the test runner.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    private static let gemmaId = "gemma-4-26b-qat-4bit"
    private static let gptossId = "gpt-oss-20b"

    /// Install survivor A (probe engine at `grant`) and return its pieces.
    private func installSurvivorA(
        _ loop: ProviderLoop, runtime: EngineV2Runtime,
        grant: Int, sizingA: SlotSizingSnapshot,
        onUpdate: @escaping @Sendable (Int) -> Void
    ) async -> (bridge: EngineV2Bridge, engine: UnwindProbeEngine) {
        let engineA = UnwindProbeEngine(kvBytesCapacity: grant, onUpdate: onUpdate)
        let bridgeA = EngineV2Bridge(
            engine: engineA,
            modelId: Self.gemmaId,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            eosTokenIds: [2])
        await runtime.register(modelId: Self.gemmaId, bridge: bridgeA)
        await loop.installModelSlotForTesting(
            modelId: Self.gemmaId,
            container: makeUnwindStubContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        return (bridgeA, engineA)
    }

    @Test("build failure: B's weights are dead BEFORE A's grant is restored; Σ ≤ true budget throughout")
    func buildFailureReleasesWeightsBeforeRestore() async throws {
        struct BFailure: Error {}
        let loop = try makeUnwindLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)

        let sizingA = sizing(weightsGiB: 15, kvRate: 20_480)
        let sizingB = sizing(weightsGiB: 12, kvRate: 24_576)
        // A holds the full single-model budget, exactly as after its load.
        let grantA0 = Int(UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: unwindPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: unwindReserveBytes))

        // B's container: the ONLY strong reference lives in the box, the
        // test keeps a weak observer (scoped `do` drops the local strong ref).
        let weakB: WeakContainerRef
        let box: EngineV2NewcomerBox
        do {
            let containerB = makeUnwindStubContainer()
            weakB = WeakContainerRef(containerB)
            box = EngineV2NewcomerBox(containerB)
        }
        #expect(weakB.isAlive)

        let trail = AlivenessTrail()
        let (bridgeA, engineA) = await installSurvivorA(
            loop, runtime: runtime, grant: grantA0, sizingA: sizingA,
            onUpdate: { bytes in trail.record(bytes: bytes, alive: weakB.isAlive) })

        // Hooks: the newcomer's engine build fails AFTER A was shrunk.
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: unwindPhysicalBytes,
                makeEngine: { _, _ in throw BFailure() }))

        await #expect(throws: BFailure.self) {
            _ = try await loop.resliceAndBuildEngineV2SlotForTesting(
                modelId: Self.gptossId,
                modelType: "gpt_oss",
                newcomer: box,
                tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: sizingB
            )
        }

        // Expected two-model shrink target (same pure policy).
        let bothBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: unwindPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: unwindReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: Self.gemmaId,
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: Self.gptossId,
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: bothBudget)
        let shrinkTarget = try #require(targets[Self.gemmaId])

        // Trail: [shrink (B resident — inherent to loading), restore].
        let entries = trail.entries
        #expect(entries.count == 2)
        #expect(entries.first?.bytes == shrinkTarget)
        #expect(entries.first?.newcomerAlive == true)
        // THE ORDERING UNDER TEST: at the instant A's grant is restored,
        // B's weights are no longer resident — so the restored grant
        // (the full single-model budget) is ≤ the TRUE fleet budget at
        // that moment (which is again the single-model budget).
        #expect(entries.last?.bytes == grantA0)
        #expect(
            entries.last?.newcomerAlive == false,
            "survivor grants must be restored only AFTER the failed newcomer's weights are released")

        // End state: box drained, A exactly restored, B never registered.
        #expect(box.container == nil)
        #expect(!weakB.isAlive)
        #expect(await bridgeA.engineKVBytesCapacity() == grantA0)
        #expect(engineA.updates == [shrinkTarget, grantA0])
        #expect(await runtime.bridge(forModel: Self.gptossId) == nil)
    }

    @Test("post-bridge-guard failure: B's weights are dead BEFORE survivors regrow")
    func postBridgeGuardUnwindReleasesWeightsBeforeRegrow() async throws {
        let loop = try makeUnwindLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)

        let sizingA = sizing(weightsGiB: 15, kvRate: 20_480)
        let sizingB = sizing(weightsGiB: 12, kvRate: 24_576)
        let grantA0 = Int(UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: unwindPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: unwindReserveBytes))
        let bothBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: unwindPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: unwindReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: Self.gemmaId,
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: Self.gptossId,
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: bothBudget)
        let shrunkA = try #require(targets[Self.gemmaId])
        let grantB = try #require(targets[Self.gptossId])

        // Mid-stretch state after a SUCCESSFUL build: A shrunk, B's engine
        // holding its grant + registered, B's slot NOT installed — exactly
        // where the post-bridge headroom guard fires.
        let weakB: WeakContainerRef
        let box: EngineV2NewcomerBox
        do {
            let containerB = makeUnwindStubContainer()
            weakB = WeakContainerRef(containerB)
            box = EngineV2NewcomerBox(containerB)
        }
        let trail = AlivenessTrail()
        let (bridgeA, engineA) = await installSurvivorA(
            loop, runtime: runtime, grant: shrunkA, sizingA: sizingA,
            onUpdate: { bytes in trail.record(bytes: bytes, alive: weakB.isAlive) })
        // Hooks only supply the physical-memory override for the regrow's
        // budget math (the builder is never invoked in this test).
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: unwindPhysicalBytes,
                makeEngine: { _, grant in UnwindProbeEngine(kvBytesCapacity: grant) }))
        let engineB = UnwindProbeEngine(kvBytesCapacity: grantB)
        let bridgeB = EngineV2Bridge(
            engine: engineB,
            modelId: Self.gptossId,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            eosTokenIds: [2])
        await runtime.register(modelId: Self.gptossId, bridge: bridgeB)

        await loop.unwindBuiltSlotAndRegrowForTesting(
            modelId: Self.gptossId, bridge: bridgeB, newcomer: box)

        // Bridge retired, engine drained.
        #expect(await runtime.bridge(forModel: Self.gptossId) == nil)
        #expect(engineB.shutdownCalls == 1)
        // THE ORDERING UNDER TEST: the regrow update on A observed B's
        // weights already dead, and grew A back to the full single-model
        // budget (Σ over live engines == that budget, ≤ the true budget).
        let entries = trail.entries
        #expect(entries.count == 1)
        #expect(entries.first?.bytes == grantA0)
        #expect(
            entries.first?.newcomerAlive == false,
            "survivors must regrow only AFTER the aborted newcomer's weights are released")
        #expect(box.container == nil)
        #expect(engineA.kvBytesCapacity == grantA0)
    }
}
