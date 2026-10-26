import Foundation

/// The operator's selection outranks an Autopilot placement outside it once
/// the placement's hold is over. A policy change for owner review, kept apart
/// from the recovery mechanism (`ProviderLoop+SelectedModelRecovery`).
///
/// - An operation that unloads selected models to place a model outside the
///   selection queues them for recovery (`queueSelectedModelsDisplaced`).
/// - An adopted model outside the selection that keeps a waiting selected
///   model out only because it serves requests, with no unexpired hold, is
///   released `adoptionReleaseDelay` after its hold expired (or after the
///   selected model began waiting, without a hold): it takes no new requests,
///   finishes those in flight, and the next check evicts it. A hold is always
///   honoured, and a selected or pinned model is never released.
extension ProviderLoop {
    static let adoptionReleaseDelay: Duration = .seconds(600)

    func queueSelectedModelsDisplaced(by command: ModelAutopilotCommand) {
        guard let target = command.loadModelId, !isProtectedFromRecoveryEviction(target) else { return }
        enqueueSelectedModelRecovery(command.unloadModelIds.filter { ordinaryServingModelIDs.contains($0) })
    }

    /// When `id` may be released for a model waiting since `since`: adopted
    /// outside the selection, unheld, and excluded from eviction only by the
    /// work it serves. Nil when it never may.
    func adoptionReleaseTime(_ id: String, reasons: [EvictionExclusionReason],
                             waitingSince since: ContinuousClock.Instant,
                             now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard !isProtectedFromRecoveryEviction(id), autopilotAdoptionIsValid(id),
              !autopilotHoldsModel(id, now: now), !reasons.isEmpty, reasons.allSatisfy(\.isServing)
        else { return nil }
        let anchor = autopilotHolds[id].map { max(since, $0.until) } ?? since
        return anchor.advanced(by: Self.adoptionReleaseDelay)
    }

    /// Ends `id`'s adoption: it is withdrawn and refuses new requests as not
    /// selected, while those in flight finish. The coordinator learns it from
    /// the next snapshot and heartbeat.
    func releaseAdoptionForSelectedModelRecovery(_ id: String, target: String) async -> String {
        let inFlight = requestToModel.values.filter { $0 == id }.count
        if autopilotAdoptedModelIDs.remove(id) != nil {
            withdrawInactiveAutopilotModels()
            autopilotGeneration &+= 1
            publishModelAutopilotSnapshot()
            logger.info("Selected-model recovery: released the Autopilot adoption of \(id) so \(target) "
                + "can load once its requests finish")
            await updateAggregateCapacity()
            await coordinatorClient?.sendEventHeartbeat()
        }
        return "released the Autopilot adoption of \(id); waiting for its "
            + (inFlight == 1 ? "1 request" : "\(inFlight) requests") + " in flight"
    }
}
