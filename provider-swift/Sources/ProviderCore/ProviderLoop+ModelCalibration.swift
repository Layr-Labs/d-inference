import Foundation

extension ProviderLoop {
    func refreshModelCalibration() async {
        for id in modelSlots.keys.sorted() {
            guard !isLoadingAny else { return }
            await scheduleLoadedModelCalibration(modelID: id)
        }
    }

    /// The load owner may call this while retaining its load-transition gate.
    /// It has finished construction and released the device-work receipt; a
    /// general refresh must still reject in-flight loads.
    func scheduleLoadedModelCalibration(modelID: String) async {
        guard !Task.isCancelled, !isShuttingDown, !servingDrain.refusing,
            modelsUnloading.isEmpty, let slot = modelSlots[modelID] else { return }
        let onRetired: @Sendable () async -> Void = { [weak self] in
            await self?.refreshModelCalibration()
        }
        // A slot that never calibrates (reviewed deadline profile) still gets
        // the excluded shape warmup under the same idle gate.
        if !(await slot.engineV2.startModelCalibrationIfNeeded(onRetired: onRetired)) {
            await slot.engineV2.startShapeWarmupIfNeeded(onRetired: onRetired)
        }
    }
}
