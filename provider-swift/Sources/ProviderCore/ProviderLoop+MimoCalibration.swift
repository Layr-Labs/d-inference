import Foundation

extension ProviderLoop {
    func refreshMimoCalibration() async {
        guard !isShuttingDown, !isLoadingAny, modelsUnloading.isEmpty else { return }
        for slot in modelSlots.values {
            await slot.engineV2.startMimoCalibrationIfNeeded()
        }
    }
}
