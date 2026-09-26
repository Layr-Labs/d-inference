import Foundation
import Testing
import MLXLMCommon
import MLXNN
@testable import ProviderCore

private func switchHardware() -> HardwareInfo {
    HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
        chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
}

private func switchModel(_ id: String) -> ModelInfo {
    ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 1024, estimatedMemoryGb: 1,
        weightHash: String(repeating: id == "old-model" ? "a" : "b", count: 64))
}

private func switchLoop(url: String = "ws://127.0.0.1:0/unused") async throws -> (ProviderLoop, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var config = ProviderConfig(provider: ProviderSettings(name: "model-switch-test", memoryReserveGB: 1))
    config.backend.enabledModels = ["old-model"]
    let configPath = root.appendingPathComponent("provider.toml")
    try ConfigManager.save(config, to: configPath)
    let loop = try ProviderLoop(config: .init(coordinatorURL: url, hardware: switchHardware(),
        models: [switchModel("old-model")], config: config,
        modelHashes: ["old-model": switchModel("old-model").weightHash!], configPath: configPath),
        purgeLegacyFiles: false, attestationSigner: nil)
    await loop.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
    await loop.isolateSwitchRuntime()
    return (loop, root)
}

private extension ProviderLoop {
    func isolateSwitchRuntime() { engineV2Runtime = EngineV2Runtime() }
    func holdSwitchRequest(_ id: String) { acceptedLifecycleRequests.insert(id) }
    func finishSwitchRequest(_ id: String) { acceptedLifecycleRequests.remove(id) }
    func failSwitchModel(_ model: ModelInfo) { failedSelfTestHashes[model.id] = model.weightHash ?? "" }
}

@Suite("Live provider model selection", .serialized)
struct ProviderModelSwitchTests {
    @Test func deadlinePreservesAcceptedWorkAndOldSelection() async throws {
        let (loop, root) = try await switchLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdSwitchRequest("accepted-stream")
        let tracker = await loop.localResponseTracker
        let response = try tracker.admit()
        defer { response.release() }
        await loop.beginServingDrain(owner: .modelSwitch)
        await #expect(throws: (any Error).self) {
            try await loop.drainForModelSwitch(deadline: .now)
        }
        #expect(await loop.lifecycleRemaining == 2)
        #expect(await loop.isModelAdvertised("old-model"))
        #expect(await loop.servingDrain.owner == .modelSwitch)
        #expect(throws: (any Error).self) { try tracker.admit() }
        #expect(try ConfigManager.load(from: root.appendingPathComponent("provider.toml")).backend.enabledModels == ["old-model"])
    }

    @Test func lifecycleStopCannotBeReopenedBySwitchCompletion() async throws {
        let (loop, root) = try await switchLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.beginServingDrain(owner: .modelSwitch)
        await loop.holdSwitchRequest("accepted")
        _ = await loop.drainForLifecycle(request: .init(target: try #require(ProcessIdentity.current()), timeoutSeconds: 0))
        await loop.resumeAfterModelSwitch()
        #expect(await loop.servingDrain.owner == .lifecycle)
        #expect(await loop.state.refusingNewWork)
        #expect(await loop.lifecycleRemaining == 1)
    }

    @Test func selfTestFailureDuringDrainCannotBeReadvertised() async throws {
        let (loop, root) = try await switchLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = switchModel("new-model")
        try await loop.validateModelSwitchSelfTests([candidate])
        await loop.beginServingDrain(owner: .modelSwitch)
        await loop.failSwitchModel(candidate)
        await #expect(throws: (any Error).self) { try await loop.applyModelSelection([candidate]) }
        #expect(await loop.advertisedLocalModelIds() == ["old-model"])
        #expect(await !loop.isModelAdvertised("new-model"))
    }

    @Test(arguments: [false, true])
    func replacementAndRejectionKeepOneCoordinatorSession(reject: Bool) async throws {
        let mock = MockCoordinator(rejectedReplacementModelIDs: reject ? ["new-model"] : [])
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await switchLoop(url: url.mockProviderWebSocketURL())
        defer { try? FileManager.default.removeItem(at: root) }
        let resident = makeInertStubBridge(modelId: "old-model", kvBytesCapacity: 1_073_741_824)
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "old-model"), model: SwitchSlotLanguageModel(),
            processor: SwitchSlotProcessor(), tokenizer: tokenizer))
        await loop.installModelSlotForTesting(modelId: "old-model", container: container,
            tokenizer: TokenizerHandle(tokenizer), engineV2: resident.bridge)
        defer { Task { await loop.removeModelSlotForTesting(modelId: "old-model"); await resident.bridge.shutdown() } }
        let client = CoordinatorClient(config: .init(url: url.mockProviderWebSocketURL(),
            hardware: switchHardware(), models: [switchModel("old-model")], backendName: "mlx-swift",
            heartbeatInterval: 60, publicKey: "cHVibGlj"), stats: AtomicProviderStats(),
            state: await loop.state, liveAPNsToken: { nil })
        let (events, send) = await client.start()
        defer { Task { await client.shutdown() } }
        for await event in events { if case .connected = event { break } }
        await loop.setCoordinatorClientForTesting(client)
        let reader = Task {
            for await event in events {
                if case .drainAck(let id) = event { await client.completeDrainAcknowledgement(id) }
            }
        }
        defer { reader.cancel() }
        let process = ProcessIdentity.current()
        await loop.beginServingDrain(owner: .modelSwitch)
        await loop.holdSwitchRequest("finished")
        send(.inferenceComplete(requestId: "finished", usage: .init(promptTokens: 3, completionTokens: 2),
            stopSequence: nil, seSignature: nil, responseHash: nil, profile: nil))
        await loop.finishSwitchRequest("finished")
        let barrier = try await loop.drainForModelSwitch(deadline: .now.advanced(by: .seconds(3)))
        if reject {
            await #expect(throws: (any Error).self) {
                try await loop.commitModelSelection([switchModel("new-model")], drainID: barrier)
            }
        } else {
            try await loop.commitModelSelection([switchModel("new-model")], drainID: barrier)
            await loop.resumeAfterModelSwitch()
        }
        let expected = reject ? ["old-model"] : ["new-model"]
        #expect(await loop.advertisedLocalModelIds() == expected)
        #expect(await client.currentAdvertisedModels().map(\.id) == expected)
        #expect(try ConfigManager.load(from: root.appendingPathComponent("provider.toml")).backend.enabledModels == expected)
        #expect(await !loop.state.refusingNewWork)
        #expect(ProcessIdentity.current() == process)
        #expect(mock.snapshot().registers.count == 1)
        #expect(mock.snapshot().inferenceComplete.first?.usage.completionTokens == 2)
        #expect(mock.snapshot().modelsReplacements.last?.models.map(\.id) == expected)
        if reject {
            #expect(await loop.slotBridgeForTesting(modelId: "old-model") === resident.bridge)
            #expect(resident.engine.shutdownCalls == 0)
        } else {
            #expect(await loop.slotBridgeForTesting(modelId: "old-model") == nil)
            #expect(resident.engine.shutdownCalls == 1)
        }
    }
}

private final class SwitchSlotLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult { .tokens(input.text) }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct SwitchSlotProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw ModelSelectionFailure("Weight-free lifecycle fixture cannot generate.")
    }
}
