import Foundation

/// Downloads on the operator's behalf: with saved consent, a `prefetch_model`
/// for a build outside ordinary serving downloads and verifies it through the
/// ordinary prefetch pipeline, then adds it to the Autopilot set (persisted in
/// `AutopilotDownloadLedger`). It is never advertised, loaded or deleted here:
/// an Autopilot operation may load it later. Serving is never fenced.
extension ProviderLoop {
    func handleAutopilotDownloadRequest(modelId: String, priority: Int, send: SendHandle) async {
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
        return nil
    }

    func makeAutopilotDownloadCoordinator() -> ModelPrefetchCoordinator {
        let logger = self.logger
        let prefetcher = AutopilotDownloadPrefetcher(
            memoryGb: Double(loopConfig.hardware.memoryGb),
            runtimeCapabilities: loopConfig.runtimeCapabilities,
            reserveBytes: AutopilotDiskGuard.reserveBytes(
                configuredGiB: loopConfig.config.backend.autopilotDownloadReserveGb),
            dependencies: .live(coordinatorURL: loopConfig.coordinatorURL,
                runtimeCapabilities: loopConfig.runtimeCapabilities,
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

    /// A member of the set with a verified hash is already available.
    func autopilotDownloadPreCheck(modelId: String) -> PrefetchPreCheck {
        autopilotInventoryModels[modelId]?.weightHash?.isEmpty == false && autopilotSetAllows(modelId)
            ? .alreadyAvailable : .needsFetch
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
        guard autopilotConsented, !isShuttingDown else { return "model_not_selected" }
        if autopilotSettings.paused { return AutopilotDownloadRefusal.autopilotPaused.rawValue }
        guard let info = scanned, let hash = info.weightHash, !hash.isEmpty else {
            logger.error("Autopilot download \(modelId) verified but its snapshot could not be scanned or hashed")
            return AutopilotDownloadRefusal.downloadFailed.rawValue
        }
        guard AutopilotModelSet.isReportableID(modelId), EngineV2SupportedModels.isSupported(model: info),
              ModelRuntimeRequirements.isEligible(modelID: modelId, available: loopConfig.runtimeCapabilities),
              AutopilotBuildEligibility.fitsLoadBudget(sizeGb: info.estimatedMemoryGb,
                  memoryGb: Double(loopConfig.hardware.memoryGb)),
              !retiringModels.contains(modelId),
              failedSelfTestHashes[modelId].map({ !$0.isEmpty && $0 != hash }) ?? true
        else { return AutopilotDownloadRefusal.modelNotSupported.rawValue }
        addAutopilotCachedBuild(info)
        guard autopilotSetAllows(modelId) else {
            // Beyond the reported set's bound: keep the files, not the claim.
            autopilotInventoryModels.removeValue(forKey: modelId)
            autopilotInventoryAwaitingRegistration.remove(modelId)
            publishModelAutopilotSnapshot()
            return AutopilotDownloadRefusal.modelNotSupported.rawValue
        }
        recordAutopilotDownload(modelId: modelId, weightHash: hash)
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

    private func recordAutopilotDownload(modelId: String, weightHash: String) {
        guard let url = autopilotDownloadLedgerURL else { return }
        var ledger = AutopilotDownloadLedger.read(from: url)
        ledger.record(.init(modelId: modelId, weightHash: weightHash, downloadedAtMs: Self.autopilotNowMs))
        do { try ledger.write(to: url) } catch {
            logger.warning("Could not persist the Autopilot download record for \(modelId)")
        }
    }
}
