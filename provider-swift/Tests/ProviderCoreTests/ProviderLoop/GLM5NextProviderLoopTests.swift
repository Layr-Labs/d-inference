import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Coordinator-mode GLM through `ProviderLoop.ensureModelLoaded` and
/// `unloadModel` over the tiny synthetic GLM artifact: real managed load,
/// protected engine, retirement and unwind. The machine is an M5 Max 256 GB
/// in configuration only; memory admission reads the scripted budget.
private enum GLM5NextProviderLoopHost {
    static let modelID = GLM5NextCoordinatorServing.catalogModelID
    static let hardware = HardwareInfo(
        machineModel: "Mac17,1", chipName: "Apple M5 Max", chipFamily: .m5, chipTier: .max,
        memoryGb: 256, memoryAvailableGb: 240,
        cpuCores: CpuCores(total: 18, performance: 12, efficiency: 6),
        gpuCores: 40, memoryBandwidthGbs: 600)

    struct Catalog: SpecDecCatalogLooking {
        let entry: CatalogModel
        func cachedModel(id: String) async -> CatalogModel? { id == entry.id ? entry : nil }
        func model(id: String) async throws -> CatalogModel? { await cachedModel(id: id) }
        func freshModel(id: String) async throws -> CatalogModel? { await cachedModel(id: id) }
    }

    static func with(
        _ body: (ProviderLoop, GLM5NextProtectedFactoryFixture) async throws -> Void
    ) async throws {
        try await GLM5NextProtectedFactoryFixture.with(
            modelID: modelID, chatTemplate: try GLM5NextManagedFixture.shippedTemplate()
        ) { fixture in
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            let manifest = fixture.plan.weights.manifest
            try ModelDownloader.writeRevisionReceipt(manifest, at: fixture.directory)
            let info = try #require(
                ModelScanner.parseModelInfo(snapshotDir: fixture.directory, modelName: modelID))
            // The encrypted prefix store is not under test; keep it off real storage.
            let previousPrefixCache = ProcessInfo.processInfo.environment[PrefixCachePolicy.environmentFlag]
            setenv(PrefixCachePolicy.environmentFlag, "0", 1)
            defer {
                if let previousPrefixCache {
                    setenv(PrefixCachePolicy.environmentFlag, previousPrefixCache, 1)
                } else {
                    unsetenv(PrefixCachePolicy.environmentFlag)
                }
            }
            let loop = try await ModelLoadingFixtures.makeLoop(
                sandbox: sandbox, models: [info],
                physicalBytes: ProcessInfo.processInfo.physicalMemory, hardware: hardware,
                runtimeCapabilities: [.appleM5, .mlxNAX, .glm5Next, .modelRevisions], mtpMode: .auto)
            await loop.setLoadedModelsFileForTesting(sandbox.loadedModelsFile)
            let catalog = CatalogModel(
                id: modelID, s3Name: manifest.r2Prefix, displayName: "Z.ai: GLM-5.3-Flash", sizeGb: 1,
                version: manifest.version, r2Prefix: manifest.r2Prefix,
                aggregateSHA256: manifest.aggregateSHA256, maxContextLength: 1536,
                requiredProviderCapabilities: [.appleM5, .mlxNAX])
            await loop.setSpecDecFunnelForTesting(
                SpecDecArtifactFunnel(resolver: SpecDecResolver(), catalog: Catalog(entry: catalog)))
            #expect(await loop.isModelAdvertised(modelID))
            try await body(loop, fixture)
        }
    }

    static func load(_ loop: ProviderLoop, _ fixture: GLM5NextProtectedFactoryFixture) async throws {
        try await loop.ensureModelLoaded(modelId: modelID, revisionDirectory: fixture.directory)
    }
}

/// Counts full weight reads behind load-time hash captures.
private final class LoadHashReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func record() { lock.withLock { reads += 1 } }
}

