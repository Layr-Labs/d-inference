import Foundation
import Testing
@testable import ProviderCore

/// The operator selected the 8-bit `gemma-4-26b` and deselected
/// `gemma-4-26b-qat-4bit`. The takeover alias `gemma-4-26b` names the QAT build
/// as desired and the 8-bit build as previous, so the coordinator offers the
/// QAT build to every provider that advertises the 8-bit one.
@Suite("Operator enabled-model filter", .serialized)
struct OperatorModelFilterTests {
    private static let selected = "gemma-4-26b"
    private static let deselected = "gemma-4-26b-qat-4bit"
    private static let other = "gpt-oss-20b"
    private static let takeover = CoordinatorMessage.DesiredModelEntry(
        modelName: selected, desiredBuild: deselected, previousBuild: selected)

    private static let hardware = HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    private static func model(_ id: String) -> ModelInfo {
        ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 1024, estimatedMemoryGb: 1,
            weightHash: String(repeating: id == selected ? "a" : "b", count: 64))
    }

    private func loop(enabledModels: [String]) throws -> ProviderLoop {
        let models = [Self.model(Self.selected), Self.model(Self.other)]
        return try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused", hardware: Self.hardware, models: models,
            config: ProviderConfig(provider: ProviderSettings(name: "model-filter-test", memoryReserveGB: 1),
                backend: BackendSettings(enabledModels: enabledModels, idleTimeoutMins: 0)),
            modelHashes: Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.weightHash ?? "") })),
            attestationSigner: nil)
    }

    private func installRecordingPrefetch(_ loop: ProviderLoop) async -> (FilterRecordingPrefetcher, ModelPrefetchCoordinator) {
        let prefetcher = FilterRecordingPrefetcher()
        let coordinator = ModelPrefetchCoordinator(prefetcher: prefetcher, preCheck: { _ in .needsFetch },
            onVerified: { _ in })
        let client = CoordinatorClient(config: CoordinatorClientConfig(url: "ws://127.0.0.1:0/unused",
            hardware: Self.hardware, models: [], backendName: "mlx-swift"),
            stats: AtomicProviderStats(), state: ProviderState())
        await loop.installPrefetchCoordinatorForTesting(coordinator, client: client)
        return (prefetcher, coordinator)
    }

    /// A refused command never starts work, so give a wrongly accepted one
    /// time to reach the prefetcher before asserting nothing did.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    @Test func aTakeoverSuccessorOutsideTheFilterIsNeitherSelectedNorDownloaded() async throws {
        let loop = try loop(enabledModels: [Self.selected, Self.other])
        let (prefetcher, coordinator) = await installRecordingPrefetch(loop)
        await loop.reconcileDesiredModels([Self.takeover], send: SendHandle { _ in })
        try await settle()
        #expect(prefetcher.startedIDs.isEmpty)
        #expect(await !loop.ordinaryServingModelIDs.contains(Self.deselected))
        #expect(await !loop.autopilotAllowsModel(Self.deselected))
        #expect(await loop.desiredPrefetchTargets.isEmpty)
        #expect(await loop.desiredSwapDrop.isEmpty)
        #expect(await loop.isModelAdvertised(Self.selected))
        await coordinator.shutdown(timeout: .seconds(3))
    }

    @Test func loadAndPrefetchCommandsOutsideTheFilterAreRefused() async throws {
        let loop = try loop(enabledModels: [Self.selected, Self.other])
        let (prefetcher, coordinator) = await installRecordingPrefetch(loop)
        let replies = FilterReplyRecorder()
        await loop.handlePrefetchModelRequest(modelId: Self.deselected, priority: 1, send: SendHandle(replies.append))
        await loop.handleLoadModelRequest(modelId: Self.deselected, send: SendHandle(replies.append))
        try await settle()
        #expect(replies.prefetchErrors == ["model_not_selected"])
        #expect(replies.loadErrors == ["model_not_selected"])
        #expect(prefetcher.startedIDs.isEmpty)
        #expect(await loop.preloadTasks.isEmpty)
        await coordinator.shutdown(timeout: .seconds(3))
    }

    @Test func aLiveSwitchMakesTheSwitchedSelectionTheFilter() async throws {
        let loop = try loop(enabledModels: [])
        let (prefetcher, coordinator) = await installRecordingPrefetch(loop)
        await loop.beginServingDrain(owner: .modelSwitch)
        try await loop.applyModelSelection(.init(models: [Self.model(Self.selected)], fingerprints: [:]))
        await loop.reconcileDesiredModels([Self.takeover], send: SendHandle { _ in })
        try await settle()
        #expect(prefetcher.startedIDs.isEmpty)
        #expect(await !loop.ordinaryServingModelIDs.contains(Self.deselected))
        #expect(await loop.isModelAdvertised(Self.selected))
        await coordinator.shutdown(timeout: .seconds(3))
    }

    /// Unchanged: with no filter, or with the successor in it, the alias
    /// successor stays the selected build's update.
    @Test(arguments: [[String](), ["gemma-4-26b", "gpt-oss-20b", "gemma-4-26b-qat-4bit"]])
    func aSuccessorTheFilterAllowsStillConverges(enabledModels: [String]) async throws {
        let loop = try loop(enabledModels: enabledModels)
        let (prefetcher, coordinator) = await installRecordingPrefetch(loop)
        await loop.reconcileDesiredModels([Self.takeover], send: SendHandle { _ in })
        var started = false
        for _ in 0..<300 where !started {
            started = prefetcher.startedIDs == [Self.deselected]
            if !started { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(started)
        #expect(await loop.desiredSwapDrop[Self.deselected] == Self.selected)
        await coordinator.shutdown(timeout: .seconds(3))
    }

    /// The reported machine, end to end through `ProviderLoop.run()` and the
    /// mock coordinator: the production alias entry (the retired
    /// `gemma-4-26b-8bit` only decides who receives it, so it is not on the
    /// wire), then the warm pool's `prefetch_model` and `load_model`. The
    /// coordinator re-sends the entry after every `register` and every switch.
    @Test func theReportedRolloutNeverReachesTheProviderAfterReconnectOrSwitch() async throws {
        let enabled = [Self.selected, "nvidia-nemotron-3.5-lightning", Self.other]
        let fixture = try await ServeLoopFixture.make(models: enabled.map(Self.model),
            backend: BackendSettings(enabledModels: enabled, idleTimeoutMins: 0, startupPreload: false))
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        try await replayRollout(fixture, round: 1)

        await fixture.mock.dropActiveWebSocket()
        let reconnected = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(20)) {
            $0.registers.count == 2
        })
        #expect(reconnected.registers.allSatisfy { Set($0.models.map(\.id)) == Set(enabled) })
        try await replayRollout(fixture, round: 2)

        await fixture.loop.resolveSwitchSnapshots(to: try Self.switchSnapshot(in: fixture.directory))
        let switched = await fixture.loop.switchModels(request: .init(
            target: try #require(ProcessIdentity.current()), models: enabled, timeoutSeconds: 10))
        #expect(switched.outcome == .switched, "\(switched.message ?? "")")
        #expect(Set(fixture.mock.snapshot().modelsReplacements.last?.models.map(\.id) ?? []) == Set(enabled))
        try await replayRollout(fixture, round: 3)

        #expect(await fixture.stop(task))
    }

    private func replayRollout(_ fixture: ServeLoopFixture, round: Int) async throws {
        let rollout = CoordinatorMessage.DesiredModelEntry(modelName: Self.selected, desiredBuild: Self.deselected,
            previousBuild: Self.selected, revision: "qat", aggregateSHA256: String(repeating: "c", count: 64))
        try await fixture.mock.pushDesiredModels([rollout])
        try await fixture.mock.pushPrefetchModel(modelId: Self.deselected, priority: 1)
        try await fixture.mock.pushLoadModel(modelId: Self.deselected)
        _ = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) { captured in
            captured.loadModelStatuses.filter { $0.modelId == Self.deselected && $0.status != .started }.count >= round
                && captured.prefetchModelStatuses.contains { $0.modelId == Self.deselected }
        }, "round \(round): no load_model reply")
        try await settle()
        let captured = fixture.mock.snapshot()
        let loads = captured.loadModelStatuses.filter { $0.modelId == Self.deselected }
        let prefetches = captured.prefetchModelStatuses.filter { $0.modelId == Self.deselected }
        #expect(loads.count == round && loads.allSatisfy { $0.status == .failed && $0.error == "model_not_selected" },
            "round \(round): \(loads)")
        #expect(prefetches.count == round
            && prefetches.allSatisfy { $0.status == .failed && $0.error == "model_not_selected" },
            "round \(round): \(prefetches)")
        #expect(!captured.modelsUpdates.contains { $0.models.contains { $0.id == Self.deselected } })
        let loop = fixture.loop
        #expect(await loop.isModelAdvertised(Self.selected))
        #expect(await !loop.isModelAdvertised(Self.deselected))
        #expect(await !loop.ordinaryServingModelIDs.contains(Self.deselected))
        #expect(await loop.desiredPrefetchTargets.isEmpty)
        #expect(await loop.desiredModelRevisions.isEmpty)
        #expect(await loop.desiredSwapDrop.isEmpty)
        #expect(await loop.preloadTasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ModelDownloader.cacheModelDirectory(for: Self.deselected).path))
    }

    private static func switchSnapshot(in directory: URL) throws -> URL {
        let snapshot = directory.appendingPathComponent("switch-snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 0x61, count: 1024).write(to: snapshot.appendingPathComponent("model.safetensors"))
        return snapshot
    }
}

private extension ProviderLoop {
    func resolveSwitchSnapshots(to snapshot: URL) { modelSwitchSnapshotResolver = { _ in snapshot } }
}

/// Records each build whose download started, then blocks until cancelled.
private final class FilterRecordingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    var startedIDs: [String] { lock.withLock { started } }
    func prefetchToDisk(modelID: String, onByteProgress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        lock.withLock { started.append(modelID) }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FilterReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var prefetchErrors: [String?] {
        lock.withLock { messages.compactMap { if case .prefetchModelStatus(_, _, _, _, let error) = $0 { return .some(error) }; return nil } }
    }
    var loadErrors: [String?] {
        lock.withLock { messages.compactMap { if case .loadModelStatus(_, _, let error) = $0 { return .some(error) }; return nil } }
    }
}
