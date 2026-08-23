import Foundation
import Testing

@testable import ProviderCore
/// Prefetcher that records whether it was invoked so the already-available
/// short-circuit test can prove that no download starts.
private final class TrackingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var callCount: Int { lock.withLock { _count } }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _count += 1 }
    }
}

/// Prefetcher that always fails and counts attempts per model for the two
/// desired-build retry-policy tests below.
private final class FailingCountingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let called = AsyncTestLatch()

    func count(for modelID: String) -> Int {
        lock.withLock { counts[modelID] ?? 0 }
    }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { counts[modelID, default: 0] += 1 }
        called.signal()
        throw ModelCatalogError.downloadFailed("simulated transient network failure")
    }

    func waitForCall() async { await called.wait() }
}


@Suite("ProviderLoop prefetch integration", .serialized)
struct ProviderLoopPrefetchTests {

    /// Seed a minimal valid MLX snapshot (config.json + one .safetensors) in the
    /// HuggingFace cache so the scanner + WeightHasher can read it.
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

    private func makeLoop(models: [ModelInfo], maxModelSlots: UInt64 = 2) throws -> ProviderLoop {
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
                provider: ProviderSettings(name: "prefetch-unit-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: maxModelSlots),
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

    @Test("verified prefetch advertises the new build and records its weight hash")
    func verifiedPrefetchAdvertisesAndHashes() async throws {
        let startupModel = ModelInfo(id: "org/startup", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/prefetched-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let loop = try makeLoop(models: [startupModel])
        let client = makeClient()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        // Capture outbound messages so we can assert a `models_update` is emitted
        // on verify (the authoritative ModelInfo + weight hash for the coordinator
        // to cross-check before routing). This is the SAME send handle used for
        // prefetch status, injected here for the test.
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Before: only the startup model is advertised.
        let beforeCount = await loop.advertisedModelCount()
        #expect(beforeCount == 1)
        let newAdvertisedBefore = await loop.isModelAdvertised(newModelID)
        #expect(!newAdvertisedBefore)

        // Fire a prefetch via the real handler.
        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)

        // Wait for the new build to be advertised (verified → re-advertise hook).
        await outbound.waitForTerminal(modelID: newModelID)
        #expect(await loop.isModelAdvertised(newModelID))
        // Both startup and prefetched are advertised (transition keeps old).
        let afterCount = await loop.advertisedModelCount()
        #expect(afterCount == 2)
        #expect(await loop.isModelAdvertised("org/startup"))
        // The coordinator client also learned the new build for the next register.
        let clientModels = await client.currentAdvertisedModels().map(\.id)
        #expect(clientModels.contains(newModelID))
        // The weight hash was recorded so attestation/challenge covers the
        // hotswapped model (finding 2 fix).
        let recordedHash = await loop.modelHashForTesting(newModelID)
        #expect(recordedHash != nil && !(recordedHash!.isEmpty))
        // And it rides on the advertised ModelInfo for reconnect registration.
        let advertisedInfo = await client.currentAdvertisedModels().first { $0.id == newModelID }
        #expect(advertisedInfo?.weightHash == recordedHash)

        // A `models_update` outbound message was emitted carrying the build id
        // AND a non-empty weight hash (the security-gap fix: the coordinator can
        // now cross-check the verified build's hash before routing).
        let emittedUpdate = outbound.modelsUpdates().contains { models in
            models.contains { $0.id == newModelID }
        }
        #expect(emittedUpdate)
        let updatedInfo = outbound.modelsUpdates()
            .flatMap { $0 }
            .first { $0.id == newModelID }
        #expect(updatedInfo != nil)
        #expect(updatedInfo?.weightHash == recordedHash)
        #expect(!(updatedInfo?.weightHash?.isEmpty ?? true))
    }

    @Test("verified prefetch whose snapshot can't be scanned is NOT advertised")
    func verifiedPrefetchUnscannableSnapshotNotAdvertised() async throws {
        // The prefetch reports verified (download succeeded) but NO snapshot is on
        // disk, so `scanVerifiedModelInfo` returns nil. The provider must NOT
        // advertise a synthetic zero-size ModelInfo (which would be routed with
        // estimatedMemoryGb == 0, bypassing memory sizing) — it advertises nothing
        // and emits no models_update, so the coordinator never routes the build.
        let startupModel = ModelInfo(id: "org/startup", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/unscannable-\(UUID().uuidString)"
        // Deliberately do NOT seed a snapshot; make sure no stray dir exists.
        let modelDir = ModelDownloader.cacheModelDirectory(for: newModelID)
        try? FileManager.default.removeItem(at: modelDir)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let loop = try makeLoop(models: [startupModel])
        let client = makeClient()
        let verifiedCalls = AdvertisedRecorder()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(), // "downloads" without touching disk
            preCheck: { _ in .needsFetch },
            onVerified: { id in
                await loop.applyVerifiedPrefetch(modelId: id)
                verifiedCalls.record(id) // record AFTER applyVerifiedPrefetch completes
            }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)

        // Wait until the verify→applyVerifiedPrefetch hook has fully run.
        await verifiedCalls.waitUntilRecorded(newModelID)

        // It must NOT have advertised the unscannable build, anywhere.
        #expect(!(await loop.isModelAdvertised(newModelID)))
        #expect(await loop.advertisedModelCount() == 1) // only the startup model
        #expect(!(await client.currentAdvertisedModels().map(\.id).contains(newModelID)))
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == newModelID })
    }

