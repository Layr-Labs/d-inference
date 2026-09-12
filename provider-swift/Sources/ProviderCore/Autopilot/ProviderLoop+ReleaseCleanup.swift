import Foundation

extension ProviderLoop {
    /// Desired-build releases already retire the old advertisement. Pausing the
    /// ordinary idle timer must not strand those known-obsolete GPU residents.
    /// This path cannot infer retirement from an absent catalog entry and never
    /// takes a still-supported co-resident out of service.
    internal func cleanupAutopilotSupersededModels() async {
        guard modelAutopilotEnabled, autopilotCommand == nil, !isShuttingDown,
              !isDrainingForUpdate, !isLoadingAny, !isReslicing,
              engineV2RecoveryInProgress.isEmpty else { return }
        var attempts = 0
        for model in autopilotSupersededModels.sorted() {
            guard autopilotCommand == nil, !isShuttingDown, !isDrainingForUpdate,
                  !isLoadingAny, !isReslicing else { return }
            // Advertisement returned (rollback/new release choice), or the
            // slot is already gone: the earlier release no longer owns it.
            guard advertisedModels[model] == nil, modelSlots[model] != nil else {
                autopilotSupersededModels.remove(model)
                continue
            }
            guard !autopilotPinnedModels.contains(model), !requestToModel.values.contains(model),
                  !hasLocalReservation(model), !modelsUnloading.contains(model),
                  !modelsLoading.contains(model), !isMTPUpgradeTargetRetained(model),
                  !engineV2RecoveryInProgress.contains(model) else { continue }
            guard attempts < 4 else { return }
            attempts += 1
            // unloadModel repeats request/local/MTP/command-owner checks after
            // its own suspension and publishes actual final capacity.
            if await unloadModel(model, forEviction: true) {
                autopilotSupersededModels.remove(model)
            }
        }
    }
}
