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
