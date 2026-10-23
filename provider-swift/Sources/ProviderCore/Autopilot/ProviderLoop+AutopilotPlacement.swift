import Foundation

/// One placement hold: the monotonic expiry enforces it, and the wall-clock
/// expiry captured with it is what heartbeats report.
struct AutopilotHold: Sendable, Equatable {
    let until: ContinuousClock.Instant
    let untilMs: Int64
}

/// Placements of succeeded operations outlive the operation-scoped lease, but
/// never their basis: saved consent, the operator's selection, a resident slot
/// and a build that has not failed verification. Adoption keeps a cached
/// inventory target serving; a hold keeps a loaded target out of LRU eviction
/// and idle unload. Both live in memory only: a restart restores the ordinary
/// selection and idle policy. Neither is machine-level control: other models,
/// ordinary cold loads into free memory and routing are unaffected.
extension ProviderLoop {
    private func autopilotPlacementBasisIsValid(_ id: String) -> Bool {
        !isShuttingDown && autopilotConsented && autopilotSettings.allows(id)
            && modelSlots[id] != nil && !retiringModels.contains(id) && failedSelfTestHashes[id] == nil
    }

    /// A hold also ends when its model stops being advertised (withdrawal,
    /// release drop or retirement): it never retains an unserved build.
    private func autopilotHoldBasisIsValid(_ id: String) -> Bool {
        autopilotPlacementBasisIsValid(id) && advertisedModels[id] != nil
    }

    func autopilotAdoptionIsValid(_ id: String) -> Bool {
        autopilotAdoptedModelIDs.contains(id) && !ordinaryServingModelIDs.contains(id)
            && autopilotInventoryModels[id]?.weightHash?.isEmpty == false
            && autopilotPlacementBasisIsValid(id)
    }

    /// Serving permission: `autopilotAllowsModel` plus valid adoption.
    /// Adoption grants serving only; prefetch, publication, desired-build and
    /// revision changes keep requiring ordinary selection or a live lease.
    func autopilotServesModel(_ id: String) -> Bool {
        autopilotAllowsModel(id) || autopilotAdoptionIsValid(id)
    }

    func autopilotHoldsModel(_ id: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard let hold = autopilotHolds[id] else { return false }
        return hold.until > now && autopilotHoldBasisIsValid(id)
    }

    /// The idle-timeout reference: an expired hold restarts the full timeout
    /// at its expiry rather than unloading the model at the next tick.
    func autopilotIdleSince(_ id: String, lastInferenceAt: ContinuousClock.Instant) -> ContinuousClock.Instant {
        guard let hold = autopilotHolds[id], autopilotHoldBasisIsValid(id) else { return lastInferenceAt }
        return max(lastInferenceAt, hold.until)
    }

    /// Called once the operation's target is resident and published, before
    /// the command releases ownership: the end of a lease must never withdraw
    /// a target that should be adopted.
    func recordAutopilotPlacement(_ command: ModelAutopilotCommand) {
        guard let target = command.loadModelId, modelSlots[target] != nil else { return }
        if autopilotInventoryModels[target] != nil, !ordinaryServingModelIDs.contains(target) {
            autopilotAdoptedModelIDs.insert(target)
        }
        if let seconds = command.holdSeconds, seconds > 0 {
            autopilotHolds[target] = AutopilotHold(until: .now.advanced(by: .seconds(seconds)),
                untilMs: Self.autopilotNowMs &+ Int64(seconds) * 1_000)
        }
        reconcileAutopilotPlacements()
    }

    /// Drops every adoption and hold whose basis ended. Holds are checked
    /// after newly unadopted inventory is withdrawn, so no hold outlives its
    /// model's advertisement. Runs before each snapshot publication and right
    /// after an unload removes a slot.
    func reconcileAutopilotPlacements() {
        guard !autopilotAdoptedModelIDs.isEmpty || !autopilotHolds.isEmpty else { return }
        let adopted = autopilotAdoptedModelIDs.filter { autopilotAdoptionIsValid($0) }
        if adopted != autopilotAdoptedModelIDs {
            autopilotAdoptedModelIDs = adopted
            withdrawInactiveAutopilotModels()
        }
        autopilotHolds = autopilotHolds.filter { autopilotHoldBasisIsValid($0.key) }
    }

    /// Resident weights an ordinary cold load cannot reclaim.
    func autopilotHeldWeightBytes() -> UInt64 {
        let now = ContinuousClock.now
        return modelSlots.reduce(UInt64(0)) { total, entry in
            guard autopilotHoldsModel(entry.key, now: now) else { return total }
            let (sum, overflow) = total.addingReportingOverflow(UInt64(max(0, entry.value.sizing.weightsBytes)))
            return overflow ? .max : sum
        }
    }

    /// The reported placements, by model: valid adoptions and unexpired holds.
    func autopilotPlacementReport(now: ContinuousClock.Instant)
        -> (adopted: [String]?, held: [ModelAutopilotHold]?) {
        let adopted = autopilotAdoptedModelIDs.filter { autopilotAdoptionIsValid($0) }.sorted()
        let held = autopilotHolds.sorted { $0.key < $1.key }
            .filter { autopilotHoldsModel($0.key, now: now) }
            .map { ModelAutopilotHold(modelId: $0.key, expiresAtMs: $0.value.untilMs) }
        return (adopted.isEmpty ? nil : adopted, held.isEmpty ? nil : held)
    }
}
