import Foundation

/// The Autopilot model set at runtime (`AutopilotModelSet`): the persisted
/// selection plus the cached builds of `autopilotInventoryModels`. The start
/// path fills the inventory with the persisted selection and the verified
/// ordinary builds; the other cached catalog builds are verified in the
/// background after registration. A verified Autopilot download or prefetched
/// build joins it, and a superseded or deleted build leaves it. No change
/// touches the consent revision, so an accepted operation or lease stays valid.
extension ProviderLoop {
    /// Reported as `selected_models`. Without saved consent: the persisted
    /// selection exactly as before.
    var autopilotModelSet: [String] {
        guard autopilotConsented else { return autopilotSettings.selectedModels }
        return AutopilotModelSet.effective(selected: autopilotSettings.selectedModels,
            cached: autopilotInventoryModels.keys)
    }

    /// Set membership under saved consent; replaces the persisted-selection
    /// check (`ModelAutopilotSettings.allows`) in every runtime gate.
    func autopilotSetAllows(_ id: String) -> Bool {
        if autopilotSettings.allows(id) { return true }
        guard autopilotConsented, autopilotInventoryModels[id] != nil,
              AutopilotModelSet.isReportableID(id) else { return false }
        // Below the cap every reportable cached build is a member.
        if autopilotSettings.selectedModels.count + autopilotInventoryModels.count <= AutopilotModelSet.maximumCount {
            return true
        }
        return autopilotModelSet.contains(id)
    }

    /// A build may join only as a member already or while the set has room:
    /// a newcomer whose ID sorts first must never push a member out.
    func autopilotSetHasRoom(for id: String) -> Bool {
        autopilotSetAllows(id) || autopilotModelSet.count < AutopilotModelSet.maximumCount
    }

    /// A verified catalog build joins the set. Its hash joins the live hashes
    /// a registration filters inventory by, unless a resident or loading slot
    /// owns that hash; the caller pushes them to the client. `register` is the
    /// only carrier of inventory metadata, so a build the coordinator has not
    /// seen waits for a re-registration unless it is advertised (`models_update`).
    func addAutopilotCachedBuild(_ model: ModelInfo) {
        guard autopilotConsented, let hash = model.weightHash, !hash.isEmpty,
              AutopilotModelSet.isReportableID(model.id), autopilotSetHasRoom(for: model.id) else { return }
        let isNew = autopilotInventoryModels[model.id]?.weightHash != hash
        autopilotInventoryModels[model.id] = model
        if modelSlots[model.id] == nil && !modelsLoading.contains(model.id) {
            modelHashes[model.id] = hash
            liveModelHashes[model.id] = hash
        }
        if isNew && !ordinaryServingModelIDs.contains(model.id) {
            autopilotInventoryAwaitingRegistration.insert(model.id)
        }
        publishModelAutopilotSnapshot()
    }

    /// A build the ordinary prefetch verified against the catalog joins the
    /// set when it fits this machine's load budget and the set has room.
    func joinsAutopilotSetWhenVerified(_ model: ModelInfo) -> Bool {
        autopilotConsented && AutopilotModelSet.isReportableID(model.id)
            && AutopilotBuildEligibility.fitsLoadBudget(sizeGb: model.estimatedMemoryGb,
                memoryGb: Double(loopConfig.hardware.memoryGb))
            && autopilotSetHasRoom(for: model.id)
    }

    /// After registration: hashes the cached candidates the start path left
    /// unhashed, one at a time off the actor, so start never pays for them.
    /// Each verified one joins the set, then waits for an idle re-registration.
    func startAutopilotCandidateVerification() {
        guard autopilotCandidateVerification == nil, let pending = loopConfig.autopilotPendingCandidates,
              !pending.models.isEmpty else { return }
        autopilotCandidateVerification = Task { [weak self] in
            await self?.verifyAutopilotCandidates(pending)
            await self?.finishAutopilotCandidateVerification()
        }
    }

    private func finishAutopilotCandidateVerification() { autopilotCandidateVerificationDone = true }

    func verifyAutopilotCandidates(_ pending: AutopilotStartInventory.Pending) async {
        var joined = false
        for candidate in pending.models {
            guard !Task.isCancelled, !isShuttingDown, autopilotConsented else { break }
            guard autopilotInventoryModels[candidate.id] == nil else { continue }
            let hashed = await Task.detached(priority: .utility) { () -> ModelInfo? in
                guard let snapshot = ModelScanner.resolveLocalPath(modelID: candidate.id) else { return nil }
                var model = candidate
                model.weightHash = WeightHasher.computeHash(snapshotDir: snapshot, modelID: candidate.id)
                return model
            }.value
            // Consent, the inventory and the slots may have changed meanwhile.
            guard !Task.isCancelled, !isShuttingDown, autopilotConsented else { break }
            guard let hashed, !pending.rule.inventory(from: [hashed]).isEmpty,
                  autopilotInventoryModels[hashed.id] == nil, failedSelfTestHashes[hashed.id] == nil,
                  autopilotSetHasRoom(for: hashed.id) else { continue }
            addAutopilotCachedBuild(hashed)
            joined = joined || autopilotInventoryModels[hashed.id] != nil
        }
        guard joined, !isShuttingDown else { return }
        logger.info("Autopilot set: verified cached builds joined (\(autopilotModelSet.count) models)")
        await coordinatorClient?.updateModelWeightHashes(liveModelHashes)
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
    }

