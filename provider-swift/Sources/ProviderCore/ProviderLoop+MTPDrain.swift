import Foundation

/// Close new admission only after a verified replacement is prepared.
/// Accepted requests retain the serving engine until the idle publication.
extension ProviderLoop {
    func waitBeforeMTPUpgradeDrain(_ modelID: String) async throws {
        let delay = UpdateJitter.delay(maxSeconds: loopConfig.config.provider.updateJitterSeconds)
        guard delay > .zero else { return }
        logger.info("mtp: model=\(modelID) replacement ready; serving during rollout jitter \(delay)")
        try await taskSleep(delay)
    }

    func beginMTPUpgradeDrain(_ staged: StagedProviderMTPUpgrade) async throws {
        try Task.checkCancellation()
        guard let original = staged.original,
            modelSlots[staged.modelID]?.engineV2 === original.engineV2,
            pendingMTPUpgradeModels().contains(staged.modelID),
            mtpAdmissionDrains.begin(staged.modelID, owner: staged.drainID)
        else { throw CancellationError() }
        state.setModelAdmissionDraining(staged.modelID, true)
        // This fence closes NEW admission only. Already accepted requests must
        // still pass ensureModelLoaded and finish on the original engine.
        await updateAggregateCapacity()
        if let client = coordinatorClient { await client.sendEventHeartbeat() }
        try Task.checkCancellation()
        guard let original = staged.original,
            modelSlots[staged.modelID]?.engineV2 === original.engineV2,
            pendingMTPUpgradeModels().contains(staged.modelID)
        else { throw CancellationError() }
        logger.info("mtp: model=\(staged.modelID) draining accepted requests before assistant swap")
    }

    func finishMTPUpgradeDrain(_ staged: StagedProviderMTPUpgrade) async {
        guard mtpAdmissionDrains.end(staged.modelID, owner: staged.drainID) else { return }
        state.setModelAdmissionDraining(staged.modelID, false)
        await updateAggregateCapacity()
        if let client = coordinatorClient { await client.sendEventHeartbeat() }
    }

    /// A model-scoped assistant swap uses slot_state, not error_reason=draining:
    /// the latter withdraws the entire provider in existing coordinators.
    internal func rejectIfDrainingForMTP(
        modelId: String, requestId: String, send: SendHandle,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer
    ) -> Bool {
        guard mtpAdmissionDrains.contains(modelId) else { return false }
        lookupReceiptFinalizer.sendTerminal(
            .inferenceError(requestId: requestId,
                failure: CapacityRejectionEnrichment.enrich(
                    InferenceFailure(code: .capacity, statusCode: 503),
                    modelId: modelId, published: state.publishedCapacity,
                    fallbackReason: .slotState),
                profile: inflightProfiles[requestId]),
            fallbackFailure: .capacity, send: send)
        return true
    }

}
