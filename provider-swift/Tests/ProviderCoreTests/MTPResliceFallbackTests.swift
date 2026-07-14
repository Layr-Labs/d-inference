import Foundation
import Dispatch
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private let mtpFloorGiB: UInt64 = 1_073_741_824
private let mtpFloorPhysical = 64 * mtpFloorGiB
private let mtpFloorExistingID = "gemma-4-existing"
private let mtpFloorNewID = "gemma-4-new"
private let mtpFloorExistingWeightBytes = 15 * mtpFloorGiB
private let mtpFloorTargetWeightBytes =
    UnifiedMemoryCap.hardCapBytes(physicalBytes: mtpFloorPhysical)
    - UnifiedMemoryCap.defaultActivationReserveBytes
    - (2 * mtpFloorGiB)
private let mtpFloorNewWeightBytes = mtpFloorTargetWeightBytes - mtpFloorExistingWeightBytes

private struct MTPFloorTokenizer: MLXLMCommon.Tokenizer {
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

private final class MTPFloorTarget: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct MTPFloorProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput { throw CancellationError() }
}

private func mtpFloorContainer() -> ModelContainer {
    ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: "test/mtp-floor"),
        model: MTPFloorTarget(),
        processor: MTPFloorProcessor(),
        tokenizer: MTPFloorTokenizer()))
}

private final class MTPFloorEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var capacityBytes: Int
    private var capacityUpdates: [Int] = []
    private let hangs: Bool
    private var submitted = 0
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []

    init(capacityBytes: Int, hangs: Bool = false) {
        self.capacityBytes = capacityBytes
        self.hangs = hangs
    }

    var updates: [Int] { lock.withLock { capacityUpdates } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            submitted += 1
            if hangs {
                continuations.append(continuation)
            } else {
                continuation.finish()
            }
        }
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(
                activeRequests: submitted, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: capacityBytes, activeTokens: 0,
                stepsExecuted: 0)
        }
    }
    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            capacityBytes = max(0, bytes)
            capacityUpdates.append(capacityBytes)
        }
    }
    func shutdown() async {
        let held = lock.withLock { () -> [AsyncStream<CBv2Event>.Continuation] in
            let held = continuations
            continuations.removeAll()
            return held
        }
        for continuation in held { continuation.finish() }
    }
}

private final class MTPRecoveryEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let blockRecovery: Bool
    private let recoveryStarted = DispatchSemaphore(value: 0)
    private let recoveryResume = DispatchSemaphore(value: 0)

    init(blockRecovery: Bool = false) {
        self.blockRecovery = blockRecovery
    }

    var buildCount: Int { lock.withLock { count } }

    func make(grant: Int) -> any CBv2Engine {
        let index = lock.withLock { () -> Int in
            let index = count
            count += 1
            return index
        }
        if blockRecovery, index == 1 {
            recoveryStarted.signal()
            recoveryResume.wait()
        }
        return MTPFloorEngine(capacityBytes: grant, hangs: index == 0)
    }

    func waitForRecoveryStart() -> Bool {
        recoveryStarted.wait(timeout: .now() + 2) == .success
    }

    func resumeRecovery() { recoveryResume.signal() }
}

private final class MTPFloorPrepared: CBv2MTPPreparedCapture {}
private final class MTPFloorDrafter: CBv2MTPDrafter, @unchecked Sendable {
    func prepare(rows: [CBv2MTPRowCapture]) -> CBv2MTPPreparedCapture {
        MTPFloorPrepared()
    }
    func draftStep(
        tokens: MLXArray,
        hidden: MLXArray,
        prepared: CBv2MTPPreparedCapture
    ) -> (tokens: MLXArray, hidden: MLXArray) {
        (tokens, hidden)
    }
}

private final class MTPFloorAssistantLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private struct MTPFloorAssistantLoader: ProviderMTPAssistantLoading {
    let counter: MTPFloorAssistantLoadCounter?

    init(counter: MTPFloorAssistantLoadCounter? = nil) {
        self.counter = counter
    }

