import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot model set and downloads", .serialized)
struct AutopilotDownloadTests {
    private typealias Fixture = AutopilotDownloadFixture
    private static let downloaded = "darkbloom-test/downloaded-model"
    private static let cached = "darkbloom-test/cached-model"

    private static func model(_ id: String, hash: String = String(repeating: "b", count: 64)) -> ModelInfo {
        ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 1 << 20, estimatedMemoryGb: 0.01, weightHash: hash)
    }

    // MARK: - The effective set

    @Test func withConsentTheSetIsThePersistedSelectionPlusCachedBuilds() async throws {
        let fixture = try await Fixture.make(inventory: [Self.model(Self.cached)])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.selectedModels == [Self.cached, Fixture.saved].sorted())
        #expect(snapshot.revision == Fixture.revision)
        #expect(snapshot.capabilities?.contains("inventory_downloads") == true)
        #expect(await loop.autopilotSetAllows(Self.cached))
        #expect(await loop.autopilotSetAllows(Fixture.saved))
        #expect(await loop.autopilotSetAllows("darkbloom-test/elsewhere") == false)

        // The persisted selection no longer bounds operations: a cached build
        // is a valid target, and a resident one a valid victim.
        await loop.activateDownloadLeaseForTesting()
        let live = try #require(await loop.state.modelAutopilot)
        let target = ModelAutopilotCommand(commandId: "cached-target", loadModelId: Self.cached,
            expiresAtMs: ProviderLoop.autopilotNowMs + 60_000, sessionId: "session", revision: Fixture.revision)
        #expect(ModelAutopilotPolicy.rejection(command: target, snapshot: live, busy: false,
            nowMs: ProviderLoop.autopilotNowMs) == nil)
        var outside = target
        outside.loadModelId = "darkbloom-test/elsewhere"
        #expect(ModelAutopilotPolicy.rejection(command: outside, snapshot: live, busy: false,
            nowMs: ProviderLoop.autopilotNowMs) == "model_not_selected")
    }

    /// Removing a build from the operator's saved selection does not take a
    /// verified cached build out of the set; leaving the cache does.
    @Test func aCachedBuildStaysInTheSetUntilItLeavesTheCache() async throws {
        let fixture = try await Fixture.make(inventory: [Self.model(Self.cached)])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.updateAutopilotSettingsForTesting { $0.selectedModels = [Fixture.saved, Self.cached] }
        await loop.updateAutopilotSettingsForTesting { $0.selectedModels = [Fixture.saved] }
        #expect(await loop.autopilotSetAllows(Self.cached))
        // Its files are gone: the next sweep drops it; the saved selection stays.
        await loop.sweepAutopilotCachedBuilds()
        #expect(await loop.autopilotSetAllows(Self.cached) == false)
        #expect(await loop.state.modelAutopilot?.selectedModels == [Fixture.saved])
    }

    @Test func theCacheSweepKeepsTheSavedResidentAndPresentBuildsAndRunsOnceAMinute() async throws {
        let present = "darkbloom-test/present-model"
        let fixture = try await Fixture.make(inventory: [Self.model(Self.cached), Self.model(present),
                                                          Self.model(Fixture.saved)])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        try fixture.writeBuild(present)
        let start = ContinuousClock.now
        await loop.sweepAutopilotCachedBuilds(now: start)
        #expect(await loop.state.modelAutopilot?.selectedModels == [Fixture.saved, present].sorted())
        try fixture.removeBuild(present)
        await loop.sweepAutopilotCachedBuilds(now: start + .seconds(59))
        #expect(await loop.autopilotSetAllows(present))
        await loop.sweepAutopilotCachedBuilds(now: start + .seconds(60))
        #expect(await loop.autopilotSetAllows(present) == false)
        #expect(await loop.autopilotSetAllows(Fixture.saved))
    }

    /// No saved consent, or saved consent on a private-only machine: the
    /// report keeps the persisted list and a refused prefetch keeps its exact
    /// reply. Nothing is downloaded on the operator's behalf.
    @Test(arguments: [false, true])
    func withoutConsentTheReportAndPrefetchRepliesAreUnchanged(privateOnly: Bool) async throws {
        let fixture = try await Fixture.make(consent: privateOnly, privateOnly: privateOnly,
            inventory: [Self.model(Self.cached)])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.selectedModels == [Fixture.saved])
        #expect(snapshot.capabilities == nil)
        #expect(await loop.autopilotSetAllows(Self.cached) == false)
        #expect(await loop.prefetchForTesting(Self.cached).all == [.init(status: .failed, error: "model_not_selected")])
        if privateOnly {
            #expect(await loop.prefetchForTesting(Self.downloaded).all
                == [.init(status: .failed, error: "model_not_selected")])
        }
        #expect(await loop.autopilotDownloadCoordinator == nil)
    }

    // MARK: - Downloads on the operator's behalf

    @Test func aVerifiedDownloadJoinsTheSetPersistsAndIsNeitherAdvertisedNorLoaded() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let log = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.autopilotSetAllows(Self.downloaded) == false)

        let replies = await loop.prefetchForTesting(Self.downloaded)
        #expect(replies.statuses.first == .started)
        #expect(replies.terminal == .init(status: .verified, error: nil))
        #expect(log.started == [Self.downloaded])

        let hash = try #require(fixture.scannedBuild(Self.downloaded)?.weightHash)
        #expect(await loop.autopilotSetAllows(Self.downloaded))
        #expect(await loop.state.modelAutopilot?.selectedModels == [Self.downloaded, Fixture.saved].sorted())
        #expect(await loop.state.modelAutopilot?.revision == Fixture.revision)
        #expect(await loop.autopilotInventoryModels[Self.downloaded]?.weightHash == hash)
        #expect(await loop.liveModelHashForTesting(Self.downloaded) == hash)
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.downloaded])
        #expect(fixture.ledger.weightHashes == [Self.downloaded: hash])
        // Never advertised or loaded: only an Autopilot operation loads it.
        #expect(await loop.isModelAdvertised(Self.downloaded) == false)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
        #expect(await loop.autopilotServesModel(Self.downloaded) == false)
        // The registration inventory carries it with the set it is filtered by.
        let registration = await loop.state.modelAutopilotRegistration
        #expect(registration.snapshot?.selectedModels.contains(Self.downloaded) == true)
        #expect(registration.inventory?.map(\.id) == [Self.downloaded])

        // A second request for a member verifies without downloading again.
        let again = await loop.prefetchForTesting(Self.downloaded)
        #expect(again.terminal == .init(status: .verified, error: nil))
        #expect(log.started == [Self.downloaded])
    }

    @Test func consentedRefusalsUseTheClosedVocabulary() async throws {
        let paused = try await Fixture.make(paused: true)
        defer { Task { await paused.remove() } }
        #expect(await paused.loop.prefetchForTesting(Self.downloaded).all
            == [.init(status: .failed, error: "autopilot_paused")])

        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let log = await fixture.installDownloads { id in
            if id.hasSuffix("full-disk") { throw AutopilotDownloadRefusal.insufficientDisk }
            try fixture.writeBuild(id, modelType: id.hasSuffix("unsupported") ? "not_a_family" : "gpt_oss")
        }
        #expect(await loop.prefetchForTesting("bad id").all == [.init(status: .failed, error: "model_not_supported")])
        #expect(await loop.prefetchForTesting("darkbloom-test/full-disk").terminal
            == .init(status: .failed, error: "insufficient_disk"))
        #expect(await loop.prefetchForTesting("darkbloom-test/unsupported").terminal
            == .init(status: .failed, error: "model_not_supported"))
        #expect(log.started == ["darkbloom-test/full-disk", "darkbloom-test/unsupported"])
        #expect(await loop.state.modelAutopilot?.selectedModels == [Fixture.saved])
        #expect(fixture.ledger.downloads.isEmpty)
    }

    @Test func aDownloadCompletingAfterConsentWasRevokedJoinsNothing() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in
            try fixture.writeBuild(id)
            await loop.updateAutopilotSettingsForTesting { $0.consentRecorded = false }
        }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal
            == .init(status: .failed, error: "model_not_selected"))
        #expect(await loop.autopilotInventoryModels[Self.downloaded] == nil)
        #expect(fixture.ledger.downloads.isEmpty)
    }

    /// The start path keeps a recorded download in the set from its bytes
    /// alone when the catalog cannot be fetched, so a restart preserves it.
    @Test func aRestartKeepsTheDownloadInTheSet() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await fixture.loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)

        let settings = await fixture.loop.autopilotSettings
        let start = await AutopilotStartInventory.load(settings: settings, coordinatorURL: "http://127.0.0.1:9",
            configDirectory: fixture.root, memoryGb: 128, runtimeCapabilities: [])
        #expect(start.catalog == nil)
        let local = try #require(fixture.scannedBuild(Self.downloaded))
        let inventory = start.inventory(from: [local])
        #expect(inventory.map(\.id) == [Self.downloaded])

        let restarted = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused", hardware: ModelLoadingFixtures.defaultHardware,
            models: [], config: ProviderConfig(provider: ProviderSettings(name: "restarted"),
                backend: BackendSettings(modelAutopilot: settings)),
            modelHashes: [Self.downloaded: try #require(local.weightHash)],
            configPath: fixture.configPath, autopilotInventory: inventory), attestationSigner: nil)
        await restarted.publishModelAutopilotSnapshot()
        #expect(await restarted.state.modelAutopilot?.selectedModels == [Self.downloaded, Fixture.saved].sorted())
        // Rewritten bytes are no longer the recorded download.
        try fixture.writeBuild(Self.downloaded, byte: 0x11)
        let rewritten = try #require(fixture.scannedBuild(Self.downloaded))
        #expect(start.inventory(from: [rewritten]).isEmpty)
    }

    /// Download verified, the build in the set, then an Autopilot load of it
    /// is accepted. Its fake weights cannot load; the tiny-model suite runs the
    /// same flow to a served, adopted model on the GPU.
    @Test func aDownloadedBuildIsAnAcceptedAutopilotLoadTarget() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        await loop.activateDownloadLeaseForTesting()
        let recorder = AutopilotRecorder()
        await loop.handleModelAutopilot(ModelAutopilotCommand(commandId: "load-download",
            loadModelId: Self.downloaded, expiresAtMs: ProviderLoop.autopilotNowMs + 60_000,
            sessionId: "session", revision: Fixture.revision), send: SendHandle(recorder.append))
        #expect(recorder.statuses.first?.status == .started)
        let task = await loop.autopilotTask
        await task?.value
        let terminal = try #require(recorder.statuses.last)
        #expect(!["model_not_selected", "model_not_cached", "not_opted_in", "inactive_session",
                  "hardware_ineligible", "unknown_model_size"].contains(terminal.error ?? ""))
        #expect(await loop.autopilotCommand == nil)
    }

    // MARK: - Reporting a grown set to the coordinator

    @Test func aRegistrationThatCarriedTheBuildEndsTheWaitAndBusyWorkDefersIt() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.downloaded])
        // No registered connection: nothing to refresh yet; the build waits.
        await loop.refreshAutopilotInventoryRegistration()
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.downloaded])
        await loop.raiseBusyFlagForTesting(.inflightWork)
        await loop.refreshAutopilotInventoryRegistration()
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.downloaded])
        await loop.lowerBusyFlagForTesting(.inflightWork)
        // A registration (any reconnect) that carried it ends the wait.
        await loop.state.setRegisteredAutopilotInventoryForTesting([Self.downloaded])
        await loop.refreshAutopilotInventoryRegistration()
        #expect(await loop.autopilotInventoryAwaitingRegistration.isEmpty)
    }

    @Test func registrationCarriesTheEffectiveInventoryFilteredByTheSet() throws {
        let config = CoordinatorClientConfig(url: "ws://127.0.0.1:0/unused", hardware: ModelLoadingFixtures.defaultHardware,
            models: [], backendName: "mlx-swift", autopilotInventory: [])
        var state = ModelAutopilotSnapshot(enabled: true, consentEnabled: true)
        state.revision = Fixture.revision
        state.selectedModels = [Self.cached, Fixture.saved].sorted()
        let message = CoordinatorClientCodec.registrationMessage(from: config, models: [], modelAutopilot: state,
            autopilotInventory: [Self.model(Self.cached), Self.model("darkbloom-test/outside-the-set")])
        guard case .register(let registration) = message else { Issue.record("not register"); return }
        #expect(registration.autopilotInventory?.map(\.id) == [Self.cached])
        #expect(registration.modelAutopilot?.protocolVersion == 3)
    }

    // MARK: - Ordinary builds verified by prefetch

    @Test func aVerifiedSuccessorJoinsTheSetAndEndsTheInventoryWait() async throws {
        let successor = "darkbloom-test/saved-model-next"
        let fixture = try await Fixture.make(ordinary: [Self.model(Fixture.saved)])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.reconcileDesiredModels([.init(modelName: "saved-alias", desiredBuild: successor,
            previousBuild: Fixture.saved)], send: SendHandle { _ in })
        #expect(await loop.autopilotPhase == "waiting_inventory")
        let artifact = Self.model(successor, hash: String(repeating: "e", count: 64))
        #expect(await loop.publishVerifiedPrefetch(modelId: successor,
            verifiedArtifact: (artifact, artifact.weightHash!)))
        #expect(await loop.autopilotSetAllows(successor))
        #expect(await loop.autopilotNeedsInventoryRefresh == false)
        #expect(await loop.autopilotPhase != "waiting_inventory")
        // Advertised by `models_update`, so it waits for no re-registration.
        #expect(await loop.autopilotInventoryAwaitingRegistration.isEmpty)
    }
}

extension ProviderLoop {
    func activateDownloadLeaseForTesting() {
        autopilotControl = .init(sessionId: "session", revision: AutopilotDownloadFixture.revision, enabled: true,
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 120_000)
        publishModelAutopilotSnapshot()
    }
}

extension ProviderState {
    func setRegisteredAutopilotInventoryForTesting(_ ids: Set<String>) {
        registeredAutopilotInventoryIDs = ids
    }
}