    @Test("verified prefetch raises the effective slot cap so old+new can be resident together")
    func verifiedPrefetchRaisesEffectiveSlotCap() async throws {
        let startupModel = ModelInfo(id: "org/startup", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/prefetched-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Operator default: 3 concurrent slots. A provider that boots advertising
        // ONE model used to freeze its cap at 1 (PR #283 P2 bug) and could not
        // hold a prefetched build alongside the one it serves.
        let loop = try makeLoop(models: [startupModel], maxModelSlots: 3)
        let client = makeClient()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Before: one model advertised, so the effective cap is 1.
        let beforeCap = await loop.maxModelSlotsForTesting()
        #expect(beforeCap == 1)

        // Fire a prefetch; wait for the new build to become advertised.
        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)
        await outbound.waitForTerminal(modelID: newModelID)
        #expect(await loop.isModelAdvertised(newModelID))

        // After: two models advertised, so the effective cap rose to 2 (≤ the
        // configured hard cap of 3) — old and new can be resident concurrently.
        let afterCap = await loop.maxModelSlotsForTesting()
        #expect(afterCap == 2)
        #expect(await loop.advertisedModelCount() == 2)
    }

    @Test("effective slot cap never exceeds the operator-configured hard cap")
    func effectiveSlotCapHonorsHardCap() async throws {
        let startupModel = ModelInfo(id: "org/startup", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/prefetched-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Operator opted out of concurrency with a hard cap of 1.
        let loop = try makeLoop(models: [startupModel], maxModelSlots: 1)
        let client = makeClient()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        #expect(await loop.maxModelSlotsForTesting() == 1)

        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)
        await outbound.waitForTerminal(modelID: newModelID)
        #expect(await loop.isModelAdvertised(newModelID))
        // Two models advertised, but the cap stays at 1: the configured hard cap
        // (memory-safety opt-out) is never exceeded.
        #expect(await loop.advertisedModelCount() == 2)
        #expect(await loop.maxModelSlotsForTesting() == 1)
    }

    @Test("prefetch of an already-advertised+hashed model short-circuits to verified")
    func alreadyHashedShortCircuits() async throws {
        let modelID = "org/already-hashed"
        let startup = ModelInfo(id: modelID, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1, weightHash: "abc123")
        // Seed config with a known hash so the pre-check sees a recorded hash.
        let loop = try makeLoopWithHashes(models: [startup], hashes: [modelID: "abc123"])
        let client = makeClient()
        let prefetcher = TrackingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        await loop.installPrefetchCoordinatorForTesting(coord, client: client)

        let recorder = RecordingSink()
        await coord.handlePrefetch(modelId: modelID, priority: 1, sink: recorder)
        _ = await recorder.waitForTerminal()
        #expect(recorder.terminal()?.status == .verified)
        // The prefetcher was NEVER invoked (short-circuit on recorded hash).
        #expect(prefetcher.callCount == 0)
    }

