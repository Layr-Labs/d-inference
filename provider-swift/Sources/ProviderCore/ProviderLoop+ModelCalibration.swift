import Foundation

extension ProviderLoop {
    func refreshModelCalibration() async {
        for slot in modelSlots.values {
            guard !Task.isCancelled, !isShuttingDown, !servingDrain.refusing,
                !isLoadingAny, modelsUnloading.isEmpty else { return }
            await slot.engineV2.startModelCalibrationIfNeeded(onRetired: { [weak self] in
                await self?.refreshModelCalibration()
            })
        }
    }
}
