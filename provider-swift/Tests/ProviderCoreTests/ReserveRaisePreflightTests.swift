import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import ProviderCore

/// A verified prefetch of an UNMEASURED build joining a MEASURED serving
/// set raises the shared activation reserve with no new slot loaded. On a
/// box where that raise would re-slice a resident slot below the
/// serviceability floor, the advertisement must be REFUSED (nothing pushed,
/// nothing advertised — the same floor the load path refuses a newcomer on)
/// and RETRIED through the desired-build backoff policy: `.verified` still
/// goes out for the attempt and the coordinator deduplicates unchanged
/// desired_models pushes, so without a local retry nothing would ever
/// re-offer the build, even once the box has room.
@Suite("Reserve-raise preflight on verified prefetch", .serialized)
struct ReserveRaisePreflightTests {
    private let gib: UInt64 = 1024 * 1024 * 1024
    /// Measured floor (3.5 GiB) — the resident, measured model.
    private let residentModel = "gpt-oss-20b"

    @Test("refused raise is not advertised, schedules a retry, and advertises once the box has room")
    func refusedRaiseRetriesUntilRoom() async throws {
        // Box arithmetic, self-checked against the real floors and cap so the
        // test tracks the tables rather than restating them: the resident
        // floor must leave a serviceable grant, the raised floor must not.
        // Production resolves max(env override, floor); the arithmetic below
        // assumes the floors alone, so an operator override in the test
        // environment would fail the resident load loudly but unexplained.
        try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_ACTIVATION_RESERVE_GB"] == nil,
            "DARKBLOOM_ACTIVATION_RESERVE_GB must be unset for this test's box arithmetic")
        let physical: UInt64 = 32 * gib
        let weights: UInt64 = 23 * gib
        let configReserve: UInt64 = 1 * gib  // memoryReserveGB: 1 in makeLoop
        let newModelID = "org/unmeasured-\(UUID().uuidString)"
        let floorResident = UnifiedMemoryCap.activationFloorBytes(forModelIDs: [residentModel])
        let floorRaised = UnifiedMemoryCap.activationFloorBytes(
            forModelIDs: [residentModel, newModelID])
        try #require(floorRaised > floorResident)
        let budgetUnderResident = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: weights,
            activationReserveBytes: floorResident, configReserveBytes: configReserve)
        let budgetUnderRaised = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical, residentWeightBytes: weights,
            activationReserveBytes: floorRaised, configReserveBytes: configReserve)
        try #require(budgetUnderResident >= EngineV2KVSizing.minimumServiceableGrantBytes)
        try #require(budgetUnderRaised < EngineV2KVSizing.minimumServiceableGrantBytes)

        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let startup = ModelInfo(
            id: residentModel, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [startup])
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setEngineV2SlotHooksForTesting(makeHooks(physical: physical))
        // The resident measured slot, installed through the production-shaped
        // load stretch (re-slice gate held across shrink → build → install).
        _ = try await loop.loadV2SlotForTesting(
            modelId: residentModel,
            modelType: "gpt_oss",
            container: makeStubContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: SlotSizingSnapshot(
                weightsBytes: Int(weights),
                fp16KVBytesPerToken: 20_480,
                maxContextLength: 131_072,
                defaultMaxTokens: 4096))

        let client = makeClient()
        let prefetcher = CountingSuccessPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let send = SendHandle { _ in }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: send)
        // A budget a slow CI runner cannot exhaust while the box stays tight:
        // every retry while tight is refused again and re-scheduled, so the
        // assertions below hold at any point of that cycle (no exact counts —
        // a retry may already have fired before the first observation).
        await loop.setDesiredPrefetchRetryDelaysForTesting(
            Array(repeating: .seconds(1), count: 10))

        let entry = CoordinatorMessage.DesiredModelEntry(
            modelName: "alias", desiredBuild: newModelID, previousBuild: nil)
        await loop.reconcileDesiredModelsForTesting([entry], send: send)

        // Refused: the bytes verified (at least once), the build is NOT
        // advertised, the resident model still is, and a desired-build
        // retry is pending.
        let retryScheduled = await waitUntil(timeout: .seconds(10)) {
            await loop.pendingDesiredPrefetchRetriesForTesting() == 1
        }
        #expect(retryScheduled)
        #expect(prefetcher.count >= 1)
        #expect(!(await loop.isModelAdvertised(newModelID)))
        #expect(await loop.isModelAdvertised(residentModel))

        // Room appears (a bigger box stands in for an unload freeing memory):
        // the next retry re-verifies, the preflight now passes, and the
        // build is advertised alongside the resident one.
        await loop.setEngineV2SlotHooksForTesting(makeHooks(physical: 128 * gib))
        let advertised = await waitUntil(timeout: .seconds(30)) {
            await loop.isModelAdvertised(newModelID)
        }
        #expect(advertised)
        #expect(prefetcher.count >= 2)
        #expect(await loop.isModelAdvertised(residentModel))
        let settled = await waitUntil(timeout: .seconds(5)) {
            await loop.pendingDesiredPrefetchRetriesForTesting() == 0
        }
        #expect(settled)
    }

    // MARK: - Fixtures

    private func makeHooks(physical: UInt64) -> ProviderLoop.EngineV2SlotHooks {
        ProviderLoop.EngineV2SlotHooks(
            eosTokenIds: [2],
            physicalMemoryBytes: physical,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) })
    }

    /// Seed a minimal valid MLX snapshot (config.json + one .safetensors) in
    /// the HuggingFace cache so the scanner + WeightHasher can read it.
    private func seedSnapshot(modelID: String) throws -> URL {
        let snapshot = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let refs = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data("fake mlx weight bytes".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try "local".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        return modelDir
    }

    private func makeLoop(models: [ModelInfo]) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: models,
            config: ProviderConfig(
                provider: ProviderSettings(name: "reserve-raise-preflight-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    private func makeClient() -> CoordinatorClient {
        let config = CoordinatorClientConfig(
            url: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [],
            backendName: "mlx-swift"
        )
        return CoordinatorClient(config: config, stats: AtomicProviderStats(), state: ProviderState())
    }

    private func makeStubContainer() -> ModelContainer {
        ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "test/reserve-raise-stub-model"),
                model: PreflightStubLanguageModel(),
                processor: PreflightStubProcessor(),
                tokenizer: StubBridgeTokenizer()
            ))
    }

    private func waitUntil(
        timeout: Duration, _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }
}

// MARK: - Stubs

private final class CountingSuccessPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _count += 1 }
        onByteProgress(10, 10)
    }
}

private final class PreflightStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct PreflightStubProcessorError: Error {}

private struct PreflightStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw PreflightStubProcessorError()
    }
}
