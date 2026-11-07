import Foundation

/// The control leader's automatic steps that stop the pair only to start it again: the re-plan after a Darkbloom update
/// (`checkForUpdate`) and a change of the pair's cluster approval (`checkApproval`). Their stop is a person's stop
/// (`OnboardingLive.localStop`), which clears the pair's saved start before it stops anything.
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
        if case .failure(let failure) = steps.stop() { return .failure(failure) }
        steps.awaitReleased()
        // A failure from here on keeps the serving intent, so the next check tries again.
        func failed(_ failure: ClusterOnboardingFailure) -> Result<ClusterOnboardingModelChoice, ClusterOnboardingFailure> {
            steps.restoreStart()
            return .failure(failure)
        }
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
    /// nil once both stopped (or the pair was not serving), else the line why not, and the approval stays as it is.
    static func stopForApprovalChange(serving: Bool, stop: () -> Result<[String], ClusterOnboardingFailure>, drained: () -> Bool,
                                      restoreStart: () -> Void) -> String? {
        guard serving else { return nil }
        if case .failure(let failure) = stop() {
            return "could not stop the parts to change the cluster approval: " + failure.lines.joined(separator: " ")
        }
        guard drained() else {
            restoreStart()
            return "a part did not stop within 5 minutes: the cluster approval stays as it is"
        }
        return nil
    }

    /// Puts the pair's saved start back after an automatic step stopped it to start it again.
    func restoreStart() {
        try? store.updateRecord { $0.leadership?.serving = true }
    }
}
