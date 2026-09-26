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
    func useSwitchSnapshot(
        _ snapshot: URL,
        hashSnapshot: @escaping @Sendable (URL, String) -> String? = { WeightHasher.computeHash(snapshotDir: $0, modelID: $1) }
    ) {
        modelSwitchSnapshotResolver = { _ in snapshot }
        modelSwitchWeightHasher = hashSnapshot
    }
    func stopSwitchForTeardown() async {
        isShuttingDown = true
        await cancelModelSwitchAndWait()
        state.refusingNewWork = true
    }
}

private func switchSnapshot(in root: URL) throws -> URL {
    let snapshot = root.appendingPathComponent("snapshot")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data(#"{"model_type":"gpt_oss"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
    try Data(repeating: 0x61, count: 1024).write(to: snapshot.appendingPathComponent("model.safetensors"))
    return snapshot
}

private func connectSwitchLoop(_ loop: ProviderLoop, url: String) async -> (CoordinatorClient, Task<Void, Never>) {
    let client = CoordinatorClient(config: .init(url: url, hardware: switchHardware(),
        models: [switchModel("old-model")], backendName: "mlx-swift", heartbeatInterval: 60,
        publicKey: "cHVibGlj"), stats: AtomicProviderStats(), state: await loop.state, liveAPNsToken: { nil })
    let (events, _) = await client.start()
    for await event in events { if case .connected = event { break } }
    await loop.setCoordinatorClientForTesting(client)
    let reader = Task {
        for await event in events {
            if case .drainAck(let id) = event { await client.completeDrainAcknowledgement(id) }
        }
    }
    return (client, reader)
}

private func switchEventually(_ condition: () async -> Bool) async throws -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private final class SwitchHashGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var finished = false

    var isEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var isFinished: Bool { condition.lock(); defer { condition.unlock() }; return finished }

    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }

    func hash(snapshot: URL, modelID: String) -> String? {
        condition.lock()
        entered = true
        while !released { condition.wait() }
        condition.unlock()
        // Only timing is controlled; production hashing still validates bytes.
        let hash = WeightHasher.computeHash(snapshotDir: snapshot, modelID: modelID)
        condition.lock(); defer { condition.unlock() }
        finished = true
        return hash
    }
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

    @Test func zeroTimeoutSwitchesSettledProviderThroughCoordinatorBarrier() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await switchLoop(url: url.mockProviderWebSocketURL())
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try switchSnapshot(in: root)
        await loop.useSwitchSnapshot(snapshot)
        let (client, reader) = await connectSwitchLoop(loop, url: url.mockProviderWebSocketURL())
        defer { reader.cancel(); Task { await client.shutdown() } }
        let request = ProviderModelSwitchRequest(target: try #require(ProcessIdentity.current()),
            models: ["new-model"], timeoutSeconds: 0)
        let result = await loop.switchModels(request: request)
        #expect(result.outcome == .switched)
        #expect(await loop.advertisedLocalModelIds() == ["new-model"])
        #expect(await client.currentAdvertisedModels().map(\.id) == ["new-model"])
        #expect(mock.snapshot().drainBarriers.count == 1)
        #expect(mock.snapshot().modelsReplacements.map(\.validateOnly) == [true, false])
        #expect(mock.snapshot().registers.count == 1)
        #expect(await !loop.state.refusingNewWork)
        #expect(try ConfigManager.load(from: root.appendingPathComponent("provider.toml")).backend.enabledModels == ["new-model"])

        let verifiedHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: "new-model"))
        let reused = try await loop.captureWeightHashForTesting(modelId: "new-model", modelPath: snapshot)
        #expect(reused.hash == verifiedHash)
        #expect(!reused.recomputed)
        let fresh = try await loop.captureWeightHashForTesting(
            modelId: "new-model", modelPath: snapshot, requireFreshCryptographicHash: true)
        #expect(fresh.hash == verifiedHash)
        #expect(fresh.recomputed)

        try Data(repeating: 0x62, count: 2048).write(to: snapshot.appendingPathComponent("model.safetensors"))
        let updatedHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: "new-model"))
        let changed = try await loop.captureWeightHashForTesting(modelId: "new-model", modelPath: snapshot)
        #expect(updatedHash != verifiedHash)
        #expect(changed.hash == updatedHash)
        #expect(changed.recomputed)
    }

    @Test(arguments: [false, true])
    func zeroTimeoutDoesNotWaitForInferenceOrModelMutation(mutation: Bool) async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await switchLoop(url: url.mockProviderWebSocketURL())
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.useSwitchSnapshot(try switchSnapshot(in: root))
        let (client, reader) = await connectSwitchLoop(loop, url: url.mockProviderWebSocketURL())
        defer { reader.cancel(); Task { await client.shutdown() } }
        let tracker = await loop.localResponseTracker
        let lease = mutation ? nil : try tracker.admit()
        defer { lease?.release() }
        if mutation { await loop.acquireResliceGateForTesting() }
        else { await loop.holdSwitchRequest("accepted") }
        let result = await loop.switchModels(request: .init(target: try #require(ProcessIdentity.current()),
            models: ["new-model"], timeoutSeconds: 0))
        #expect(result.outcome == .timedOut)
        #expect(mock.snapshot().drainBarriers.isEmpty)
        #expect(mock.snapshot().modelsReplacements.isEmpty)
        #expect(await loop.advertisedLocalModelIds() == ["old-model"])
        #expect(await loop.state.refusingNewWork)
        if mutation {
            #expect(await !loop.modelSwitchMutationsSettled)
            await loop.releaseResliceGateForTesting()
        } else {
            #expect(await loop.lifecycleRemaining == 2)
            await loop.finishSwitchRequest("accepted")
        }
    }

    @Test(arguments: ["graceful", "force", "teardown"])
    func lifecyclePreemptsReadOnlyHashAndLateCompletionCannotPublish(mode: String) async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await switchLoop(url: url.mockProviderWebSocketURL())
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SwitchHashGate()
        defer { gate.release() }
        await loop.useSwitchSnapshot(try switchSnapshot(in: root), hashSnapshot: { gate.hash(snapshot: $0, modelID: $1) })
        let (client, reader) = await connectSwitchLoop(loop, url: url.mockProviderWebSocketURL())
        defer { reader.cancel(); Task { await client.shutdown() } }
        let identity = try #require(ProcessIdentity.current())
        let request = ProviderModelSwitchRequest(target: identity, models: ["new-model"], timeoutSeconds: 0)
        let switching = Task { await loop.switchModels(request: request) }
        #expect(try await switchEventually { gate.isEntered })
        let stopping = Task {
            if mode == "teardown" {
                await loop.stopSwitchForTeardown()
            } else {
                let result = await loop.drainForLifecycle(request: .init(target: identity,
                    timeoutSeconds: 1, force: mode == "force"))
                #expect(result.outcome == (mode == "force" ? .forced : .drained))
            }
        }
        let preempted = try await switchEventually {
            if mode == "teardown" { return await loop.modelSwitchStatus.outcome == .failed }
            return await loop.lifecycleStatus.outcome == (mode == "force" ? .forced : .drained)
        }
        #expect(preempted, "Lifecycle must finish while read-only hashing is still held")
        if !preempted { gate.release() }
        await stopping.value
        #expect(await switching.value.outcome == .failed)
        #expect(!gate.isFinished || !preempted)
        #expect(await loop.advertisedLocalModelIds() == ["old-model"])
        #expect(mock.snapshot().modelsReplacements.isEmpty)

        // A later scheduled loop reuses this process's state/receipt paths.
        let (next, nextRoot) = try await switchLoop()
        defer { try? FileManager.default.removeItem(at: nextRoot) }
        let statePath = root.appendingPathComponent("state.json")
        await next.setDaemonStateFileForTesting(statePath)
        await next.publishModelSwitchStatus()
        let nextRequest = ProviderModelSwitchRequest(target: identity, models: ["later-model"], timeoutSeconds: 0)
        let nextResult = await next.switchModels(request: nextRequest)
        #expect(nextResult.outcome == .busy)
        let mailbox = LifecycleMailbox(identity: identity, directory: root.appendingPathComponent("lifecycle"))
        let nextState = try Data(contentsOf: statePath)
        #expect(mailbox.readSwitchStatus()?.requestID == nextRequest.id)
        gate.release()
        #expect(try await switchEventually { gate.isFinished })
        #expect(await loop.modelSwitchStatus.requestID == request.id)
        #expect(await loop.modelSwitchStatus.outcome == .failed)
        #expect(await loop.advertisedLocalModelIds() == ["old-model"])
        #expect(await next.advertisedLocalModelIds() == ["old-model"])
        #expect(mailbox.readSwitchStatus() == nextResult)
        #expect(try Data(contentsOf: statePath) == nextState)
        #expect(mock.snapshot().modelsReplacements.isEmpty)
        #expect(await loop.state.refusingNewWork)
        #expect(await !next.state.refusingNewWork)
        if mode != "teardown" { #expect(await loop.servingDrain.owner == .lifecycle) }
    }

    @Test func laterLoopMonitorConsumesOnlyNewPublication() async throws {
        let (first, root) = try await switchLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try #require(ProcessIdentity.current())
        let mailbox = LifecycleMailbox(identity: identity, directory: root.appendingPathComponent("lifecycle"))
        let old = ProviderModelSwitchRequest(target: identity, models: ["old-selection"], timeoutSeconds: 0)
        try mailbox.writeSwitchRequest(old)
        let firstAccepted = try #require(await first.acceptPendingModelSwitch(from: mailbox))
        #expect(await firstAccepted.value.requestID == old.id)

        let (next, nextRoot) = try await switchLoop()
        defer { try? FileManager.default.removeItem(at: nextRoot) }
        await next.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
        await next.publishModelSwitchStatus()
        // Poll the same production acceptance path in a new loop lifetime.
        #expect(await next.acceptPendingModelSwitch(from: mailbox) == nil)
        #expect(mailbox.readSwitchStatus()?.requestID == nil)
        let new = ProviderModelSwitchRequest(target: identity, models: ["new-selection"], timeoutSeconds: 0)
        try mailbox.writeSwitchRequest(new)
        let nextAccepted = try #require(await next.acceptPendingModelSwitch(from: mailbox))
        #expect(await nextAccepted.value.requestID == new.id)
        #expect(mailbox.readSwitchStatus()?.outcome == .busy)
        #expect(mailbox.claimSwitchRequest() == nil)
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
        await #expect(throws: (any Error).self) {
            try await loop.applyModelSelection(.init(models: [candidate], fingerprints: [:]))
        }
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
                try await loop.commitModelSelection(.init(models: [switchModel("new-model")], fingerprints: [:]), drainID: barrier)
            }
        } else {
            try await loop.commitModelSelection(.init(models: [switchModel("new-model")], fingerprints: [:]), drainID: barrier)
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

    @Test func changedArtifactsDuringValidationCannotReuseTheEarlierHash() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await switchLoop(url: url.mockProviderWebSocketURL())
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try switchSnapshot(in: root)
        let originalHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: "new-model"))
        await loop.useSwitchSnapshot(snapshot, hashSnapshot: { path, id in
            let hash = WeightHasher.computeHash(snapshotDir: path, modelID: id)
            // A writer changes bytes before the validation hash returns. Taking
            // the fingerprint after this callback would bless the earlier hash.
            do {
                try Data(repeating: 0x62, count: 2048).write(to: path.appendingPathComponent("model.safetensors"))
            } catch {
                Issue.record(error)
                return nil
            }
            return hash
        })
        let (client, reader) = await connectSwitchLoop(loop, url: url.mockProviderWebSocketURL())
        defer { reader.cancel(); Task { await client.shutdown() } }
        let result = await loop.switchModels(request: .init(target: try #require(ProcessIdentity.current()),
            models: ["new-model"], timeoutSeconds: 0))
        #expect(result.outcome == .switched)
        #expect(await loop.liveModelHashForTesting("new-model") == originalHash)
        let updatedHash = try #require(WeightHasher.computeHash(snapshotDir: snapshot, modelID: "new-model"))
        let captured = try await loop.captureWeightHashForTesting(modelId: "new-model", modelPath: snapshot)
        #expect(updatedHash != originalHash)
        #expect(captured.hash == updatedHash)
        #expect(captured.recomputed)
    }

    @Test(arguments: [false, true])
    func failedCommitPreservesMatchingHashAndFingerprint(dropConnection: Bool) async throws {
        let mock = MockCoordinator(acknowledgeModelReplacements: false)
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let (loop, root) = try await switchLoop(url: url.mockProviderWebSocketURL())
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSnapshot = try switchSnapshot(in: root)
        let previous = try await ProviderModelSwitchValidation.scanCancellable(
            ["old-model"], capabilities: [], resolveSnapshot: { _ in oldSnapshot },
            hashSnapshot: { WeightHasher.computeHash(snapshotDir: $0, modelID: $1) })
        await loop.beginServingDrain(owner: .modelSwitch)
        try await loop.applyModelSelection(previous)
        await loop.resumeAfterModelSwitch()
        let oldHash = try #require(previous.models.first?.weightHash)
        let newSnapshot = try switchSnapshot(in: root.appendingPathComponent("replacement"))
        try Data(repeating: 0x62, count: 2048).write(to: newSnapshot.appendingPathComponent("model.safetensors"))
        let newHash = try #require(WeightHasher.computeHash(snapshotDir: newSnapshot, modelID: "old-model"))
        #expect(newHash != oldHash)
        await loop.useSwitchSnapshot(newSnapshot)
        let (client, reader) = await connectSwitchLoop(loop, url: url.mockProviderWebSocketURL())
        defer { reader.cancel(); Task { await client.shutdown() } }
        await client.stageModelSelection(previous.models)
        let request = ProviderModelSwitchRequest(target: try #require(ProcessIdentity.current()),
            models: ["old-model"], timeoutSeconds: 0)
        let switching = Task { await loop.switchModels(request: request) }
        defer { switching.cancel() }
        let validationMessages = try #require(try await mock.waitForSnapshot { !$0.modelsReplacements.isEmpty })
        let validation = try #require(validationMessages.modelsReplacements.first)
        try await mock.pushModelsReplaceAck(.init(requestId: validation.requestId, drainRequestId: validation.drainRequestId,
            validateOnly: true, accepted: true))
        let commitMessages = try #require(try await mock.waitForSnapshot { $0.modelsReplacements.count == 2 })
        let commit = try #require(commitMessages.modelsReplacements.last)
        let applied = try await loop.captureWeightHashForTesting(modelId: "old-model", modelPath: newSnapshot)
        #expect(applied.hash == newHash)
        #expect(!applied.recomputed)
        if dropConnection {
            await mock.dropActiveWebSocket()
        } else {
            try await mock.pushModelsReplaceAck(.init(requestId: commit.requestId, drainRequestId: commit.drainRequestId,
                accepted: false, error: "invalid_models"))
            let rollbackMessages = try #require(try await mock.waitForSnapshot { $0.modelsReplacements.count == 3 })
            let rollback = try #require(rollbackMessages.modelsReplacements.last)
            try await mock.pushModelsReplaceAck(.init(requestId: rollback.requestId, drainRequestId: rollback.drainRequestId,
                accepted: true))
        }
        let result = await switching.value
        #expect(result.outcome == (dropConnection ? .timedOut : .failed))
        #expect(await loop.state.refusingNewWork == dropConnection)
        let expectedHash = dropConnection ? newHash : oldHash
        let expectedSnapshot = dropConnection ? newSnapshot : oldSnapshot
        let kept = try await loop.captureWeightHashForTesting(modelId: "old-model", modelPath: expectedSnapshot)
        #expect(kept.hash == expectedHash)
        #expect(!kept.recomputed)
        #expect(await loop.liveModelHashForTesting("old-model") == expectedHash)
        #expect(await client.currentAdvertisedModels().first?.weightHash == expectedHash)
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
