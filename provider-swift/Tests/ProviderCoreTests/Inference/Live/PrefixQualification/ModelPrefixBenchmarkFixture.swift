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
    let persistentTestNamespace: SSDPersistentTestKeyNamespace?
    private var installedPrefillTrace: ModelCheckpointPrefillTrace?

    // Fixtures submit serially. Install only at the first idle use; all later
    // request begin/end operations are host-only even after a watchdog failure.
    func prefillTraceRecorder() throws -> ModelCheckpointPrefillTrace {
        if let installedPrefillTrace { return installedPrefillTrace }
        let recorder = try ModelCheckpointPrefillTrace(engine: session.rawEngine)
        installedPrefillTrace = recorder
        return recorder
    }

    var schedulerConfiguration: ModelPrefixBenchmarkSchedulerConfiguration {
        let loop = session.rawEngine.loopForTesting
        return loop.onEngineQueueSync {
            ModelPrefixBenchmarkSchedulerConfiguration(loop.scheduler.config)
        }
    }

    /// Forward an explicit specification value through the existing factory
    /// setting. Process-wide diagnostic variables cannot silently change a
    /// frozen benchmark specification or its serving geometry. Specifications
    /// pinned a stripe above the SDK's plain chunk, which a wide-chunk family
    /// would otherwise swallow, so a pinned stripe also pins that chunk.
    static func checkpointEnvironment(
        root: URL, soloPrefillStripeTokens: Int?
    ) -> [String: String] {
        var environment = ["DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0",
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1", "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": root.path]
        if let stripe = soloPrefillStripeTokens {
            let sdk = CBv2SchedulerConfig()
            environment[EngineV2Factory.soloPrefillStripeKey] = String(stripe)
            environment[EngineV2Factory.prefillChunkKey] = String(sdk.prefillChunkSize)
            environment[EngineV2Factory.stepTokenBudgetKey] = String(sdk.maxBatchedTokensPerStep)
        }
        return environment
    }

    init(_ specification: ModelPrefixBenchmarkSpecification,
         persistentRoot: URL? = nil,
         persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
         maximumStageMegabytes: Int? = nil) async throws {
        self.specification = specification
        self.persistentTestNamespace = persistentTestNamespace
        let owned = try await Self.prepare(specification, persistentRoot: persistentRoot,
            persistentTestNamespace: persistentTestNamespace, maximumStageMegabytes: maximumStageMegabytes)
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

    private static func prepare(_ specification: ModelPrefixBenchmarkSpecification,
                                persistentRoot: URL?,
                                persistentTestNamespace: SSDPersistentTestKeyNamespace?,
                                maximumStageMegabytes: Int?) async throws -> Owned {
        try specification.validate()
        guard (persistentRoot == nil) == (persistentTestNamespace == nil) else {
            throw SSDPersistentTestKeyNamespace.Failure.isolatedRootRequired
        }
        let root = persistentRoot ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("model-prefix-qualification-\(UUID().uuidString)", isDirectory: true)
        var environment = checkpointEnvironment(
            root: root, soloPrefillStripeTokens: specification.soloPrefillStripeTokens)
        if let persistentTestNamespace {
            environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1"
            try persistentTestNamespace.validate(environment: environment)
        }
        if let maximumStageMegabytes {
            environment["DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB"] = String(maximumStageMegabytes)
        }
        let directory = URL(fileURLWithPath: specification.directory, isDirectory: true)
        struct Declaration: Decodable {
            let modelType: String
            enum CodingKeys: String, CodingKey { case modelType = "model_type" }
        }
        let declaration = try JSONDecoder().decode(Declaration.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        try #require(declaration.modelType == specification.modelType,
            "the specification must identify the actual loaded model family")
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
        let before = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: specification.modelID))
        try #require(before == specification.expectedWeightHash, "the exact catalog artifact must match before load")
        if specification.modelType == "mimo_v2" {
            try #require(persistentTestNamespace == nil,
                "MiMo process-restart qualification requires its separate owned native harness")
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
                kvBackendConfig: specification.resolvedKVBackend,
                kvQuantizationConfig: specification.resolvedLiveKVQuantization,
                checkpointQuantizationConfig: specification.resolvedCheckpointQuantization,
                requirePersistentKey: persistentTestNamespace != nil,
                persistentTestNamespace: persistentTestNamespace, environment: environment)
            createdSession = session
            let cache = await session.cacheSnapshot()
            try #require(cache.status.state == .ready && cache.durableMode == "ssd_complete")
            try #require(cache.keyMode == (persistentTestNamespace == nil ? "ephemeral" : "persistent")
                && !cache.memoryEnabled)
            try #require(session.backendFallback == nil)
            return Owned(container: loaded.container, tokenizer: tokenizer, session: session,
                servingModelType: servingModelType, root: root)
        } catch {
            await createdSession?.shutdown()
            await EngineV2Factory.releaseBenchmarkContainer(loaded.container)
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            if persistentTestNamespace == nil { try? FileManager.default.removeItem(at: root) }
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
        if persistentTestNamespace == nil { try FileManager.default.removeItem(at: root) }
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
