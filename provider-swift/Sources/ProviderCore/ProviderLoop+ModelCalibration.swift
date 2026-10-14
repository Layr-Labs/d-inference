import Foundation

extension ProviderLoop {
    func refreshModelCalibration(prioritizing modelID: String? = nil) async {
        let orderedIDs = modelSlots.keys.sorted { lhs, rhs in
            if lhs == modelID { return rhs != modelID }
            if rhs == modelID { return false }
            return lhs < rhs
        }
        for id in orderedIDs {
            guard !Task.isCancelled, !isShuttingDown, !servingDrain.refusing,
                !isLoadingAny, modelsUnloading.isEmpty else { return }
            guard let slot = modelSlots[id] else { continue }
            await slot.engineV2.startModelCalibrationIfNeeded(onRetired: { [weak self] in
                await self?.refreshModelCalibration()
            })
        }
    }
}
