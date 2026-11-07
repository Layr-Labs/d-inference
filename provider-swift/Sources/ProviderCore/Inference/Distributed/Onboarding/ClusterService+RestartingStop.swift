import Foundation

/// The control leader's automatic steps that stop the pair only to start it again: the re-plan after a Darkbloom update
/// (`checkForUpdate`) and a change of the pair's cluster approval (`checkApproval`). Their stop is a person's stop
/// (`OnboardingLive.localStop`), which clears the pair's saved start before it stops anything, so a failed stop must put
/// it back: both steps act only while the start is saved, and nothing else starts a pair again. DevNet pair-2, 2026-11-07
/// (`0.10.10-dev.branch.135` → `.137`): such a stop failed right after both Macs restarted into the update, and the pair
/// stayed stopped on both Macs until `darkbloom cluster` was run.
extension ClusterService {
    /// The steps of the re-plan after an update, as the control leader's onboarding operations run them (`controlLive`);
    /// tests stand in.
    struct UpdateReplan {
        var reachMembers: () -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>
        var stop: () -> Result<[String], ClusterOnboardingFailure>
        var awaitReleased: () -> Void
        var planModels: () -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure>
        var adopt: (Int) -> Result<[String], ClusterOnboardingFailure>
        var serve: () -> Result<[String], ClusterOnboardingFailure>
        /// Puts the pair's saved start back (`ClusterService.restoreStart`).
        var restoreStart: () -> Void
    }

    /// Sets the cluster up again for `model` (its id) once both Macs run one build: both Macs reached, both parts stopped
    /// and their memory waited for, then the same model planned again, adopted and served. Both Macs refuse the old parts
    /// once their workers changed, and planned while they run, a tensor-parallel pair does not fit "now" and a pipeline is
    /// chosen in its place. The model's choice as planned, or why the cluster was not set up again.
    static func replanAfterUpdate(model: String, _ steps: UpdateReplan) -> Result<ClusterOnboardingModelChoice, ClusterOnboardingFailure> {
        if case .failure(let failure) = steps.reachMembers() { return .failure(failure) }
        // From the stop on, also when the stop itself fails, a failure keeps the serving intent, so the next check tries
        // again.
        func failed(_ failure: ClusterOnboardingFailure) -> Result<ClusterOnboardingModelChoice, ClusterOnboardingFailure> {
            steps.restoreStart()
            return .failure(failure)
        }
        if case .failure(let failure) = steps.stop() { return failed(failure) }
        steps.awaitReleased()
        let choices: [ClusterOnboardingModelChoice]
        switch steps.planModels() {
        case .success(let value): choices = value
        case .failure(let failure): return failed(failure)
        }
        // `model` is the model's id (the record keeps ids; the screens show catalog names).
        guard let index = ClusterOnboardingUpdate.servableIndex(of: model, in: choices) else {
            return failed(.init("\(model) is not offered on these Macs with this release: "
                + (choices.first { ($0.modelID ?? $0.title) == model }?.blocker ?? "not found")))
        }
        if case .failure(let failure) = steps.adopt(index) { return failed(failure) }
        if case .failure(let failure) = steps.serve() { return failed(failure) }
        return .success(choices[index])
    }

    /// `checkApproval`'s stop of both parts before it changes the cluster approval on both Macs (`ClusterApprovalSync.apply`):
    /// nil once both stopped (or the pair was not serving), else the line why not, with the pair's saved start put back,
    /// so it serves as before and the next check tries again.
    static func stopForApprovalChange(serving: Bool, stop: () -> Result<[String], ClusterOnboardingFailure>, drained: () -> Bool,
                                      restoreStart: () -> Void) -> String? {
        guard serving else { return nil }
        if case .failure(let failure) = stop() {
            restoreStart()
            return "could not stop the parts to change the cluster approval: " + failure.lines.joined(separator: " ")
        }
        guard drained() else {
            restoreStart()
            return "a part did not stop within 5 minutes: the cluster approval stays as it is"
        }
        return nil
    }

    /// Puts the pair's saved start back after an automatic step stopped it to start it again, and drops the stop request a
    /// stop that failed midway keeps (this Mac's part had not released yet): left in place, it would hold off every start,
    /// sync and hand-over (`OnboardingLive.localServe`, `syncMembers`). Both steps call it under the control command lock,
    /// so no person's stop is under way.
    func restoreStart() {
        try? store.updateRecord { $0.leadership?.serving = true; $0.stopDrain = nil }
    }
}