    @Test("desired_models for a build the provider lacks triggers a prefetch of the desired build")
    func desiredModelsTriggersPrefetchOfMissingBuild() async throws {
        // A brand-new provider advertises nothing yet for this alias. It receives
        // a desired_models entry naming a build it does not have on disk; the
        // declarative reconcile must kick off a background prefetch OF THE DESIRED
        // BUILD (not the previous one).
        let desiredBuild = "org/desired-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"

        let loop = try makeLoop(models: [])
        let client = makeClient()
        // .blockUntilCancelled lets us assert the prefetch STARTED for the desired
        // build without racing a completion; we cancel via shutdown at the end.
        let prefetcher = RecordingBlockingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // The desired build's download body started; the previous build was never
        // prefetched (it's only the drop target, not a fetch target).
        await prefetcher.waitUntilStarted(desiredBuild)
        #expect(!prefetcher.startedIDs.contains(previousBuild))
        let inflight = await coord.inFlightCount()
        #expect(inflight == 1)

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("applyVerifiedPrefetch hard-swaps: advertises desired, drops previous from advertisedModels + store, emits models_update")
    func applyVerifiedPrefetchHardSwapsDroppingPrevious() async throws {
        // Seed the on-disk snapshot for the DESIRED build so applyVerifiedPrefetch
        // can scan + hash it. The PREVIOUS build is advertised at startup (loop)
        // and in the client's AdvertisedModelStore, so we can observe the drop.
        let desiredBuild = "org/desired-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: desiredBuild)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let previousInfo = ModelInfo(id: previousBuild, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [previousInfo], maxModelSlots: 3)
        let client = makeClient()
        // Mirror startup advertising into the client store so the hard-swap drop
        // (unadvertiseModel) has something to remove there too.
        _ = await client.advertiseModel(previousInfo)

        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Before: only the previous build is advertised, on both the loop and the
        // client store.
        #expect(await loop.isModelAdvertised(previousBuild))
        #expect(await client.currentAdvertisedModels().map(\.id).contains(previousBuild))
        #expect(await loop.advertisedModelCount() == 1)

        // Reconcile records previous→desired as the swap target, then prefetches
        // the (missing) desired build. On .verified, applyVerifiedPrefetch fires.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // Wait for the hard swap to settle: desired advertised, previous dropped.
        await outbound.waitForTerminal(modelID: desiredBuild)
        #expect(await loop.isModelAdvertised(desiredBuild))
        #expect(!(await loop.isModelAdvertised(previousBuild)))

        // Desired is now the only advertised build on the loop.
        #expect(await loop.isModelAdvertised(desiredBuild))
        #expect(!(await loop.isModelAdvertised(previousBuild)))
        #expect(await loop.advertisedModelCount() == 1)
        // The desired build carries a recorded weight hash (attestation coverage).
        let desiredHash = await loop.modelHashForTesting(desiredBuild)
        #expect(desiredHash != nil && !(desiredHash!.isEmpty))
        // The previous build's hash was forgotten on drop.
        #expect(await loop.modelHashForTesting(previousBuild) == nil)

        // The previous build was also dropped from the client's advertised store
        // (so the next register no longer announces it); desired is now present.
        let clientIDs = await client.currentAdvertisedModels().map(\.id)
        #expect(clientIDs.contains(desiredBuild))
        #expect(!clientIDs.contains(previousBuild))

        // An authoritative models_update was emitted carrying the DESIRED build
        // (with its hash) — this is the wire signal the coordinator uses to derive
        // the previous-build drop from the alias's desired/previous pair.
        let emitted = outbound.modelsUpdates().contains {
            models in models.contains { $0.id == desiredBuild }
        }
        #expect(emitted)
        let desiredUpdate = outbound.modelsUpdates().flatMap { $0 }.first { $0.id == desiredBuild }
        #expect(desiredUpdate?.weightHash == desiredHash)
        // No emitted models_update advertised the previous build as a fresh build.
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == previousBuild })

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("desired already converged but previous learned LATE drops previous AND re-emits models_update")
    func reconcileAlreadyConvergedLatePreviousEmitsUpdate() async throws {
        // Models a real sequence: the provider verified the desired build BEFORE
        // any previous build was set on the alias (so the original verify carried
        // no drop). Later the operator sets previous_build; desired_models now
        // names desired (already advertised+hashed) + previous (still advertised).
        // The reconcile must drop previous locally AND re-emit an authoritative
        // models_update for desired — otherwise the coordinator keeps routing the
        // previous build to a provider that has locally stopped serving it.
        let desiredBuild = "org/desired-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: desiredBuild)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let previousInfo = ModelInfo(id: previousBuild, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [previousInfo], maxModelSlots: 3)
        let client = makeClient()
        _ = await client.advertiseModel(previousInfo)

        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Step 1: converge desired with NO previous on the alias yet — verify it.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(modelName: "alias-a", desiredBuild: desiredBuild)],
            send: capturingSend
        )
        await outbound.waitForTerminal(modelID: desiredBuild)
        #expect(await loop.isModelAdvertised(desiredBuild))
        #expect(await loop.modelHashForTesting(desiredBuild) != nil)
        // Previous is still advertised (no drop happened — it wasn't in the alias).
        #expect(await loop.isModelAdvertised(previousBuild))
        let updatesAfterConverge = outbound.modelsUpdates().count

        // Step 2: the operator sets previous_build; desired_models now carries it.
        // Desired is already advertised+hashed, so we hit the already-converged path.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // Previous is dropped locally AND from the client store.
        #expect(!(await loop.isModelAdvertised(previousBuild)))
        #expect(!(await client.currentAdvertisedModels().map(\.id).contains(previousBuild)))
        #expect(await loop.isModelAdvertised(desiredBuild))

        // A FRESH models_update for the desired build was emitted on the
        // already-converged path (so the coordinator derives the previous drop).
        #expect(outbound.modelsUpdates().count > updatesAfterConverge)
        let latest = outbound.modelsUpdates().suffix(from: updatesAfterConverge).flatMap { $0 }
        #expect(latest.contains { $0.id == desiredBuild })
        #expect(!latest.contains { $0.id == previousBuild })

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("late verify for stale desired build is ignored after alias retarget")
    func staleDesiredPrefetchVerifyIsIgnoredAfterRetarget() async throws {
        let staleDesired = "org/stale-\(UUID().uuidString)"
        let currentBuild = "org/current-\(UUID().uuidString)"
        let newDesired = "org/new-\(UUID().uuidString)"
        let staleDir = try seedSnapshot(modelID: staleDesired)
        defer { try? FileManager.default.removeItem(at: staleDir) }

        let currentInfo = ModelInfo(id: currentBuild, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [currentInfo], maxModelSlots: 3)
        let client = makeClient()
        _ = await client.advertiseModel(currentInfo)

        let prefetcher = RecordingBlockingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: staleDesired,
                previousBuild: currentBuild
            )],
            send: capturingSend
        )
        await prefetcher.waitUntilStarted(staleDesired)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: newDesired,
                previousBuild: currentBuild
            )],
            send: capturingSend
        )

        await loop.applyVerifiedPrefetch(modelId: staleDesired)

        #expect(!(await loop.isModelAdvertised(staleDesired)))
        #expect(await loop.isModelAdvertised(currentBuild))
        #expect(await client.currentAdvertisedModels().map(\.id).contains(currentBuild))
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == staleDesired })

        await coord.shutdown(timeout: .seconds(3))
    }

    /// Seed a snapshot with config.json but NO weight files. scanVerifiedModelInfo
    /// returns nil (parseModelInfo requires sizeBytes > 0) — the same guard the
    /// nil-weight-hash case falls into: a verify that can't produce a hashed,
    /// advertisable build. Used to prove neither path strands the previous build.
    private func seedConfigOnlySnapshot(modelID: String) throws -> URL {
        let snapshot = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let refs = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try "local".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        return modelDir
    }

    @Test("a verify that can't produce an advertisable+hashed build keeps the previous build (no strand)")
    func verifiedPrefetchUnhashableKeepsPrevious() async throws {
        // A verify whose snapshot yields no advertisable+hashed ModelInfo (here:
        // no weight files, so scanVerifiedModelInfo returns nil — the same early
        // return the nil-weight-hash guard takes) must NOT advertise/emit the
        // build AND must leave the previous build untouched. Dropping previous
        // here while the build can't be advertised would strand the provider on
        // neither — the coordinator's models_update gate would also reject a
        // hashless build, so the local drop must not run ahead of a real swap.
        let desiredBuild = "org/unhashable-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"
        let modelDir = try seedConfigOnlySnapshot(modelID: desiredBuild)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let previousInfo = ModelInfo(id: previousBuild, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [previousInfo], maxModelSlots: 3)
        let client = makeClient()
        _ = await client.advertiseModel(previousInfo)

        let verifiedCalls = AdvertisedRecorder()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in
                await loop.applyVerifiedPrefetch(modelId: id)
                verifiedCalls.record(id)
            }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // Wait until applyVerifiedPrefetch has fully run.
        await verifiedCalls.waitUntilRecorded(desiredBuild)

        // The hashless desired build is NOT advertised anywhere, and no
        // models_update was emitted for it.
        #expect(!(await loop.isModelAdvertised(desiredBuild)))
        #expect(await loop.modelHashForTesting(desiredBuild) == nil)
        #expect(!(await client.currentAdvertisedModels().map(\.id).contains(desiredBuild)))
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == desiredBuild })
        // The previous build is UNTOUCHED — still serving (no unverifiable swap).
        #expect(await loop.isModelAdvertised(previousBuild))
        #expect(await client.currentAdvertisedModels().map(\.id).contains(previousBuild))

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("a failed desired-build prefetch retries with bounded backoff, and a fresh push resets the budget")
    func failedDesiredPrefetchSchedulesBoundedRetries() async throws {
        // One transient download failure must not strand the provider on the old
        // build: each failure of a still-desired build schedules one retry per
        // configured delay, then gives up until the next desired_models push.
        let desiredBuild = "org/desired-\(UUID().uuidString)"

        let loop = try makeLoop(models: [])
        let client = makeClient()
        let prefetcher = FailingCountingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)
        let sleeper = ControlledTestSleeper()
        await loop.setDesiredPrefetchRetryDelaysForTesting([.seconds(1), .seconds(1)])
        await loop.setDesiredPrefetchSleepForTesting {
            try await sleeper.sleep($0)
        }

        let entry = CoordinatorMessage.DesiredModelEntry(
            modelName: "alias-a", desiredBuild: desiredBuild, previousBuild: nil
        )
        await loop.reconcileDesiredModelsForTesting([entry], send: capturingSend)

        await prefetcher.waitForCall()
        for expectedCount in 2 ... 3 {
            await sleeper.waitForRequest()
            sleeper.resumeNext()
            await prefetcher.waitForCall()
            #expect(prefetcher.count(for: desiredBuild) == expectedCount)
        }
        #expect(prefetcher.count(for: desiredBuild) == 3)
        #expect(await loop.pendingDesiredPrefetchRetriesForTesting() == 0)

        await loop.reconcileDesiredModelsForTesting([entry], send: capturingSend)
        await prefetcher.waitForCall()
        for expectedCount in 5 ... 6 {
            await sleeper.waitForRequest()
            sleeper.resumeNext()
            await prefetcher.waitForCall()
            #expect(prefetcher.count(for: desiredBuild) == expectedCount)
        }
        #expect(prefetcher.count(for: desiredBuild) == 6)

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("a pending prefetch retry is cancelled when the build leaves the desired set")
    func failedDesiredPrefetchRetryStopsAfterRetarget() async throws {
        let oldDesired = "org/old-desired-\(UUID().uuidString)"
        let newDesired = "org/new-desired-\(UUID().uuidString)"

        let loop = try makeLoop(models: [])
        let client = makeClient()
        let prefetcher = FailingCountingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = PrefetchOutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)
        let sleeper = ControlledTestSleeper()
        await loop.setDesiredPrefetchRetryDelaysForTesting([.seconds(1)])
        await loop.setDesiredPrefetchSleepForTesting {
            try await sleeper.sleep($0)
        }

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a", desiredBuild: oldDesired, previousBuild: nil
            )],
            send: capturingSend
        )
        await prefetcher.waitForCall()
        await sleeper.waitForRequest()
        #expect(prefetcher.count(for: oldDesired) == 1)
        #expect(await loop.pendingDesiredPrefetchRetriesForTesting() == 1)

        // Operator retargets the alias before the retry fires: the pending retry
        // for the stale build is cancelled.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a", desiredBuild: newDesired, previousBuild: nil
            )],
            send: capturingSend
        )
        await prefetcher.waitForCall()
        await sleeper.waitForRequest()
        sleeper.resumeNext()
        sleeper.resumeNext()
        await prefetcher.waitForCall()
        #expect(prefetcher.count(for: oldDesired) == 1)

        await coord.shutdown(timeout: .seconds(3))
    }

    private func makeLoopWithHashes(models: [ModelInfo], hashes: [String: String]) throws -> ProviderLoop {
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
                provider: ProviderSettings(name: "prefetch-unit-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            ),
            modelHashes: hashes
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }
}
