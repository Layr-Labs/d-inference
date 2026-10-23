import Foundation

/// The Autopilot model set at runtime (`AutopilotModelSet`): the persisted
/// selection plus the cached builds of `autopilotInventoryModels`. The start
/// path fills the inventory with every verified catalog build this machine
/// can run; a verified Autopilot download or prefetched build joins it, and a
/// superseded or deleted build leaves it. No change touches the consent
/// revision, so an accepted operation or lease stays valid.
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
        guard autopilotSettings.hasConsent else { return false }
        if autopilotSettings.selectedModels.contains(id) { return true }
        guard !loopConfig.config.coordinator.privateOnly, autopilotInventoryModels[id] != nil,
              AutopilotModelSet.isReportableID(id) else { return false }
        if autopilotSettings.selectedModels.count + autopilotInventoryModels.count <= AutopilotModelSet.maximumCount {
            return true
        }
        return autopilotModelSet.contains(id)
    }

    /// A verified catalog build joins the set. Its hash joins the live hashes
    /// a registration filters inventory by; the caller pushes them to the
    /// client. `register` is the only carrier of inventory metadata, so a
    /// build the coordinator has not seen waits for a re-registration unless
    /// it is advertised (`models_update`).
    func addAutopilotCachedBuild(_ model: ModelInfo) {
        guard autopilotConsented, let hash = model.weightHash, !hash.isEmpty,
              AutopilotModelSet.isReportableID(model.id) else { return }
        let isNew = autopilotInventoryModels[model.id]?.weightHash != hash
        autopilotInventoryModels[model.id] = model
        modelHashes[model.id] = hash
        liveModelHashes[model.id] = hash
        if isNew && !ordinaryServingModelIDs.contains(model.id) {
            autopilotInventoryAwaitingRegistration.insert(model.id)
        }
        publishModelAutopilotSnapshot()
    }

    /// A build the ordinary prefetch verified against the catalog joins the
    /// set when it fits this machine's load budget.
    func joinsAutopilotSetWhenVerified(_ model: ModelInfo) -> Bool {
        autopilotConsented && AutopilotModelSet.isReportableID(model.id)
            && AutopilotBuildEligibility.fitsLoadBudget(sizeGb: model.estimatedMemoryGb,
                memoryGb: Double(loopConfig.hardware.memoryGb))
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
        guard !autopilotInventoryAwaitingRegistration.isEmpty, autopilotConsented,
              !autopilotNeedsInventoryRefresh, autopilotCommand == nil, autopilotBusyReasons().isEmpty,
              let client = coordinatorClient, await client.hasRegisteredConnection()
        else { return }
        // Recheck after the client hop.
        guard autopilotCommand == nil, autopilotBusyReasons().isEmpty else { return }
        logger.info("Re-registering to report Autopilot inventory: \(autopilotInventoryAwaitingRegistration.sorted().joined(separator: ", "))")
        autopilotInventoryAwaitingRegistration.removeAll()
        requestPlannedReconnect()
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
}