/// Parks one pre-submit host consumer until released.
private actor PreSubmitGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false
    private var arrived = false

    func park() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { parked = $0 }
    }

    var hasArrived: Bool { arrived }
    var isReleased: Bool { released }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }
}

@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_PROTECTED_FACTORY"] == "1"))
struct GLM5NextProviderLoopTests {
    /// An unload while a submission is still a host pre-submit consumer gets
    /// the SDK's quiescent receipt, waits for that consumer instead of
    /// retaining a fault, completes, and leaves GLM loadable.
    @Test func unloadWithInFlightSubmissionDrainsAndReloads() async throws {
        try await GLM5NextProviderLoopHost.with { loop, fixture in
            let id = GLM5NextProviderLoopHost.modelID
            try await GLM5NextProviderLoopHost.load(loop, fixture)
            let bridge = try #require(await loop.slotBridgeForTesting(modelId: id))
            #expect(await bridge.hasGLM5NextNativeOwner)
            let gate = PreSubmitGate()
            await bridge._testInstallPreSubmitGate { await gate.park() }
            let submission = Task {
                let stream = await bridge.submitTokenized(
                    promptTokens: Array(repeating: 3, count: 32),
                    request: .init(model: id, messages: [], temperature: 0, max_tokens: 4),
                    requestId: "in-flight", cacheScope: "tenant", cacheEnabled: false,
                    usageSignal: EngineV2RequestUsageSignal())
                for await _ in stream {}
            }
            #expect(await modelLoadingWaitUntil { await gate.hasArrived })

            let unloaded = PreSubmitGate()
            let unload = Task {
                let result = await loop.unloadModel(id)
                await unloaded.release()
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
            // Retirement is waiting on the parked consumer, not retaining it.
            #expect(!(await unloaded.isReleased))
            #expect(!GLM5NextLoadFaultState.isRetained)
            await gate.release()
            #expect(await unload.value)
            await submission.value

            #expect(!GLM5NextLoadFaultState.isRetained)
            #expect(await loop.modelLoadingResidentIDs().isEmpty)
            #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
            try await GLM5NextProviderLoopHost.load(loop, fixture)
            #expect(await loop.modelLoadingResidentIDs() == [id])
            #expect(await loop.unloadModel(id))
            #expect(!GLM5NextLoadFaultState.isRetained)
        }
    }

    /// Cancelling the unload while a consumer is parked does not abandon the
    /// proven-idle retirement or retain a fault: it completes once the
    /// consumer unwinds, and GLM loads again.
    @Test func cancelledUnloadStillCompletesRetirement() async throws {
        try await GLM5NextProviderLoopHost.with { loop, fixture in
            let id = GLM5NextProviderLoopHost.modelID
            try await GLM5NextProviderLoopHost.load(loop, fixture)
            let bridge = try #require(await loop.slotBridgeForTesting(modelId: id))
            let gate = PreSubmitGate()
            await bridge._testInstallPreSubmitGate { await gate.park() }
            let submission = Task {
                let stream = await bridge.submitTokenized(
                    promptTokens: Array(repeating: 3, count: 32),
                    request: .init(model: id, messages: [], temperature: 0, max_tokens: 4),
                    requestId: "cancelled-unload", cacheScope: "tenant", cacheEnabled: false,
                    usageSignal: EngineV2RequestUsageSignal())
                for await _ in stream {}
            }
            #expect(await modelLoadingWaitUntil { await gate.hasArrived })

            let unloaded = PreSubmitGate()
            let unload = Task {
                let result = await loop.unloadModel(id)
                await unloaded.release()
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
            unload.cancel()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!(await unloaded.isReleased))
            #expect(!GLM5NextLoadFaultState.isRetained)
            await gate.release()
            #expect(await unload.value)
            await submission.value

            #expect(!GLM5NextLoadFaultState.isRetained)
            #expect(await loop.modelLoadingResidentIDs().isEmpty)
            #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
            try await GLM5NextProviderLoopHost.load(loop, fixture)
            #expect(await loop.modelLoadingResidentIDs() == [id])
            #expect(await loop.unloadModel(id))
        }
    }

    /// The load publishes its own SHA-256 verification: no `WeightHasher` pass
    /// brackets it, the live (registration) hash is the manifest aggregate,
    /// and the next start's record matches the unchanged files.
    @Test func loadPublishesItsVerifiedDigestWithoutBracketingReads() async throws {
        try await GLM5NextProviderLoopHost.with { loop, fixture in
            let id = GLM5NextProviderLoopHost.modelID
            let reads = LoadHashReads()
            await loop.setLoadWeightHasherForTesting { directory, model in
                reads.record()
                return WeightHasher.computeHash(snapshotDir: directory, modelID: model)
            }
            let records = FileManager.default.temporaryDirectory
                .appendingPathComponent("verified-weights-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: records) }
            await loop.setVerifiedWeightHashesFileForTesting(records)

            try await GLM5NextProviderLoopHost.load(loop, fixture)
            let aggregate = fixture.plan.weights.manifest.aggregateSHA256
            #expect(reads.count == 0)
            #expect(await loop.liveModelHashForTesting(id) == aggregate)
            #expect(VerifiedWeightHashStore.verifiedHash(
                modelID: id, identities: VerifiedWeightHashStore.fileIdentities(snapshotDir: fixture.directory),
                at: records) == aggregate)
            #expect(await loop.unloadModel(id))
        }
    }

