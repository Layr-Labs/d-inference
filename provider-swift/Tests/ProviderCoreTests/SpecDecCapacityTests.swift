// Copyright © 2026 Eigen Labs.
//
// Capacity accounting for Gemma 4 MTP speculative decoding (plan D5):
//
//   1. Drafter (auxiliary) weight bytes fold INTO
//      `SlotSizingSnapshot.weightsBytes` at construction, so every consumer
//      of `.weightsBytes` — fleet KV budget, re-slice grants, heartbeat
//      clamp, StandaloneServer's mirrored budget — sees the sum with zero
//      consumer-site changes. KV-rate math must be untouched (the drafter
//      writes no KV).
//   2. The load gate (`ensureModelLoaded`) adds `extraWeightBytes` to BOTH
//      the required-to-load figure and the pending-load reservation. The
//      drafter lives outside the model snapshot on every path, so the
//      scan-time `estimatedMemoryGb` can never include it.
//   3. The slot's opaque MTP drafter handle is released with the target on
//      `unloadModel` (the gray-box lesson: no unaccounted residents, no
//      leaked residents).

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private let gib = 1024.0 * 1024.0 * 1024.0
/// The real drafter figure the bridge passes: model.safetensors
/// 236,124,704 B × the standard 1.2 load factor.
private let drafterEstimateBytes = UInt64(236_124_704.0 * 1.2)

// MARK: - Sizing snapshot: auxiliary bytes fold at construction

@Suite("SpecDec capacity: sizing snapshot auxiliary-bytes fold")
struct SpecDecSizingSnapshotTests {

    private func snapshot(weights: Int, aux: Int = 0) -> SlotSizingSnapshot {
        SlotSizingSnapshot(
            weightsBytes: weights,
            auxiliaryWeightBytes: aux,
            fp16KVBytesPerToken: 20_480,
            maxContextLength: 262_144,
            defaultMaxTokens: 8192)
    }

    @Test("auxiliary bytes fold into weightsBytes — snapshot is IDENTICAL to a direct-sum one")
    func auxiliaryFoldsIntoWeights() {
        let folded = snapshot(weights: 15_000_000_000, aux: Int(drafterEstimateBytes))
        let direct = snapshot(weights: 15_000_000_000 + Int(drafterEstimateBytes))
        #expect(folded.weightsBytes == 15_000_000_000 + Int(drafterEstimateBytes))
        // Downstream capacity consumers read the identical folded total. The
        // component fields intentionally remain distinct for fail-open rebuilds.
        #expect(folded.weightsBytes == direct.weightsBytes)
        #expect(folded.fp16KVBytesPerToken == direct.fp16KVBytesPerToken)
        #expect(folded.maxContextLength == direct.maxContextLength)
    }

    @Test("default (0) and negative auxiliary bytes leave weightsBytes unchanged")
    func defaultAndNegativeAreInert() {
        #expect(snapshot(weights: 100).weightsBytes == 100)
        #expect(snapshot(weights: 100, aux: 0).weightsBytes == 100)
        #expect(snapshot(weights: 100, aux: -7).weightsBytes == 100)
    }

    @Test("weight-byte sum saturates instead of trapping at Int boundary")
    func sizingSaturates() {
        let saturated = snapshot(weights: Int.max - 4, aux: 10)
        #expect(saturated.weightsBytes == Int.max)
        #expect(saturated.targetWeightsBytes == Int.max - 4)
        #expect(saturated.auxiliaryWeightBytes == 10)
    }

    @Test("replacing auxiliary bytes charges active assistant exactly once")
    func replacingAuxiliaryIsExact() {
        let candidate = snapshot(weights: 1_000, aux: 200)
        let active = candidate.replacingAuxiliaryWeightBytes(200)
        let fallback = candidate.replacingAuxiliaryWeightBytes(0)
        #expect(active.weightsBytes == 1_200)
        #expect(active.targetWeightsBytes == 1_000)
        #expect(active.auxiliaryWeightBytes == 200)
        #expect(fallback.weightsBytes == 1_000)
        #expect(fallback.auxiliaryWeightBytes == 0)
    }