    /// Re-registers once, on a capacity tick with nothing busy, when the set
    /// gained a build the last registration did not carry. A planned
    /// reconnect at an idle moment interrupts no request; a busy provider
    /// keeps waiting. Each build is tried once.
    func refreshAutopilotInventoryRegistration() async {
        guard !autopilotInventoryAwaitingRegistration.isEmpty else { return }
        let registered = state.registeredAutopilotInventoryIDs ?? []
        autopilotInventoryAwaitingRegistration = autopilotInventoryAwaitingRegistration.filter {
            !registered.contains($0) && autopilotInventoryModels[$0] != nil && autopilotSetAllows($0)
        }
        guard isIdleForInventoryRegistration, await autopilotDownloadsAreIdle(),
              await autopilotRegistrationIsLive(), isIdleForInventoryRegistration else { return }
        let builds = autopilotInventoryAwaitingRegistration.sorted()
        // Tried once; a refused request keeps waiting for the next idle tick.
        guard requestAutopilotInventoryRegistration() else { return }
        logger.info("Re-registering to report Autopilot inventory: \(builds.joined(separator: ", "))")
        autopilotInventoryAwaitingRegistration.removeAll()
    }

    /// Rechecked after every hop: consent, a reported set, no live lease, no
    /// operation and no busy reason, so the reconnect interrupts nothing.
    private var isIdleForInventoryRegistration: Bool {
        !autopilotInventoryAwaitingRegistration.isEmpty && autopilotConsented && !autopilotNeedsInventoryRefresh
            && !modelAutopilotEnabled && autopilotCommand == nil && autopilotBusyReasons().isEmpty
            && autopilotCandidateVerificationIsIdle
    }

    /// Batches re-registration after every running and queued download, so
    /// their statuses stay on one session.
    private func autopilotDownloadsAreIdle() async -> Bool {
        guard let downloads = autopilotDownloadCoordinator else { return true }
        let (running, queued) = (await downloads.inFlightCount(), await downloads.queuedCount())
        return running == 0 && queued == 0
    }

    private var autopilotCandidateVerificationIsIdle: Bool {
        autopilotCandidateVerificationDone || autopilotCandidateVerification == nil
    }

    private func autopilotRegistrationIsLive() async -> Bool {
        if let seam = autopilotRegistrationSeamForTesting { return await seam.registered() }
        guard let client = coordinatorClient else { return false }
        return await client.hasRegisteredConnection()
    }

    /// True when the planned reconnect was issued.
    private func requestAutopilotInventoryRegistration() -> Bool {
        if let seam = autopilotRegistrationSeamForTesting { return seam.reconnect() }
        let revision = plannedReconnectRevision
        requestPlannedReconnect()
        return plannedReconnectRevision != revision
    }

    /// Drops cached builds whose files are gone, at most once a minute. The
    /// persisted selection, resident, loading and ordinary models stay.
    func sweepAutopilotCachedBuilds(now: ContinuousClock.Instant = .now) {
        guard autopilotConsented, autopilotCommand == nil else { return }
        if let last = autopilotCacheSweepAt, now - last < .seconds(60) { return }
        autopilotCacheSweepAt = now
        let persisted = Set(autopilotSettings.selectedModels)
        let gone = autopilotInventoryModels.keys.filter {
            !persisted.contains($0) && !ordinaryServingModelIDs.contains($0) && modelSlots[$0] == nil
                && !modelsLoading.contains($0) && ModelScanner.resolveLocalPath(modelID: $0) == nil
        }
        guard !gone.isEmpty else { return }
        for id in gone {
            autopilotInventoryModels.removeValue(forKey: id)
            autopilotInventoryAwaitingRegistration.remove(id)
        }
        logger.info("Autopilot set: removed builds no longer on disk: \(gone.sorted().joined(separator: ", "))")
        publishModelAutopilotSnapshot()
    }

    /// Without consent the inventory holds only what an enrolled start would
    /// have registered: the persisted selection. Cached builds that are not
    /// resident or ordinary leave, so ordinary prefetch and loading treat them
    /// exactly as before the set existed.
    func dropAutopilotCachedBuildsWithoutConsent() {
        guard !autopilotConsented else { return }
        let persisted = Set(autopilotSettings.selectedModels)
        for id in Array(autopilotInventoryModels.keys) where !persisted.contains(id)
            && !ordinaryServingModelIDs.contains(id) && modelSlots[id] == nil && !modelsLoading.contains(id)
            && advertisedModels[id] == nil {
            autopilotInventoryModels.removeValue(forKey: id)
        }
        autopilotInventoryAwaitingRegistration.removeAll()
    }

    /// Verified cached builds and their hashes, carried into the next
    /// scheduled window.
    public var autopilotCachedBuildHashes: [String: String] {
        guard autopilotConsented else { return [:] }
        let persisted = Set(autopilotSettings.selectedModels)
        var hashes: [String: String] = [:]
        for (id, model) in autopilotInventoryModels where !persisted.contains(id) {
            if let hash = model.weightHash, !hash.isEmpty { hashes[id] = hash }
        }
        return hashes
    }
}
