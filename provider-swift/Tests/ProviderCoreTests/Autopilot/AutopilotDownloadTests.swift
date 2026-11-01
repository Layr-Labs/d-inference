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
        defer { fixture.release() }
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
        await loop.activateAutopilotForTesting(revision: Fixture.revision)
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
        defer { fixture.release() }
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
        defer { fixture.release() }
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

    /// No saved consent (the start path passes no inventory), or saved
    /// consent on a private-only Mac (the persisted selection only): the
    /// report keeps the persisted list and every prefetch takes its earlier
    /// path. Nothing is downloaded on the operator's behalf.
    @Test(arguments: [false, true])
    func withoutConsentTheReportAndPrefetchRepliesAreUnchanged(privateOnly: Bool) async throws {
        let fixture = try await Fixture.make(consent: privateOnly, privateOnly: privateOnly,
            inventory: privateOnly ? [Self.model(Fixture.saved)] : [])
        defer { fixture.release() }
        let loop = fixture.loop
        try fixture.writeBuild(Self.downloaded)
        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.selectedModels == [Fixture.saved])
        #expect(snapshot.capabilities == nil)
        #expect(await loop.autopilotSetAllows(Self.downloaded) == false)
        // Unenrolled: the ordinary prefetch pipeline, absent in this fixture.
        // Private-only enrolled: refused exactly as before.
        let expected = privateOnly ? "model_not_selected" : "prefetch subsystem not initialized"
        #expect(await loop.prefetchForTesting(Self.downloaded).all == [.init(status: .failed, error: expected)])
        if privateOnly {
            #expect(await loop.prefetchForTesting(Fixture.saved).all
                == [.init(status: .failed, error: "model_not_selected")])
        }
        #expect(await loop.autopilotDownloadCoordinator == nil)
    }

    /// Revoking consent at runtime takes the cached builds out of the
    /// inventory, so ordinary prefetch and loading treat them as before the
    /// set existed; the persisted selection stays as it always did.
    @Test func revokingConsentRestoresOrdinaryTreatmentOfCachedBuilds() async throws {
        let fixture = try await Fixture.make(inventory: [Self.model(Self.cached), Self.model(Fixture.saved)])
        defer { fixture.release() }
        let loop = fixture.loop
        #expect(await loop.autopilotAllowsModel(Self.cached) == false)
        try await fixture.revokeConsent()
        #expect(await loop.autopilotInventoryModels[Self.cached] == nil)
        #expect(await loop.autopilotInventoryModels[Fixture.saved] != nil)
        #expect(await loop.autopilotAllowsModel(Self.cached))
        #expect(await loop.autopilotAllowsModel(Fixture.saved) == false)
        #expect(await loop.state.modelAutopilot?.selectedModels == [Fixture.saved])
    }

    // MARK: - Downloads on the operator's behalf

    /// Downloads are on by default with saved consent. Turned off, a prefetch
    /// outside the set is refused exactly as before, and neither the
    /// capability nor `download_storage` is reported. The set stays automatic.
    @Test func downloadsAreOnByDefaultUntilTheOperatorTurnsThemOff() async throws {
        let defaults = try await Fixture.make(downloads: nil)
        defer { defaults.release() }
        #expect(await defaults.loop.autopilotDownloadsEnabled)
        #expect(await defaults.loop.state.modelAutopilot?.capabilities?.last == "inventory_downloads")
        #expect(await defaults.loop.state.modelAutopilot?.downloadStorage?.limitModels == nil)
        for downloads in [AutopilotDownloadSettings(enabled: false), AutopilotDownloadSettings(enabled: false, maxModels: 2)] {
            let fixture = try await Fixture.make(inventory: [Self.model(Self.cached)], downloads: downloads)
            defer { fixture.release() }
            let loop = fixture.loop
            let log = await fixture.installDownloads { id in try fixture.writeBuild(id) }
            #expect(await loop.prefetchForTesting(Self.downloaded).all
                == [.init(status: .failed, error: "model_not_selected")])
            #expect(await loop.prefetchForTesting(Self.cached).all
                == [.init(status: .failed, error: "model_not_selected")])
            #expect(log.started.isEmpty)
            let snapshot = try #require(await loop.state.modelAutopilot)
            #expect(snapshot.capabilities == ["inventory_adoption", "placement_holds", "busy_reasons"])
            #expect(snapshot.downloadStorage == nil)
            #expect(snapshot.selectedModels == [Self.cached, Fixture.saved].sorted())
        }
    }

    @Test func enabledDownloadsReportTheCapabilityAndTheirStorage() async throws {
        let fixture = try await Fixture.make(downloads: .init(enabled: true, maxStorageGb: 100, maxModels: 4))
        defer { fixture.release() }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        var snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.capabilities?.last == "inventory_downloads")
        var storage = try #require(snapshot.downloadStorage)
        #expect(storage.diskFreeBytes > 0)
        #expect(storage.reserveBytes == 50 << 30)
        #expect(storage.limitBytes == 100 << 30)
        #expect(storage.limitModels == 4)
        #expect(storage.usedBytes == 0 && storage.usedModels == 0)
        let replies = await loop.prefetchForTesting(Self.downloaded)
        #expect(replies.terminal == .init(status: .verified, error: nil))
        snapshot = try #require(await loop.state.modelAutopilot)
        storage = try #require(snapshot.downloadStorage)
        #expect(storage.usedModels == 1)
        #expect(storage.usedBytes == Int64(try #require(fixture.scannedBuild(Self.downloaded)).sizeBytes))
        // The wire object is snake_case and omits absent limits.
        let json = String(decoding: try JSONEncoder().encode(ModelAutopilotDownloadStorage(diskFreeBytes: 1,
            reserveBytes: 2, usedBytes: 3, usedModels: 4)), as: UTF8.self)
        #expect(json.contains(#""disk_free_bytes":1"#) && json.contains(#""used_models":4"#))
        #expect(!json.contains("limit_"))
    }

    /// The operator's caps count the builds Autopilot downloaded that are
    /// still on disk; deleting one frees its share.
    @Test func theOperatorCapsRefuseNewDownloadsUntilABuildIsDeleted() async throws {
        let fixture = try await Fixture.make(downloads: .init(enabled: true, maxModels: 1))
        defer { fixture.release() }
        let loop = fixture.loop
        let log = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        #expect(await loop.prefetchForTesting("darkbloom-test/second-model").all
            == [.init(status: .failed, error: "model_limit_reached")])
        // A member re-verifies without counting against the cap.
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        try fixture.removeBuild(Self.downloaded)
        #expect(await loop.prefetchForTesting("darkbloom-test/second-model").terminal?.status == .verified)
        #expect(log.started == [Self.downloaded, "darkbloom-test/second-model"])

        let storageCapped = try await Fixture.make(downloads: .init(enabled: true, maxStorageGb: 1))
        defer { storageCapped.release() }
        var ledger = AutopilotDownloadLedger()
        try storageCapped.writeBuild(Self.cached)
        ledger.record(.init(modelId: Self.cached, weightHash: "h", downloadedAtMs: 1, sizeBytes: 1 << 30))
        try ledger.write(to: AutopilotDownloadLedger.url(configDirectory: storageCapped.root))
        _ = await storageCapped.installDownloads { id in try storageCapped.writeBuild(id) }
        #expect(await storageCapped.loop.prefetchForTesting(Self.downloaded).all
            == [.init(status: .failed, error: "storage_limit_reached")])
    }

    /// Enabling, disabling or changing limits is provider configuration: the
    /// running provider applies it at its next policy refresh, and neither the
    /// consent revision nor a live lease changes.
    @Test func changingDownloadSettingsLeavesConsentAndControlAlone() async throws {
        let fixture = try await Fixture.make(downloads: .init(enabled: false))
        defer { fixture.release() }
        let loop = fixture.loop
        await loop.activateAutopilotForTesting(revision: Fixture.revision)
        var config = await loop.loopConfig.config
        config.backend.autopilotDownloads = .init(enabled: true, maxModels: 3)
        try ConfigManager.save(config, to: fixture.configPath)
        await loop.refreshAutopilotSettings()
        #expect(await loop.autopilotDownloadsEnabled)
        #expect(await loop.modelAutopilotEnabled)
        #expect(await loop.autopilotSettings.revision == Fixture.revision)
        #expect(await loop.state.modelAutopilot?.capabilities?.contains("inventory_downloads") == true)
        #expect(await loop.state.modelAutopilot?.downloadStorage?.limitModels == 3)
        config.backend.autopilotDownloads?.enabled = false
        try ConfigManager.save(config, to: fixture.configPath)
        await loop.refreshAutopilotSettings()
        #expect(await loop.autopilotDownloadsEnabled == false)
        #expect(await loop.modelAutopilotEnabled)
        #expect(await loop.state.modelAutopilot?.downloadStorage == nil)
    }

    @Test func aVerifiedDownloadJoinsTheSetPersistsAndIsNeitherAdvertisedNorLoaded() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
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
        defer { paused.release() }
        #expect(await paused.loop.prefetchForTesting(Self.downloaded).all
            == [.init(status: .failed, error: "autopilot_paused")])

        let fixture = try await Fixture.make()
        defer { fixture.release() }
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

    /// The bytes that failed a self-test stay refused; different bytes are
    /// a new build that joins and clears the record, as in ordinary
    /// publication, so an operation can load it.
    @Test func aFailedSelfTestRefusesOnlyTheBytesThatFailed() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        try fixture.writeBuild(Self.downloaded)
        let hash = try #require(fixture.scannedBuild(Self.downloaded)?.weightHash)
        for refused in [hash, ""] {
            await loop.recordFailedSelfTestForTesting(Self.downloaded, hash: refused)
            #expect(await loop.prefetchForTesting(Self.downloaded).terminal
                == .init(status: .failed, error: "model_not_supported"))
            #expect(await loop.autopilotSetAllows(Self.downloaded) == false)
        }
        await loop.recordFailedSelfTestForTesting(Self.downloaded, hash: String(repeating: "f", count: 64))
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal == .init(status: .verified, error: nil))
        #expect(await loop.autopilotSetAllows(Self.downloaded))
        #expect(await loop.failedSelfTestHashForTesting(Self.downloaded) == nil)
    }

    /// At the 256-ID bound a download keeps its files but joins nothing, even
    /// when its ID sorts before a member's: no member is ever pushed out.
    @Test(arguments: [false, true])
    func aDownloadAtTheBoundJoinsNothing(cachedMember: Bool) async throws {
        let member = "darkbloom-test/zzz-cached"
        let saved = (0..<(AutopilotModelSet.maximumCount - (cachedMember ? 1 : 0))).map { "darkbloom-test/saved-\($0)" }
        let fixture = try await Fixture.make(selected: saved, inventory: cachedMember ? [Self.model(member)] : [])
        defer { fixture.release() }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(Self.downloaded < member)
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal
            == .init(status: .failed, error: "model_not_supported"))
        #expect(await loop.autopilotInventoryModels[Self.downloaded] == nil)
        #expect(await loop.liveModelHashForTesting(Self.downloaded) == nil)
        let set = try #require(await loop.state.modelAutopilot?.selectedModels)
        #expect(set.count == AutopilotModelSet.maximumCount)
        #expect(set.contains(member) == cachedMember)
        #expect(fixture.ledger.downloads.isEmpty)
        #expect(ModelScanner.resolveLocalPath(modelID: Self.downloaded) != nil)
    }

    /// A member answers `verified` without a download only while its bytes
    /// can still serve: files present, no failed self-test, not retiring.
    @Test func aMemberThatCannotServeIsDownloadedAgain() async throws {
        let fixture = try await Fixture.make(inventory: [Self.model(Self.cached)])
        defer { fixture.release() }
        let loop = fixture.loop
        #expect(await loop.autopilotDownloadPreCheck(modelId: Self.cached) == .needsFetch)
        try fixture.writeBuild(Self.cached)
        #expect(await loop.autopilotDownloadPreCheck(modelId: Self.cached) == .alreadyAvailable)
        await loop.recordFailedSelfTestForTesting(Self.cached, hash: String(repeating: "b", count: 64))
        #expect(await loop.autopilotDownloadPreCheck(modelId: Self.cached) == .needsFetch)
    }

    /// With saved consent, a build outside ordinary serving is a download
    /// even under a live lease: never advertised, never a `models_update`.
    @Test func aLiveLeasePrefetchOfACachedBuildIsStillADownload() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
        let loop = fixture.loop
        let log = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        await loop.activateAutopilotForTesting(revision: Fixture.revision)
        #expect(await loop.autopilotAllowsModel(Self.downloaded))
        let messages = OutboundLog()
        await loop.setOutboundSendForTesting(SendHandle(messages.append))
        let again = await loop.prefetchForTesting(Self.downloaded)
        #expect(again.terminal == .init(status: .verified, error: nil))
        #expect(log.started == [Self.downloaded])
        #expect(await loop.isModelAdvertised(Self.downloaded) == false)
        #expect(messages.modelsUpdates == 0)
    }

    @Test func aDownloadCompletingAfterConsentWasRevokedJoinsNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
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
        defer { fixture.release() }
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
        defer { fixture.release() }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        await loop.activateAutopilotForTesting(revision: Fixture.revision)
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

    @Test func aGrownSetReRegistersOnceOnlyWhenNothingIsBusy() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
        let loop = fixture.loop
        let (release, releaseNow) = AsyncStream<Void>.makeStream()
        _ = await fixture.installDownloads { id in
            if id.hasSuffix("slow") { for await _ in release { break } }
            try fixture.writeBuild(id)
        }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.downloaded])
        let reconnects = ReconnectLog(accept: false)
        await loop.setAutopilotRegistrationSeamForTesting(reconnects)

        // No registered connection: the build waits.
        await loop.refreshAutopilotInventoryRegistration()
        #expect(reconnects.requests == 0)
        reconnects.registered = true
        // Busy work, a live lease, or another download still running: wait.
        await loop.raiseBusyFlagForTesting(.inflightWork)
        await loop.refreshAutopilotInventoryRegistration()
        await loop.lowerBusyFlagForTesting(.inflightWork)
        await loop.activateAutopilotForTesting(revision: Fixture.revision)
        await loop.refreshAutopilotInventoryRegistration()
        await loop.clearAutopilotControl()
        let slow = PrefetchReplies()
        await loop.handlePrefetchModelRequest(modelId: "darkbloom-test/slow", priority: 0, send: SendHandle(slow.append))
        await loop.refreshAutopilotInventoryRegistration()
        #expect(reconnects.requests == 0)
        releaseNow.yield(())
        #expect(await modelLoadingWaitUntil { slow.terminal != nil })
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.downloaded, "darkbloom-test/slow"])

        // A refused reconnect keeps waiting; an issued one ends the wait once.
        await loop.refreshAutopilotInventoryRegistration()
        #expect(reconnects.requests == 1)
        #expect(await loop.autopilotInventoryAwaitingRegistration.count == 2)
        reconnects.accept = true
        await loop.refreshAutopilotInventoryRegistration()
        #expect(reconnects.requests == 2)
        #expect(await loop.autopilotInventoryAwaitingRegistration.isEmpty)
        await loop.refreshAutopilotInventoryRegistration()
        #expect(reconnects.requests == 2)
    }

    @Test func aRegistrationThatCarriedTheBuildEndsTheWait() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
        let loop = fixture.loop
        _ = await fixture.installDownloads { id in try fixture.writeBuild(id) }
        #expect(await loop.prefetchForTesting(Self.downloaded).terminal?.status == .verified)
        let reconnects = ReconnectLog(accept: true)
        reconnects.registered = true
        await loop.setAutopilotRegistrationSeamForTesting(reconnects)
        await loop.state.setRegisteredAutopilotInventoryForTesting([Self.downloaded])
        await loop.refreshAutopilotInventoryRegistration()
        #expect(await loop.autopilotInventoryAwaitingRegistration.isEmpty)
        #expect(reconnects.requests == 0)
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
        // A build that joined at runtime and reached the client's advertised
        // store under a lease still registers as inventory, not as ordinary.
        let leased = CoordinatorClientCodec.registrationMessage(from: config,
            models: [Self.model(Fixture.saved), Self.model(Self.cached)], modelAutopilot: state,
            ordinaryServingModelIDs: [Fixture.saved], autopilotInventory: [Self.model(Self.cached)])
        guard case .register(let leasedRegistration) = leased else { Issue.record("not register"); return }
        #expect(leasedRegistration.models.map(\.id) == [Fixture.saved])
        #expect(leasedRegistration.autopilotInventory?.map(\.id) == [Self.cached])
    }

    /// After registration, the cached builds the start path left unhashed
    /// are verified one at a time; a current catalog build joins and waits
    /// for a re-registration, a stale or uncatalogued one does not.
    @Test func cachedCandidatesAreVerifiedAfterRegistration() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.release() }
        let loop = fixture.loop
        try fixture.writeBuild(Self.cached)
        try fixture.writeBuild("darkbloom-test/stale-model")
        try fixture.writeBuild("darkbloom-test/off-catalog")
        let current = try #require(fixture.scannedBuild(Self.cached))
        let catalog = [Self.cached, "darkbloom-test/stale-model"].map { id in
            CatalogModel(id: id, s3Name: id, displayName: id, sizeGb: 1, minRamGb: 8, active: true,
                weightHash: id == Self.cached ? current.weightHash : "superseded", r2Prefix: "v2/\(id)")
        }
        let settings = await loop.autopilotSettings
        let rule = AutopilotStartInventory(settings: settings, catalog: catalog, recordedDownloads: [:],
            memoryGb: 64, runtimeCapabilities: [])
        let local = [Self.cached, "darkbloom-test/stale-model", "darkbloom-test/off-catalog"].compactMap {
            fixture.scannedBuild($0).map { var unhashed = $0; unhashed.weightHash = nil; return unhashed }
        }
        let pending = rule.pending(local: local, hashed: [])
        #expect(pending.models.map(\.id) == [Self.cached, "darkbloom-test/stale-model"])
        await loop.verifyAutopilotCandidates(pending)
        #expect(await loop.autopilotSetAllows(Self.cached))
        #expect(await loop.autopilotSetAllows("darkbloom-test/stale-model") == false)
        #expect(await loop.autopilotInventoryAwaitingRegistration == [Self.cached])
        #expect(await loop.liveModelHashForTesting(Self.cached) == current.weightHash)

        // Without consent, nothing joins.
        try await fixture.revokeConsent()
        await loop.verifyAutopilotCandidates(rule.pending(local: local, hashed: []))
        #expect(await loop.autopilotSetAllows(Self.cached) == false)
    }

    // MARK: - Ordinary builds verified by prefetch

    @Test func aVerifiedSuccessorJoinsTheSetAndEndsTheInventoryWait() async throws {
        let successor = "darkbloom-test/saved-model-next"
        let fixture = try await Fixture.make(ordinary: [Self.model(Fixture.saved)])
        defer { fixture.release() }
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

extension ProviderState {
    func setRegisteredAutopilotInventoryForTesting(_ ids: Set<String>) {
        registeredAutopilotInventoryIDs = ids
    }
}