    /// A refused publication unwinds the built slot and returns the pending
    /// lease, artifact ownership and load gate; nothing is retained.
    @Test func fullContextRefusalUnwindsCleanly() async throws {
        try await GLM5NextProviderLoopHost.with { loop, fixture in
            let id = GLM5NextProviderLoopHost.modelID
            await loop.setGLM5NextPublicationRefusalForTesting { _ in "forced publication refusal" }
            do {
                try await GLM5NextProviderLoopHost.load(loop, fixture)
                Issue.record("expected the GLM publication to be refused")
            } catch let InferenceError.modelLoadFailed(message) {
                #expect(message.contains("forced publication refusal"))
            }
            #expect(await loop.modelLoadingResidentIDs().isEmpty)
            #expect(await loop.modelLoadingInFlightIDs().isEmpty)
            #expect(await loop.modelLoadingIsLoadingAny() == false)
            #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
            #expect(!GLM5NextLoadFaultState.isRetained)
            // The artifact writer lease came back with the ownership.
            let lease = try ModelArtifactWriteLease.acquireIfAvailable(modelID: id)
            lease.release()

            await loop.setGLM5NextPublicationRefusalForTesting(nil)
            try await GLM5NextProviderLoopHost.load(loop, fixture)
            #expect(await loop.modelLoadingResidentIDs() == [id])
            #expect(await loop.unloadModel(id))
        }
    }

    private struct InjectedRetirementFailure: Error {}

    /// An unproven retirement keeps the slot, its owners and their charge and
    /// refuses further GLM work. Retains process state: isolated run only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_RETAINED_FAULT"] == "1"))
    func unprovenRetirementRetainsFaultAndCharges() async throws {
        try await GLM5NextProviderLoopHost.with { loop, fixture in
            let id = GLM5NextProviderLoopHost.modelID
            try await GLM5NextProviderLoopHost.load(loop, fixture)
            let bridge = try #require(await loop.slotBridgeForTesting(modelId: id))
            try await bridge.installGLM5NextRetirementRefusalForTesting { throw InjectedRetirementFailure() }

            #expect(!(await loop.unloadModel(id)))
            #expect(GLM5NextLoadFaultState.isRetained)
            #expect(GLM5NextLoadFaultState.retainedResidentBytes > 0)
            #expect(await loop.modelLoadingResidentIDs() == [id])
            await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
                try await loop.ensureModelLoaded(modelId: id, revisionDirectory: fixture.directory)
            }
        }
    }
}