    @Test("KV-rate fields are untouched by auxiliary bytes (drafter writes no KV)")
    func kvFieldsUntouched() {
        let folded = snapshot(weights: 100, aux: Int(drafterEstimateBytes))
        let plain = snapshot(weights: 100)
        #expect(folded.fp16KVBytesPerToken == plain.fp16KVBytesPerToken)
        #expect(folded.maxContextLength == plain.maxContextLength)
        #expect(folded.defaultMaxTokens == plain.defaultMaxTokens)
    }

    @Test("fleet KV budget consumer: budget shrinks by exactly the auxiliary bytes")
    func fleetKVBudgetSeesTheSum() {
        // The fleet-budget consumer reads `.weightsBytes` into
        // `UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes:)`
        // (ProviderLoop+EngineV2.fleetKVBudgetBytes and StandaloneServer's
        // mirror). In the linear (non-clamped) region the drafter bytes must
        // come straight out of the KV budget.
        let physical: UInt64 = 64 * 1024 * 1024 * 1024
        let base = snapshot(weights: 15_000_000_000)
        let mtp = snapshot(weights: 15_000_000_000, aux: Int(drafterEstimateBytes))
        let budgetBase = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical,
            residentWeightBytes: UInt64(base.weightsBytes),
            activationReserveBytes: 3 * 1024 * 1024 * 1024)
        let budgetMTP = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical,
            residentWeightBytes: UInt64(mtp.weightsBytes),
            activationReserveBytes: 3 * 1024 * 1024 * 1024)
        #expect(budgetBase > 0)
        #expect(budgetBase - budgetMTP == drafterEstimateBytes)
    }

    @Test("build(): auxiliary bytes fold in; every other field byte-identical")
    func buildFoldsAuxiliaryBytes() async {
        // Weight-free stub container (Σ parameter nbytes == 0), so the folded
        // figure IS the auxiliary figure and the KV-rate/context fields can
        // be compared field-for-field between the two builds.
        let plain = await SlotSizingSnapshot.build(
            container: makeSpecDecStubContainer(),
            modelPath: nil,
            fallbackDefaultMaxTokens: 4096)
        let mtp = await SlotSizingSnapshot.build(
            container: makeSpecDecStubContainer(),
            modelPath: nil,
            fallbackDefaultMaxTokens: 4096,
            auxiliaryWeightBytes: Int(drafterEstimateBytes))
        #expect(mtp.weightsBytes == plain.weightsBytes + Int(drafterEstimateBytes))
        #expect(mtp.fp16KVBytesPerToken == plain.fp16KVBytesPerToken)
        #expect(mtp.maxContextLength == plain.maxContextLength)
        #expect(mtp.defaultMaxTokens == plain.defaultMaxTokens)
    }
}

// MARK: - Load gate: extraWeightBytes arithmetic

@Suite("SpecDec capacity: load-gate extra-bytes arithmetic")
struct SpecDecLoadGateTests {

    @Test("loadGateWeightsGb adds exactly extraWeightBytes/GiB; zero is the identity")
    func loadGateAddsExtraGb() {
        let base = 21.5
        #expect(ProviderLoop.loadGateWeightsGb(estimatedWeightsGb: base, extraWeightBytes: 0) == base)
        let withDrafter = ProviderLoop.loadGateWeightsGb(
            estimatedWeightsGb: base, extraWeightBytes: drafterEstimateBytes)
        #expect(withDrafter == base + Double(drafterEstimateBytes) / gib)
    }

