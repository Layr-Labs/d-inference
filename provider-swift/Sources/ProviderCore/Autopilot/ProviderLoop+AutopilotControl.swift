import Foundation

extension ProviderLoop {
    var autopilotSettings: ModelAutopilotSettings {
        autopilotSettingsOverride ?? loopConfig.config.backend.modelAutopilot
    }

    var autopilotConsented: Bool {
        autopilotSettings.hasConsent && !loopConfig.config.coordinator.privateOnly
    }

    var autopilotManagesResidency: Bool {
        modelAutopilotEnabled || (autopilotConsented && autopilotSettings.paused)
    }

    /// Pins belong to live residency control, an explicit pause, or an accepted
    /// operation. Saved consent alone must not block the restored idle policy.
    var autopilotProtectsPins: Bool {
        autopilotManagesResidency || autopilotCommand != nil
    }

    var autopilotOperationView: DaemonState.AutopilotOperation? {
        let last = autopilotLastCommandId.flatMap { autopilotHistory[$0]?.0 }
        guard let command = autopilotCommand ?? last else { return nil }
        return .init(reason: command.reason ?? "coordinator placement", target: command.loadModelId,
            releasing: command.unloadModelIds, elapsedMs: autopilotCommand == nil ? autopilotLastElapsedMs : nil)
    }

    var autopilotPhase: String {
        if autopilotCommand != nil { return modelAutopilotEnabled ? "transitioning" : "recovering" }
        if !autopilotConsented { return "off" }
        if autopilotSettings.paused { return "paused" }
        if autopilotControlIsValid && autopilotControl?.observeOnly == true { return "shadow" }
        return modelAutopilotEnabled ? "active" : "waiting"
    }

    func autopilotAllowsModel(_ id: String) -> Bool {
        if ordinaryServingModelIDs.contains(id) { return true }
        if !autopilotSettings.enabled {
            return autopilotInventoryModels[id] == nil
        }
        // Inventory is observational until a valid live lease. Never let
        // waiting, shadow, paused, expired or disconnected control widen it.
        return modelAutopilotEnabled && autopilotSettings.allows(id)
            && autopilotInventoryModels[id] != nil
    }

    /// Connection loss and lease expiry both restore the saved idle policy.
    /// The idle tick still defers to accepted commands; explicit pause retains
    /// residency ownership even while the coordinator is unavailable.
    func clearAutopilotControl() {
        guard autopilotControl != nil else { return }
        autopilotControl = nil
        withdrawInactiveAutopilotModels()
        autopilotGeneration &+= 1
        startIdleMonitor()
        publishModelAutopilotSnapshot()
    }

    /// Only the daemon started with this config path reads live policy changes.
    /// Tests and embedded loops with no path never read the user's config.
    func refreshAutopilotSettings() {
        guard let path = loopConfig.configPath,
              let config = try? ConfigManager.load(from: path) else { return }
        let settings = config.backend.modelAutopilot
        guard settings != autopilotSettings else { return }
        let previouslyManaged = autopilotManagesResidency
        let hadControl = autopilotControl != nil
        autopilotSettingsOverride = settings
        autopilotControl = nil
        withdrawInactiveAutopilotModels()
        autopilotGeneration &+= 1
        // Disabling / pausing does not cancel an accepted mutation. Its owner
        // finishes and publishes actual capacity before ordinary changes resume.
        if hadControl || previouslyManaged != autopilotManagesResidency { startIdleMonitor() }
        publishModelAutopilotSnapshot()
    }

    func handleAutopilotControl(_ control: ModelAutopilotControl) async {
        refreshAutopilotSettings()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard autopilotConsented, control.revision == autopilotSettings.revision,
              !control.sessionId.isEmpty, control.sessionId.utf8.count <= 128,
              control.expiresAtMs <= now + 200_000 else { return }
        let previouslyManaged = autopilotManagesResidency
        if control.enabled && control.expiresAtMs > now && !autopilotSettings.paused {
            autopilotControl = control
            autopilotGeneration &+= 1
            if previouslyManaged != autopilotManagesResidency
                || (!autopilotManagesResidency && idleMonitorTask == nil) { startIdleMonitor() }
        } else {
            clearAutopilotControl()
        }
        withdrawInactiveAutopilotModels()
        restoreAutopilotResidentModels()
        await refreshActivationReserve()
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
        writeDaemonState()
    }
}
