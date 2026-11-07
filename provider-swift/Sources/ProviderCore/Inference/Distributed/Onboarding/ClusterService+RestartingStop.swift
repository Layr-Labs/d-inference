import Foundation

/// The control leader's automatic steps that stop the pair only to start it again: the re-plan after a Darkbloom update
/// (`checkForUpdate`) and a change of the pair's cluster approval (`checkApproval`). Both keep three invariants:
/// - A failed stop never loses the pair's saved start. Their stop is a person's stop (`OnboardingLive.localStop`): it
///   clears the saved start before it stops anything. Both steps act only while the start is saved, and nothing else
///   starts a pair again, so every failure from the stop on, including the stop's own, puts it back (`restoreStart`).
/// - A stop the owner made is never undone. Every stop of the pair holds the control command lock (a person's, typed
///   here or forwarded by the other Mac, and `releaseForSingleMac`'s), and once a step holds it, it stops and starts the
///   pair only while the start is still saved: the re-plan reads it again (`commandLockIfStillStarted`), and the
///   approval change decides again.
/// - Neither acts on an unconfirmed claim: each checks `leadershipConfirmed` before it begins and again once it holds
///   the control command lock. The Macs restart into an update seconds apart, and the one back first may take control
///   meanwhile: the other Mac then refuses the stop of a leader whose saved claim it superseded.
///
/// The memory re-plan (`replanForMemory`) starts the pair too, and takes the command lock as the re-plan does: it never
/// starts a pair its owner stopped while it waited, nor acts on a claim that moved meanwhile. Its adoption stops a
/// serving pair first (`localAdopt`), and as with the steps, every failure from there puts the start back.
///
/// The steps, and the memory re-plan, take the command lock beside this service's own files: on a Mac, the one every
/// cluster command takes.
///
/// DevNet pair-2, 2026-11-07 (`0.10.10-dev.branch.135` → `.137`): such a stop failed right after both Macs restarted
/// into the update, and the pair stayed stopped on both Macs until `darkbloom cluster` was run.
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
        // Nothing is stopped yet: the saved start is as it was.
        if case .failure(let failure) = steps.reachMembers() { return .failure(failure) }
        // From the stop on, every failure puts the saved start back, including the stop's own, so the next check tries
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
                + " The pair stays started; the change is tried again at the next check."
        }
        guard drained() else {
            restoreStart()
            return "a part did not stop within 5 minutes: the cluster approval stays as it is"
        }
        return nil
    }

    /// `checkApproval`'s start of both parts again once the cluster approval changed (`ClusterApprovalSync.apply` calls
    /// it after every stop that succeeded): nil once started (or the pair was not serving), else the line why not, with
    /// the pair's saved start put back, so the service starts this Mac's part again and syncs the other Mac's.
    static func restartAfterApprovalChange(serving: Bool, serve: () -> Result<[String], ClusterOnboardingFailure>,
                                           restoreStart: () -> Void) -> String? {
        guard serving, case .failure(let failure) = serve() else { return nil }
        restoreStart()
        return "could not start the parts again after the cluster approval changed: " + failure.lines.joined(separator: " ")
    }

    /// Puts the pair's saved start back after an automatic step stopped it to start it again, and drops the stop request a
    /// stop that failed midway keeps (this Mac's part had not released yet): left in place, it would hold off every start,
    /// sync and hand-over (`OnboardingLive.localServe`, `syncMembers`). Both steps call it under the control command lock,
    /// which every stop of the pair holds, so no person's stop is under way.
    func restoreStart() {
        try? store.updateRecord { $0.leadership?.serving = true; $0.stopDrain = nil }
    }

    /// The control command lock for a re-plan of the pair (`checkForUpdate`, `replanForMemory`), taken within 5 s; nil
    /// when it stays busy, or when, once it is held, the pair's start is no longer saved or this Mac no longer leads
    /// on a confirmed claim. Every stop of the pair holds this lock, so a start cleared while the re-plan waited for it
    /// is a stop the owner made, which the re-plan's start would undo.
    func commandLockIfStillStarted() -> ClusterControlCommandLock? {
        guard let held = ClusterControlCommandLock.acquire(seconds: 5,
            file: store.paths.directory.appendingPathComponent("control.lock")) else { return nil }
        guard leadershipConfirmed(), (try? store.readRecord())?.leadership?.serving == true else {
            held.release()
            return nil
        }
        return held
    }
}