    @Test("requiredToLoadGb over the folded figure == weights + drafter + headroom")
    func requiredToLoadComposition() {
        let required = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: ProviderLoop.loadGateWeightsGb(
                estimatedWeightsGb: 21.5, extraWeightBytes: drafterEstimateBytes),
            headroomGb: 5.0)
        #expect(abs(required - (21.5 + Double(drafterEstimateBytes) / gib + 5.0)) < 1e-9)
    }

    @Test("pending-load reservation includes the drafter bytes")
    func pendingReservationIncludesExtra() {
        let bytes = ProviderLoop.pendingLoadReservationBytes(
            estimatedWeightsGb: 2.0, extraWeightBytes: drafterEstimateBytes)
        #expect(bytes == 2 * 1_073_741_824 + drafterEstimateBytes)
    }

    @Test("pre-MTP behavior preserved: no extra bytes, sane estimate")
    func pendingReservationBaseline() {
        #expect(
            ProviderLoop.pendingLoadReservationBytes(estimatedWeightsGb: 2.0, extraWeightBytes: 0)
                == 2 * 1_073_741_824)
    }

    @Test("garbage estimates contribute nothing — the extra bytes still reserve")
    func pendingReservationGarbageEstimate() {
        for garbage in [0.0, -3.5, .nan, .infinity, -.infinity] as [Double] {
            #expect(
                ProviderLoop.pendingLoadReservationBytes(
                    estimatedWeightsGb: garbage, extraWeightBytes: drafterEstimateBytes)
                    == drafterEstimateBytes,
                "estimate=\(garbage)")
        }
    }

    @Test("saturation: huge estimate or overflowing sum clamps to UInt64.max")
    func pendingReservationSaturates() {
        #expect(
            ProviderLoop.pendingLoadReservationBytes(
                estimatedWeightsGb: 1e30, extraWeightBytes: drafterEstimateBytes)
                == .max)
        #expect(
            ProviderLoop.pendingLoadReservationBytes(
                estimatedWeightsGb: Double(UInt64.max) / 1_073_741_824 * 0.999,
                extraWeightBytes: .max)
                == .max)
    }

    @Test("assistant admission boundary is exact and malformed inputs fail closed")
    func assistantAdmissionBoundary() {
        let oneGiB: UInt64 = 1_073_741_824
        #expect(ProviderLoop.assistantMemoryFits(
            availableGb: 11, targetRequiredGb: 10, assistantBytes: oneGiB))
        #expect(!ProviderLoop.assistantMemoryFits(
            availableGb: 10.999, targetRequiredGb: 10,
            assistantBytes: oneGiB))
        #expect(!ProviderLoop.assistantMemoryFits(
            availableGb: .nan, targetRequiredGb: 10, assistantBytes: oneGiB))
        #expect(!ProviderLoop.assistantMemoryFits(
            availableGb: 11, targetRequiredGb: .infinity, assistantBytes: oneGiB))
    }

    @Test("pending reservation atomically transfers from target+assistant to assistant only")
    func pendingReservationTransfer() async {
        let budget = GlobalKVCacheBudget(
            memorySnapshot: {
                .init(total: 10_000, active: 0, cache: 0, systemAvailable: 10_000)
            })
        await budget.reservePendingLoad(requestID: "load", bytes: 1_200)
        #expect(await budget.outstandingReservedBytes() == 1_200)
        await budget.replacePendingLoadReservation(requestID: "load", bytes: 200)
        #expect(await budget.outstandingReservedBytes() == 200)
        await budget.replacePendingLoadReservation(requestID: "load", bytes: 0)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("pending reservation shrink and removal reset rejection audit progress")
    func pendingReservationProgressResetsAuditStreak() async {
        let unit: UInt64 = 1_073_741_824
        let budget = GlobalKVCacheBudget(
            capFraction: 1.0,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(total: 8 * unit, active: 0, cache: 0, systemAvailable: .max)
            })
        await budget.reservePendingLoad(requestID: "load", bytes: 6 * unit)
        #expect(!(await budget.reserveBytes(requestID: "rejected-1", bytes: unit)))
        #expect(await budget.rejectionStreakArmedForTesting())

        await budget.replacePendingLoadReservation(requestID: "load", bytes: 5 * unit)
        #expect(!(await budget.rejectionStreakArmedForTesting()))
        #expect(!(await budget.reserveBytes(requestID: "rejected-2", bytes: 2 * unit)))
        #expect(await budget.rejectionStreakArmedForTesting())

        await budget.replacePendingLoadReservation(requestID: "load", bytes: 0)
        #expect(!(await budget.rejectionStreakArmedForTesting()))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

// MARK: - Slot teardown releases the drafter handle

/// Weight-free stubs so a real `ModelSlot` can exist (same pattern as
/// LoadedModelsStoreTests / EngineV2ProductionWiringTests).
private struct SpecDecStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [0] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [0] }
}

