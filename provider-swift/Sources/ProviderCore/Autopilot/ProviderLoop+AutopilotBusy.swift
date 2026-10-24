import Foundation

extension ProviderLoop {
    /// Every condition that refuses a new residency operation, in report
    /// order. Empty exactly when the operation policy's `busy` input is false;
    /// an accepted operation is deliberately not an input.
    func autopilotBusyReasons() -> [ModelAutopilotBusyReason] {
        ModelAutopilotBusyReason.allCases.filter { isAutopilotBusy(because: $0) }
    }

    private func isAutopilotBusy(because reason: ModelAutopilotBusyReason) -> Bool {
        switch reason {
        case .autopilotOperation: return false
        case .shuttingDown: return isShuttingDown
        case .draining: return isDraining
        case .reconnectAfterRetirement: return isReconnectingAfterRetirement
        case .modelSwitch: return modelSwitchTask != nil
        case .revisionActivation: return modelRevisionActivationID != nil
        case .revisionUpdate: return !revisionUpdatesInProgress.isEmpty
        case .startupPreload: return startupPreloadTask != nil
        case .preload: return !preloadTasks.isEmpty
        case .engineRecovery: return !engineV2RecoveryInProgress.isEmpty
        case .mtpUpgrade: return !mtpUpgradeTransitions.isEmpty
        case .mtpStaging: return mtpStagingReservations.hasRetainedTargets
        case .modelAdvertisement: return modelAdvertisementsInFlight > 0
        case .pendingAdvertisement: return !pendingAdvertise.isEmpty
        case .loadGate: return isLoadingAny
        case .modelLoading: return !modelsLoading.isEmpty
        case .reslice: return isReslicing
        case .modelUnloading: return !modelsUnloading.isEmpty
        case .modelRetiring: return !retiringModels.isEmpty
        case .nativeMemoryRetained: return !nativeMiMoAllowsReclamation()
        case .inflightWork: return hasInflightWork
        }
    }

    /// What heartbeats report: an accepted operation outranks the transitions
    /// it owns.
    func reportedAutopilotBusyReasons() -> [ModelAutopilotBusyReason] {
        (autopilotCommand != nil ? [.autopilotOperation] : []) + autopilotBusyReasons()
    }
}