    func loadAndBind(
        artifact: SpecDecArtifact,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        counter?.increment()
        return ProviderMTPAssistantHandle(
            owner: NSObject(), drafter: MTPFloorDrafter())
    }
}

private func mtpFloorArtifact() throws -> SpecDecArtifact {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mtp-floor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"model_type":"gemma4_assistant"}"#.utf8)
        .write(to: directory.appendingPathComponent("config.json"))
    let weightURL = directory.appendingPathComponent("model.safetensors")
    try Data(repeating: 0x5a, count: 4096).write(to: weightURL)
    return try #require(SpecDecStore.inspectLocalArtifact(path: directory.path))
}

private func mtpFloorSizing(weightsGiB: UInt64) -> SlotSizingSnapshot {
    mtpFloorSizing(weightsBytes: weightsGiB * mtpFloorGiB)
}

private func mtpFloorSizing(weightsBytes: UInt64) -> SlotSizingSnapshot {
    .init(
        weightsBytes: Int(weightsBytes),
        fp16KVBytesPerToken: 20_480,
        maxContextLength: 131_072,
        defaultMaxTokens: 4096)
}

private func mtpFloorLoop(
    models: [ModelInfo] = [],
    mtpDrafterPath: String? = nil
) throws -> ProviderLoop {
    try ProviderLoop(
        config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max,
                memoryGb: 64, memoryAvailableGb: 60,
                cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: models,
            config: ProviderConfig(
                provider: .init(name: "mtp-floor", memoryReserveGB: 0),
                backend: .init(
                    idleTimeoutMins: 0,
                    maxModelSlots: 3,
                    mtp: mtpDrafterPath != nil,
                    mtpDrafterPath: mtpDrafterPath),
                coordinator: .init(heartbeatIntervalSecs: 60))),
        purgeLegacyFiles: false,
        attestationSigner: nil)
}

private func mtpFloorTargetOnlyGrants() -> [String: Int] {
    let existing = mtpFloorSizing(weightsBytes: mtpFloorExistingWeightBytes)
    let newcomer = mtpFloorSizing(weightsBytes: mtpFloorNewWeightBytes)
    let budget = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: mtpFloorPhysical,
        residentWeightBytes: UInt64(existing.weightsBytes + newcomer.weightsBytes),
        configReserveBytes: 0)
    return EngineV2KVSizing.resliceGrants(
        existing: [
            .init(
                modelId: mtpFloorExistingID,
                fp16KVBytesPerToken: existing.fp16KVBytesPerToken,
                maxContextLength: existing.maxContextLength),
        ],
        newcomer: .init(
            modelId: mtpFloorNewID,
            fp16KVBytesPerToken: newcomer.fp16KVBytesPerToken,
            maxContextLength: newcomer.maxContextLength),
        fleetKVBudgetBytes: budget)
}