private final class SpecDecStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct SpecDecStubProcessorError: Error {}
private struct SpecDecStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw SpecDecStubProcessorError()
    }
}

private func makeSpecDecStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/specdec-stub-model"),
            model: SpecDecStubLanguageModel(),
            processor: SpecDecStubProcessor(),
            tokenizer: SpecDecStubTokenizer()
        ))
}

private func makeSpecDecLoop() throws -> ProviderLoop {
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
            provider: ProviderSettings(name: "specdec-capacity-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

/// Stand-in for the MLXLLM drafter adapter — ProviderCore only ever sees the
/// type-erased handle, so any (Sendable) class object exercises the
/// ownership contract.
private final class SpecDecFakeDrafterHandle: Sendable {}

/// Lock-guarded weak observer (a bare `weak var` local can't cross the
/// @Sendable/actor boundaries; same shape as EngineV2ResliceUnwindTests).
private final class WeakHandleRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: AnyObject?
    init(_ value: AnyObject) { self._value = value }
    var isAlive: Bool { lock.withLock { _value != nil } }
}

extension ProviderLoop {
    /// Test-local seam: install a fully-formed slot CARRYING an opaque MTP
    /// drafter handle (the shared `installModelSlotForTesting` predates the
    /// field, and this suite owns the drafter-lifecycle contract). The handle
    /// is created HERE so the non-Sendable strong reference never crosses the
    /// actor boundary; the returned weak observer is the release probe (the
    /// slot holds the only strong reference).
    fileprivate func installSlotWithDrafterForSpecDecTesting(
        modelId: String
    ) -> WeakHandleRef {
        let drafter = SpecDecFakeDrafterHandle()
        modelSlots[modelId] = ModelSlot(
            engineV2: makeInertStubBridge(modelId: modelId).bridge,
            container: makeSpecDecStubContainer(),
            tokenizer: TokenizerHandle(SpecDecStubTokenizer()),
            sizing: SlotSizingSnapshot(
                weightsBytes: 0, fp16KVBytesPerToken: 0,
                maxContextLength: 0, defaultMaxTokens: 4096),
            isVLM: false,
            modelType: "gemma4",
            mtpDrafter: drafter,
            lastInferenceAt: .now
        )
        return WeakHandleRef(drafter)
    }

    fileprivate func hasMTPDrafterForSpecDecTesting(modelId: String) -> Bool {
        modelSlots[modelId]?.mtpDrafter != nil
    }
}

@Suite("SpecDec capacity: slot drafter-handle teardown", .serialized)
struct SpecDecSlotTeardownTests {

    init() {
        // unloadModel calls MLX.Memory.clearCache(), which initializes the
        // MLX device — the metallib must sit next to the test runner.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("unloadModel releases the slot's drafter handle with the target")
    func unloadReleasesDrafterHandle() async throws {
        let loop = try makeSpecDecLoop()
        let modelId = "gemma-4-26b-it-mtp"

        // The slot is the ONLY strong owner of the handle from birth.
        let weakDrafter = await loop.installSlotWithDrafterForSpecDecTesting(
            modelId: modelId)
        #expect(weakDrafter.isAlive)
        #expect(await loop.hasMTPDrafterForSpecDecTesting(modelId: modelId))

        await loop.unloadModel(modelId)

        #expect(await loop.hasMTPDrafterForSpecDecTesting(modelId: modelId) == false)
        #expect(!weakDrafter.isAlive)
    }

    @Test("slots default to NO drafter handle (existing construction sites unchanged)")
    func defaultSlotHasNoDrafter() async throws {
        let loop = try makeSpecDecLoop()
        let modelId = "gemma-4-26b-it"
        await loop.installModelSlotForTesting(
            modelId: modelId,
            container: makeSpecDecStubContainer(),
            tokenizer: TokenizerHandle(SpecDecStubTokenizer()),
            engineV2: makeInertStubBridge(modelId: modelId).bridge
        )
        #expect(await loop.hasMTPDrafterForSpecDecTesting(modelId: modelId) == false)
        await loop.unloadModel(modelId)
        #expect(await loop.slotSizingForTesting(modelId: modelId) == nil)
    }
}
