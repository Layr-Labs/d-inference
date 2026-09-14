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
/// and re-offered later: through the desired-build backoff, AND by the
/// capacity-change event that actually frees the room (a slot unload),
/// because the backoff budget is shorter than the idle-unload horizon.
/// `.verified` still goes out for the refused attempt and the coordinator
/// deduplicates unchanged desired_models pushes, so without a local
/// re-offer nothing would ever advertise the build.
@Suite("Reserve-raise preflight on verified prefetch", .serialized)
struct ReserveRaisePreflightTests {
    private let gib: UInt64 = 1024 * 1024 * 1024
    /// Measured floor (3.5 GiB) — the resident, measured model.
    private let residentModel = "gpt-oss-20b"

    @Test("refused raise is not advertised, schedules a retry, and advertises once the box has room")
    func refusedRaiseRetriesUntilRoom() async throws {
        // A budget a slow CI runner cannot exhaust while the box stays tight:
        // every retry while tight is refused again and re-scheduled, so the
        // assertions below hold at any point of that cycle.
        let fixture = try await makeRefusedPrefetch(
            retryDelays: Array(repeating: .seconds(1), count: 10))
        defer { try? FileManager.default.removeItem(at: fixture.modelDir) }
        let loop = fixture.loop

        // Room appears (a bigger box stands in for an unload freeing memory):
        // the next backoff retry re-verifies, the preflight now passes, and
        // the build is advertised alongside the resident one.
        await loop.setEngineV2SlotHooksForTesting(makeHooks(physical: 128 * gib))
        let advertised = await waitUntil(timeout: .seconds(30)) {
            await loop.isModelAdvertised(fixture.newModelID)
        }
        #expect(advertised)
        #expect(fixture.prefetcher.count >= 2)
        #expect(await loop.isModelAdvertised(residentModel))
        let settled = await waitUntil(timeout: .seconds(5)) {
            await loop.pendingDesiredPrefetchRetriesForTesting() == 0
        }
        #expect(settled)
    }

    @Test("refused raise is re-offered by the unload that frees the room, even after the backoff budget")
    func refusedRaiseIsReofferedWhenTheResidentSlotUnloads() async throws {
        // A backoff far longer than the test: only the capacity-change
        // re-offer can advertise the build inside the timeout below.
        let fixture = try await makeRefusedPrefetch(retryDelays: [.seconds(600)])
        defer { try? FileManager.default.removeItem(at: fixture.modelDir) }
        let loop = fixture.loop

        // The resident slot unloads (the idle monitor's job in production):
        // no survivors, the preflight passes, and the deferred build is
        // re-offered immediately with a fresh budget — no 600 s wait.
        await loop.unloadModel(residentModel)
        let advertised = await waitUntil(timeout: .seconds(20)) {
            await loop.isModelAdvertised(fixture.newModelID)
        }
        #expect(advertised)
        #expect(fixture.prefetcher.count >= 2)
        #expect(await loop.reserveDeferredPrefetchesForTesting().isEmpty)
    }

    // MARK: - Fixture

    private struct RefusedPrefetchFixture {
        let loop: ProviderLoop
        let prefetcher: CountingSuccessPrefetcher
        let newModelID: String
        let modelDir: URL
    }

    /// Box arithmetic, self-checked against the real floors and cap so the
    /// test tracks the tables rather than restating them: the resident floor
    /// must leave a serviceable grant, the raised floor must not. Installs
    /// the resident measured slot through the production-shaped load
    /// stretch, reconciles a desired UNMEASURED build, and returns once the
    /// refusal has been observed (build not advertised, one retry pending).
    private func makeRefusedPrefetch(retryDelays: [Duration]) async throws -> RefusedPrefetchFixture {
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

        let startup = ModelInfo(
            id: residentModel, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [startup])
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setEngineV2SlotHooksForTesting(makeHooks(physical: physical))
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
        await loop.setDesiredPrefetchRetryDelaysForTesting(retryDelays)

        let entry = CoordinatorMessage.DesiredModelEntry(
            modelName: "alias", desiredBuild: newModelID, previousBuild: nil)
        await loop.reconcileDesiredModelsForTesting([entry], send: send)

        // Refused: the bytes verified (at least once), the build is NOT
        // advertised, the resident model still is, a desired-build retry is
        // pending, and the id is remembered for the capacity-change re-offer.
        let retryScheduled = await waitUntil(timeout: .seconds(10)) {
            await loop.pendingDesiredPrefetchRetriesForTesting() == 1
        }
        #expect(retryScheduled)
        #expect(prefetcher.count >= 1)
        #expect(!(await loop.isModelAdvertised(newModelID)))
        #expect(await loop.isModelAdvertised(residentModel))
        #expect(await loop.reserveDeferredPrefetchesForTesting().contains(newModelID))

        return RefusedPrefetchFixture(
            loop: loop, prefetcher: prefetcher, newModelID: newModelID, modelDir: modelDir)
    }

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