@Suite("MTP assistant-only re-slice fallback", .serialized)
struct MTPResliceFallbackTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("ProviderLoop retries target-only, transfers accounting, and preserves heartbeat truth")
    func providerLoopTargetSurvivesAssistantFloor() async throws {
        let artifact = try mtpFloorArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let loop = try mtpFloorLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(
            physicalMemoryBytes: mtpFloorPhysical,
            assistantLoader: MTPFloorAssistantLoader(),
            makeEngine: { _, grant in MTPFloorEngine(capacityBytes: grant) }))

        let existingSizing = mtpFloorSizing(weightsBytes: mtpFloorExistingWeightBytes)
        let existingEngine = MTPFloorEngine(capacityBytes: Int(30 * mtpFloorGiB))
        let existingBridge = EngineV2Bridge(
            engine: existingEngine,
            modelId: mtpFloorExistingID,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            eosTokenIds: [])
        await runtime.register(modelId: mtpFloorExistingID, bridge: existingBridge)
        await loop.installModelSlotForTesting(
            modelId: mtpFloorExistingID,
            container: mtpFloorContainer(),
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            engineV2: existingBridge,
            sizing: existingSizing,
            modelType: "gemma4")
        await loop.reservePendingLoadForTesting(
            requestID: "pending-load:\(mtpFloorNewID)", bytes: artifact.residentBytes)

        let newcomer = EngineV2NewcomerBox(mtpFloorContainer())
        let build = try await loop.resliceAndBuildEngineV2BundleForTesting(
            modelId: mtpFloorNewID,
            modelType: "gemma4",
            newcomer: newcomer,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: mtpFloorSizing(weightsBytes: mtpFloorNewWeightBytes),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)))

        let expected = mtpFloorTargetOnlyGrants()
        #expect(build.bundle.mtpStatus.reason == .assistantResliceFloor)
        #expect(!build.bundle.mtpStatus.active)
        #expect(build.bundle.assistantBytes == 0)
        #expect(build.sizing.auxiliaryWeightBytes == 0)
        #expect(newcomer.container != nil)
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
        #expect(await existingBridge.engineKVBytesCapacity() == expected[mtpFloorExistingID])
        #expect(await build.bundle.bridge.engineKVBytesCapacity() == expected[mtpFloorNewID])
        #expect(existingEngine.updates == [expected[mtpFloorExistingID]!])

        let heartbeat = await build.bundle.bridge.backendSlotCapacity()
        #expect(heartbeat.activeTokenBudgetMax == Int64(expected[mtpFloorNewID]! / 20_480))
        let sum = UInt64(expected.values.reduce(0, +))
        let targetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: mtpFloorPhysical,
            residentWeightBytes: mtpFloorTargetWeightBytes,
            configReserveBytes: 0)
        #expect(sum <= targetBudget)

        await runtime.unregister(modelId: mtpFloorNewID)
        await build.bundle.bridge.shutdown()
        build.bundle.releaseAssistant()
        await existingBridge.shutdown()
    }

    @Test("Standalone retries target-only and keeps the valid target resident")
    func standaloneTargetSurvivesAssistantFloor() async throws {
        let artifact = try mtpFloorArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let server = StandaloneServer(config: .init(maxCachedModels: 3))
        await server.setV2TestHooksForTesting(.init(
            physicalMemoryBytes: mtpFloorPhysical,
            assistantLoader: MTPFloorAssistantLoader(),
            makeEngine: { _, grant in MTPFloorEngine(capacityBytes: grant) }))

        let existingSizing = mtpFloorSizing(weightsBytes: mtpFloorExistingWeightBytes)
        let existingEngine = MTPFloorEngine(capacityBytes: Int(30 * mtpFloorGiB))
        let existingBridge = EngineV2Bridge(
            engine: existingEngine,
            modelId: mtpFloorExistingID,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            eosTokenIds: [])
        await server.installSlotForTesting(
            modelId: mtpFloorExistingID,
            bridge: existingBridge,
            container: mtpFloorContainer(),
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: existingSizing,
            modelType: "gemma4")
        await server.reservePendingLoadForTesting(
            requestID: "pending-load:\(mtpFloorNewID)", bytes: artifact.residentBytes)

        let newcomer = EngineV2NewcomerBox(mtpFloorContainer())
        let build = try await server.resliceAndBuildMTPBundleForTesting(
            modelId: mtpFloorNewID,
            modelType: "gemma4",
            newcomer: newcomer,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: mtpFloorSizing(weightsBytes: mtpFloorNewWeightBytes),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)))

        let expected = mtpFloorTargetOnlyGrants()
        #expect(build.bundle.mtpStatus.reason == .assistantResliceFloor)
        #expect(!build.bundle.mtpStatus.active)
        #expect(build.sizing.auxiliaryWeightBytes == 0)
        #expect(newcomer.container != nil)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
        #expect(await existingBridge.engineKVBytesCapacity() == expected[mtpFloorExistingID])
        #expect(await build.bundle.bridge.engineKVBytesCapacity() == expected[mtpFloorNewID])
        #expect(existingEngine.updates == [expected[mtpFloorExistingID]!])

        await build.bundle.bridge.shutdown()
        build.bundle.releaseAssistant()
        await server.stopAndWait()
    }

    @Test("liveness rebuild revalidates cached artifact and recovers target-only")
    func recoveryCorruptionFallsBackWithoutUnloadingTarget() async throws {
        let artifact = try mtpFloorArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let loop = try mtpFloorLoop()
        let runtime = EngineV2Runtime()
        let factory = MTPRecoveryEngineFactory()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(
            physicalMemoryBytes: mtpFloorPhysical,
            assistantLoader: MTPFloorAssistantLoader(),
            makeEngine: { _, grant in factory.make(grant: grant) }))

        let container = mtpFloorContainer()
        let newcomer = EngineV2NewcomerBox(container)
        let initial = try await loop.resliceAndBuildEngineV2BundleForTesting(
            modelId: mtpFloorNewID,
            modelType: "gemma4",
            newcomer: newcomer,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: mtpFloorSizing(weightsGiB: 15),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)))
        #expect(initial.bundle.mtpStatus.active)
        #expect(initial.bundle.hasAssistant)
        await loop.installModelBundleForTesting(
            modelId: mtpFloorNewID,
            bundle: initial.bundle,
            container: container,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: initial.sizing,
            modelType: "gemma4")

        let oldBridge = initial.bundle.bridge
        let t0 = ContinuousClock.now
        _ = await oldBridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(
                model: mtpFloorNewID,
                messages: [.init(role: "user", content: "hi")]),
            requestId: "mtp-recovery-wedge")
        _ = await oldBridge.backendSlotCapacity(now: t0)

        let weightURL = artifact.directory.appendingPathComponent("model.safetensors")
        var mutated = try Data(contentsOf: weightURL)
        mutated[mutated.startIndex] ^= 0xff
        try mutated.write(to: weightURL)

        await loop.recoverWedgedEngineV2SlotsForTesting(
            now: t0.advanced(by: .seconds(130)))

        let rebuilt = try #require(await loop.slotBridgeForTesting(modelId: mtpFloorNewID))
        #expect(rebuilt !== oldBridge)
        #expect(factory.buildCount == 2)
        let status = await rebuilt.mtpStatusSnapshot()
        #expect(!status.active)
        #expect(status.fallbackReason == .localArtifactInvalid)
        let sizing = try #require(await loop.slotSizingForTesting(modelId: mtpFloorNewID))
        #expect(sizing.auxiliaryWeightBytes == 0)
        #expect(sizing.weightsBytes == sizing.targetWeightsBytes)
        #expect(await runtime.bridge(forModel: mtpFloorNewID) === rebuilt)

        await loop.unloadModel(mtpFloorNewID)
    }

    @Test("liveness rebuild reuses active assistant while concurrent KV remains reserved")
    func recoveryReusesAssistantWithoutNewResidency() async throws {
        let artifact = try mtpFloorArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let counter = MTPFloorAssistantLoadCounter()
        let factory = MTPRecoveryEngineFactory(blockRecovery: true)
        let loop = try mtpFloorLoop()
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(
            physicalMemoryBytes: mtpFloorPhysical,
            assistantLoader: MTPFloorAssistantLoader(counter: counter),
            makeEngine: { _, grant in factory.make(grant: grant) }))

        let container = mtpFloorContainer()
        let initial = try await loop.resliceAndBuildEngineV2BundleForTesting(
            modelId: mtpFloorNewID,
            modelType: "gemma4",
            newcomer: EngineV2NewcomerBox(container),
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: mtpFloorSizing(weightsGiB: 15),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)))
        await loop.installModelBundleForTesting(
            modelId: mtpFloorNewID,
            bundle: initial.bundle,
            container: container,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: initial.sizing,
            modelType: "gemma4")
        let oldBridge = initial.bundle.bridge
        let t0 = ContinuousClock.now
        _ = await oldBridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(
                model: mtpFloorNewID,
                messages: [.init(role: "user", content: "hi")]),
            requestId: "mtp-recovery-reuse-wedge")
        _ = await oldBridge.backendSlotCapacity(now: t0)

        let budget = await loop.kvBudgetForTesting()
        let recovery = Task {
            await loop.recoverWedgedEngineV2SlotsForTesting(
                now: t0.advanced(by: .seconds(130)))
        }
        let rebuildStarted = factory.waitForRecoveryStart()
        let outstandingBeforeConcurrentReserve = await budget.outstandingReservedBytes()
        let reserved = await budget.reserveBytes(
            requestID: "mtp-concurrent-kv", bytes: 1)
        let outstandingDuringRebuild = await budget.outstandingReservedBytes()
        factory.resumeRecovery()
        await recovery.value

        #expect(rebuildStarted)
        #expect(reserved)
        #expect(outstandingDuringRebuild == outstandingBeforeConcurrentReserve + 1)
        #expect(counter.count == 1, "recovery must reuse, not reload, the assistant")
        let rebuilt = try #require(await loop.slotBridgeForTesting(modelId: mtpFloorNewID))
        #expect(rebuilt !== oldBridge)
        #expect(await loop.slotMTPStatusForTesting(modelId: mtpFloorNewID)?.active == true)
        #expect(await loop.slotSizingForTesting(modelId: mtpFloorNewID)?.auxiliaryWeightBytes
            == initial.sizing.auxiliaryWeightBytes)
        let outstandingBeforeConcurrentRelease = await budget.outstandingReservedBytes()
        await budget.release(requestID: "mtp-concurrent-kv")
        let outstandingAfterConcurrentRelease = await budget.outstandingReservedBytes()
        #expect(outstandingBeforeConcurrentRelease == outstandingAfterConcurrentRelease + 1)
        await loop.unloadModel(mtpFloorNewID)
    }

    @Test("target-only slot cannot activate an available assistant during recovery")
    func recoveryPreservesTargetOnlyPosture() async throws {
        let artifact = try mtpFloorArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let counter = MTPFloorAssistantLoadCounter()
        let factory = MTPRecoveryEngineFactory()
        let model = ModelInfo(
            id: mtpFloorNewID,
            modelType: "gemma4",
            sizeBytes: 1,
            estimatedMemoryGb: 1)
        let loop = try mtpFloorLoop(
            models: [model], mtpDrafterPath: artifact.directory.path)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(.init(
            physicalMemoryBytes: mtpFloorPhysical,
            assistantLoader: MTPFloorAssistantLoader(counter: counter),
            makeEngine: { _, grant in factory.make(grant: grant) }))

        let targetOnlyStatus = MTPActivationStatus.disabled(
            .assistantMemoryUnavailable, configured: true)
        let container = mtpFloorContainer()
        let initial = try await loop.resliceAndBuildEngineV2BundleForTesting(
            modelId: mtpFloorNewID,
            modelType: "gemma4",
            newcomer: EngineV2NewcomerBox(container),
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: mtpFloorSizing(weightsGiB: 15),
            specDecPreparation: .init(
                artifact: nil, status: targetOnlyStatus))
        await loop.installModelBundleForTesting(
            modelId: mtpFloorNewID,
            bundle: initial.bundle,
            container: container,
            tokenizer: TokenizerHandle(MTPFloorTokenizer()),
            sizing: initial.sizing,
            modelType: "gemma4")
        let oldBridge = initial.bundle.bridge
        let t0 = ContinuousClock.now
        _ = await oldBridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(
                model: mtpFloorNewID,
                messages: [.init(role: "user", content: "hi")]),
            requestId: "mtp-recovery-target-only-wedge")
        _ = await oldBridge.backendSlotCapacity(now: t0)

        await loop.recoverWedgedEngineV2SlotsForTesting(
            now: t0.advanced(by: .seconds(130)))

        let rebuilt = try #require(await loop.slotBridgeForTesting(modelId: mtpFloorNewID))
        let status = await rebuilt.mtpStatusSnapshot()
        #expect(!status.active)
        #expect(status.fallbackReason == .assistantMemoryUnavailable)
        #expect(counter.count == 0)
        #expect(await loop.slotSizingForTesting(modelId: mtpFloorNewID)?.auxiliaryWeightBytes == 0)
        await loop.unloadModel(mtpFloorNewID)
    }
}
