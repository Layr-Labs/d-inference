import Foundation

/// Downloads on the operator's behalf: with saved consent and downloads not
/// turned off in provider configuration (`[backend.autopilot_downloads]`, on
/// by default), a `prefetch_model` for a build outside ordinary serving downloads
/// and verifies it through the ordinary prefetch pipeline, within the disk
/// reserve and the operator's caps, then adds it to the Autopilot set
/// (persisted in `AutopilotDownloadLedger`). It is never advertised, loaded or
/// deleted here: an Autopilot operation may load it later. Serving is never
/// fenced.
extension ProviderLoop {
    /// Live provider configuration, refreshed with the consent settings but
    /// never part of them.
    var autopilotDownloadSettings: AutopilotDownloadSettings {
        autopilotDownloadSettingsOverride ?? loopConfig.config.backend.autopilotDownloads ?? .init()
    }

    var autopilotDownloadsEnabled: Bool { autopilotConsented && autopilotDownloadSettings.enabled }

    /// Free disk on the model cache volume, the reserve, the caps and the
    /// builds Autopilot downloaded that are still on disk, leaving out one
    /// build a download would replace.
    func autopilotDownloadBudget(excluding modelId: String? = nil) -> AutopilotDownloadBudget {
        let settings = autopilotDownloadSettings
        let usage = (autopilotDownloadLedgerURL.map(AutopilotDownloadLedger.read(from:)) ?? .init())
            .usage(excluding: modelId) { ModelScanner.resolveLocalPath(modelID: $0) != nil }
        return AutopilotDownloadBudget(freeBytes: AutopilotDiskGuard.volumeFreeBytes(at: ModelScanner.cacheDirectory()),
            reserveBytes: settings.reserveBytes, usedBytes: usage.bytes, usedModels: usage.models,
            limitBytes: settings.limitBytes, limitModels: settings.limitModels)
    }

    /// The `download_storage` report, refreshed on the capacity tick at most
    /// once a minute and after each download or settings change.
    func refreshAutopilotDownloadStorage(now: ContinuousClock.Instant = .now, force: Bool = false) {
        guard autopilotDownloadsEnabled else {
            autopilotDownloadStorage = nil
            return
        }
        if !force, autopilotDownloadStorage != nil, let last = autopilotDownloadStorageAt,
           now - last < .seconds(60) { return }
        autopilotDownloadStorageAt = now
        autopilotDownloadStorage = autopilotDownloadBudget().report
    }

    func handleAutopilotDownloadRequest(modelId: String, priority: Int, send: SendHandle) async {
        // Act on the saved pause, consent and download settings, not on up to
        // a tick-old copy.
        refreshAutopilotSettings()
        guard autopilotDownloadsEnabled else {
            send.send(.prefetchModelStatus(modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0,
                error: "model_not_selected"))
            return
        }
        if isShuttingDown {
            send.send(.prefetchModelStatus(modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0,
                error: "provider is shutting down"))
            return
        }
        if isDraining {
            sendDrainingPrefetchFailure(modelId: modelId, send: send)
            return
        }
        if let refusal = autopilotDownloadRefusal(modelId) {
            logger.info("Autopilot download \(modelId) refused: \(refusal.rawValue)")
            send.send(.prefetchModelStatus(modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0,
                error: refusal.rawValue))
            return
        }
        let coordinator = autopilotDownloadCoordinator ?? makeAutopilotDownloadCoordinator()
        autopilotDownloadCoordinator = coordinator
        logger.info("Autopilot download request for \(modelId) (priority=\(priority))")
        await coordinator.handlePrefetch(modelId: modelId, priority: priority, sink: SendHandlePrefetchSink(send: send))
    }

    /// Refusals that need no catalog; the rest are checked by the download
    /// task (`AutopilotDownloadPrefetcher`) and on publication.
    private func autopilotDownloadRefusal(_ modelId: String) -> AutopilotDownloadRefusal? {
        if autopilotSettings.paused { return .autopilotPaused }
        guard AutopilotModelSet.isReportableID(modelId),
              ModelRuntimeRequirements.isEligible(modelID: modelId, available: loopConfig.runtimeCapabilities)
        else { return .modelNotSupported }
        // A member re-verifies without counting against a cap.
        if autopilotDownloadPreCheck(modelId: modelId) == .alreadyAvailable { return nil }
        return autopilotDownloadBudget(excluding: modelId).refusalBeforeSizing
    }

    func makeAutopilotDownloadCoordinator() -> ModelPrefetchCoordinator {
        let logger = self.logger
        let me = self
        let prefetcher = AutopilotDownloadPrefetcher(
            memoryGb: Double(loopConfig.hardware.memoryGb),
            runtimeCapabilities: loopConfig.runtimeCapabilities,
            dependencies: .live(coordinatorURL: loopConfig.coordinatorURL,
                runtimeCapabilities: loopConfig.runtimeCapabilities,
                budget: { entry in await me.autopilotDownloadBudget(excluding: entry.id) },
                log: { logger.warning("\($0)") }))
        return makeAutopilotDownloadCoordinator(prefetcher: prefetcher)
    }

