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
        await slot.engineV2.startModelCalibrationIfNeeded(onRetired: { [weak self] in
            await self?.refreshModelCalibration()
        })
    }
}
