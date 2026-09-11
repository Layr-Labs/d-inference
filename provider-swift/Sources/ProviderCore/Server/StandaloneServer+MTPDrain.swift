import Foundation

extension StandaloneServer {
    func beginMTPUpgradeDrain(_ staged: StagedStandaloneMTPUpgrade) throws {
        try Task.checkCancellation()
        guard let original = staged.original,
            slots[staged.modelID]?.bridge === original.bridge,
            pendingMTPUpgradeModels().contains(staged.modelID),
            mtpAdmissionDrains.begin(staged.modelID, owner: staged.drainID)
        else { throw CancellationError() }
        standaloneLogger.info("mtp: draining accepted requests before assistant swap for \(staged.modelID)")
    }

    func finishMTPUpgradeDrain(_ staged: StagedStandaloneMTPUpgrade) {
        guard mtpAdmissionDrains.end(staged.modelID, owner: staged.drainID) else { return }
        standaloneLogger.info("mtp: assistant upgrade admission reopened for \(staged.modelID)")
    }

    func throwIfMTPUpgradeDraining(_ modelID: String) throws {
        guard mtpAdmissionDrains.contains(modelID) else { return }
        throw MultiModelBatchSchedulerEngineError.requestRejected("model temporarily unavailable during assistant upgrade")
    }
}
