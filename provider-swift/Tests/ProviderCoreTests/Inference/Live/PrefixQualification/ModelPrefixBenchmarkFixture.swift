import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

final class ModelPrefixBenchmarkFixture {
    let specification: ModelPrefixBenchmarkSpecification
    let container: ModelContainer
    let tokenizer: TokenizerHandle
    let session: EngineV2BenchmarkSession
    let servingModelType: String
    let root: URL

    var schedulerConfiguration: ModelPrefixBenchmarkSchedulerConfiguration {
        let loop = session.rawEngine.loopForTesting
        return loop.onEngineQueueSync {
            ModelPrefixBenchmarkSchedulerConfiguration(loop.scheduler.config)
        }
    }

    /// Forward an explicit specification value through the existing factory
    /// setting. Process-wide diagnostic variables cannot silently change a
    /// frozen benchmark specification or its serving geometry.
    static func checkpointEnvironment(
        root: URL, soloPrefillStripeTokens: Int?
    ) -> [String: String] {
        var environment = ["DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0",
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1", "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": root.path]
        if let stripe = soloPrefillStripeTokens {
            environment[EngineV2Factory.soloPrefillStripeKey] = String(stripe)
        }
        return environment
    }

    init(_ specification: ModelPrefixBenchmarkSpecification) async throws {
        self.specification = specification
        let owned = try await Self.prepare(specification)
        container = owned.container
        tokenizer = owned.tokenizer
        session = owned.session
        servingModelType = owned.servingModelType
        root = owned.root
    }

    struct Owned {
        let container: ModelContainer
        let tokenizer: TokenizerHandle
        let session: EngineV2BenchmarkSession
        let servingModelType: String
        let root: URL
    }

    private static func prepare(_ specification: ModelPrefixBenchmarkSpecification) async throws -> Owned {
        let metallib = try #require(LiveInferenceFixtures.ensureMetallibColocated())
        let boundMetallibHash = try #require(bindRuntimeMetallibForMLX(from: metallib),
            "the source-matched metallib must be bound before Metal initialization")
        _ = try GPUEnforcement.requireMetal()
        let hardware = try HardwareDetector.detect()
        let capabilities = ProviderRuntimeCapabilityDetector.detectPrepared(
            hardware: hardware, boundMetallibHash: boundMetallibHash)
        try ModelRuntimeRequirements.requireEligible(
            modelID: specification.modelID, available: capabilities)
        MLXMemoryGuard.configureOnce()
        Memory.cacheLimit = 1 << 30
        let directory = URL(fileURLWithPath: specification.directory, isDirectory: true)
        let before = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: specification.modelID))
        try #require(before == specification.expectedWeightHash, "the exact catalog artifact must match before load")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("model-prefix-qualification-\(UUID().uuidString)", isDirectory: true)
        let environment = checkpointEnvironment(
            root: root, soloPrefillStripeTokens: specification.soloPrefillStripeTokens)
        if specification.modelType == "mimo_v2" {
            return try await prepareNative(specification, directory: directory, verifiedHash: before,
                root: root, environment: environment)
        }
        let loaded = try await EngineV2Factory.loadBenchmarkContainer(modelID: specification.modelID, directory: directory)
        var createdSession: EngineV2BenchmarkSession?
        do {
            let after = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: specification.modelID))
            try #require(before == after, "artifact bytes changed while loading")
            let tokenizer = await loaded.container.perform { TokenizerHandle($0.tokenizer) }
            let loadedModel = await loaded.container.perform { EngineV2ModelSnapshot(model: $0.model,
                eosTokenIds: $0.configuration.eosTokenIds, extraEOSTokens: $0.configuration.extraEOSTokens.sorted()) }
            let servingModel = try EngineV2Factory.benchmarkServingModel(model: loadedModel.model,
                isVLM: loaded.isVLM, modelDirectory: directory)
            let servingModelType = String(describing: type(of: servingModel))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = try await EngineV2Factory.makeBenchmarkSession(modelId: specification.modelID,
                modelDirectory: directory, isVLM: loaded.isVLM, container: loaded.container,
                tokenizer: tokenizer, verifiedWeightHash: after, kvBytesCapacity: 1 << 30,
                maxConcurrentRequests: 1, mtpEnabled: specification.mtpEnabled ?? false,
                checkpointPartition: specification.checkpointPartition == "demanded_recurrent_qualification"
                    ? .demandedRecurrentQualification : .production,
                useProductionKVGrant: true,
                kvBackendConfig: "auto", requirePersistentKey: false, environment: environment)
            createdSession = session
            let cache = await session.cacheSnapshot()
            try #require(cache.status.state == .ready && cache.durableMode == "ssd_complete")
            try #require(cache.keyMode == "ephemeral" && !cache.memoryEnabled)
            try #require(session.backendFallback == nil)
            return Owned(container: loaded.container, tokenizer: tokenizer, session: session,
                servingModelType: servingModelType, root: root)
        } catch {
            await createdSession?.shutdown()
            await EngineV2Factory.releaseBenchmarkContainer(loaded.container)
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func promptTokens(count: Int, variant: Int = 0) -> [Int] {
        // Fixed native token IDs isolate physical prefix reuse. They do not
        // claim chat-template quality or any model's natural stopping behavior.
        (0..<count).map { 37 + (($0 * 7 + variant * 23) % 400) }
    }

    func forkTokens(_ cell: ModelPrefixBenchmarkSpecification.Case) -> [Int] {
        promptTokens(count: cell.sharedTokens)
            + promptTokens(count: cell.forkTokens - cell.sharedTokens, variant: 1)
    }

    func close() async throws {
        try await session.shutdownReportingCompletion()
        await EngineV2Factory.releaseBenchmarkContainer(container)
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
        try FileManager.default.removeItem(at: root)
        Memory.clearCache()
    }

    func requireIdle() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let capacity = session.rawEngine.capacity()
            if capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw IdleFailure.notDrained
    }

    enum IdleFailure: Error { case notDrained }
}