    func makeAutopilotDownloadCoordinator(prefetcher: any ModelPrefetcher) -> ModelPrefetchCoordinator {
        let me = self
        return ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { modelId in await me.autopilotDownloadPreCheck(modelId: modelId) },
            publish: { modelId in await me.publishAutopilotDownload(modelId: modelId) })
    }

    /// A member of the set with a verified hash is already available while
    /// it is resident or loading, or its files are still present and it has
    /// neither failed a self-test nor started retiring.
    func autopilotDownloadPreCheck(modelId: String) -> PrefetchPreCheck {
        guard autopilotInventoryModels[modelId]?.weightHash?.isEmpty == false, autopilotSetAllows(modelId)
        else { return .needsFetch }
        if modelSlots[modelId] != nil || modelsLoading.contains(modelId) { return .alreadyAvailable }
        return failedSelfTestHashes[modelId] == nil && !retiringModels.contains(modelId)
            && ModelScanner.resolveLocalPath(modelID: modelId) != nil ? .alreadyAvailable : .needsFetch
    }

    /// Adds a verified download to the Autopilot set, or returns the closed
    /// refusal the terminal status reports instead of `verified`. The scan
    /// and weight hash run off the actor.
    func publishAutopilotDownload(modelId: String) async -> String? {
        if autopilotDownloadPreCheck(modelId: modelId) == .alreadyAvailable { return nil }
        let scanned = await Task.detached(priority: .utility) { () -> ModelInfo? in
            guard let snapshot = ModelScanner.resolveLocalPath(modelID: modelId),
                  var info = ModelScanner.parseModelInfo(snapshotDir: snapshot, modelName: modelId)
            else { return nil }
            info.weightHash = WeightHasher.computeHash(snapshotDir: snapshot, modelID: modelId)
            return info
        }.value
        // Consent, pause and lifecycle may have changed during the download.
        refreshAutopilotSettings()
        if isShuttingDown { return "provider is shutting down" }
        guard autopilotConsented else { return "model_not_selected" }
        if autopilotSettings.paused { return AutopilotDownloadRefusal.autopilotPaused.rawValue }
        // A loaded slot owns its attested hash: never replace it with newer
        // bytes on disk. Retry once the model has unloaded.
        if modelSlots[modelId] != nil || modelsLoading.contains(modelId) {
            logger.warning("Autopilot download \(modelId) verified while the model is loaded; not adding it")
            return AutopilotDownloadRefusal.downloadFailed.rawValue
        }
        guard let info = scanned, let hash = info.weightHash, !hash.isEmpty else {
            logger.error("Autopilot download \(modelId) verified but its snapshot could not be scanned or hashed")
            return AutopilotDownloadRefusal.downloadFailed.rawValue
        }
        guard AutopilotModelSet.isReportableID(modelId),
              ModelRuntimeRequirements.isEligible(modelID: modelId, available: loopConfig.runtimeCapabilities),
              AutopilotBuildEligibility.allowsScannedBuild(info, memoryGb: Double(loopConfig.hardware.memoryGb)),
              !retiringModels.contains(modelId), !selfTestRecordRefuses(modelId: modelId, hash: hash),
              // At the reported set's bound: keep the files, not the claim.
              autopilotSetHasRoom(for: modelId)
        else { return AutopilotDownloadRefusal.modelNotSupported.rawValue }
        // Different bytes from a build that failed its self-test are a new
        // build, as in ordinary publication; an operation may load them.
        failedSelfTestHashes.removeValue(forKey: modelId)
        addAutopilotCachedBuild(info)
        recordAutopilotDownload(modelId: modelId, weightHash: hash, sizeBytes: Int64(clamping: info.sizeBytes))
        refreshAutopilotDownloadStorage(force: true)
        publishModelAutopilotSnapshot()
        logger.info("Autopilot download \(modelId) verified (weight_hash=\(hash.prefix(16))); added to the Autopilot set")
        await coordinatorClient?.updateModelWeightHashes(liveModelHashes)
        // Heartbeats carry the snapshot paired with capacity: rebuild the pair
        // so the coordinator sees the grown `selected_models` now.
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
        return nil
    }

    var autopilotDownloadLedgerURL: URL? {
        loopConfig.configPath.map { AutopilotDownloadLedger.url(configDirectory: $0.deletingLastPathComponent()) }
    }

    private func recordAutopilotDownload(modelId: String, weightHash: String, sizeBytes: Int64) {
        guard let url = autopilotDownloadLedgerURL else { return }
        var ledger = AutopilotDownloadLedger.read(from: url)
        ledger.record(.init(modelId: modelId, weightHash: weightHash, downloadedAtMs: Self.autopilotNowMs,
            sizeBytes: sizeBytes))
        do { try ledger.write(to: url) } catch {
            logger.warning("Could not persist the Autopilot download record for \(modelId)")
        }
    }
}
