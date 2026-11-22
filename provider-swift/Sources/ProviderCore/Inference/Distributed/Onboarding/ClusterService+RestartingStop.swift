import Foundation

/// The control leader's automatic steps that stop the pair only to start it again: the re-plan after a Darkbloom update
/// (`checkForUpdate`), the memory re-plan (`replanForMemory`) and a change of the pair's cluster approval
/// (`checkApproval`). Each runs as one restarting stop (`ClusterRestartingStop.run`), which keeps the first of three
/// invariants for all of them; the steps keep the other two:
/// - A step never loses the pair's saved start. Their stop is the one a person's stop runs
///   (`OnboardingLive.localStop`, never counted as asked for: `ClusterSetupRecord.stopsAsked`): it clears the saved start
///   before it stops anything. The steps act only while the start is saved, and nothing else starts a pair again, so
///   the start is put back when a step ends, whichever of its parts failed, the stop included, and by the service's
///   next run when the service was ended in the middle of the step (`resumeInterruptedRestart`).
/// - A stop the owner made is never undone. Every stop of the pair holds the control command lock (a person's, typed
///   here or forwarded by the other Mac, and `releaseForSingleMac`'s), and once a step holds it, it stops and starts the
///   pair only while the start is still saved: the re-plans read it again (`commandLockIfStillStarted`), and the
///   approval change decides again.
/// - None acts on an unconfirmed claim: each checks `leadershipConfirmed` before it begins and again once it holds
///   the control command lock. The Macs restart into an update seconds apart, and the one back first may take control
///   meanwhile: the other Mac then refuses the stop of a leader whose saved claim it superseded.
///
/// The steps take the command lock beside this service's own files: on a Mac, the one every cluster command takes.
///
/// A DevNet pair, 2026-11-07 (`0.10.10-dev.branch.135` → `.137`): such a stop failed right after both Macs restarted
/// into the update, and the pair stayed stopped on both Macs until `darkbloom cluster` was run.
extension ClusterService {
    /// This service's restarting stops, with its switches (`resumesInterruptedUpdateReplan`, `updateReplanGuard`).
    var restartingStops: ClusterRestartingStop {
        .init(store: store, localUpdateRestart: resumesInterruptedUpdateReplan, updateReplanGuard: updateReplanGuard)
    }

    /// The steps of the re-plan after an update, as the control leader's onboarding operations run them (`controlLive`);
    /// tests stand in.
    struct UpdateReplan {
        var reachMembers: () -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>
        var stop: () -> Result<[String], ClusterOnboardingFailure>
        var awaitReleased: () -> Void
        var planModels: () -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure>
        var adopt: (Int) -> Result<[String], ClusterOnboardingFailure>
        var serve: () -> Result<[String], ClusterOnboardingFailure>
    }

    /// Sets the cluster up again for `model` (its id) once both Macs run one build: both Macs reached, both parts stopped
    /// and their memory waited for, then the same model planned again, adopted and served. Both Macs refuse the old parts
    /// once their workers changed, and planned while they run, a tensor-parallel pair does not fit "now" and a pipeline is
    /// chosen in its place. One restarting stop: a failure, of its stop too, leaves the saved start as it was, so the
    /// next check tries again. The model's choice as planned, or why the cluster was not set up again; nil, with
    /// nothing run, while this Mac's update restarts this service next or the setup record cannot be read
    /// (`ClusterRestartingStop.run`).
    func replanAfterUpdate(model: String, _ steps: UpdateReplan) -> Result<ClusterOnboardingModelChoice, ClusterOnboardingFailure>? {
        restartingStops.run(.updateReplan) {
            // Nothing is stopped while the other Mac is not reached: the saved start is still as it was.
            if case .failure(let failure) = steps.reachMembers() { return .failure(failure) }
            if case .failure(let failure) = steps.stop() { return .failure(failure) }
            steps.awaitReleased()
            let choices: [ClusterOnboardingModelChoice]
            switch steps.planModels() {
            case .success(let value): choices = value
            case .failure(let failure): return .failure(failure)
            }
            // `model` is the model's id (the record keeps ids; the screens show catalog names).
            guard let index = ClusterOnboardingUpdate.servableIndex(of: model, in: choices) else {
                return .failure(.init("\(model) is not offered on these Macs with this release: "
                    + (choices.first { ($0.modelID ?? $0.title) == model }?.blocker ?? "not found")))
            }
            if case .failure(let failure) = steps.adopt(index) { return .failure(failure) }
            if case .failure(let failure) = steps.serve() { return .failure(failure) }
            return .success(choices[index])
        }
    }

    /// The stop, the wait for both parts to end, and the start of an approval change, as the control leader's
    /// onboarding operations run them (`controlLive`), and its sends to the other Mac; tests stand in.
    struct ApprovalChange {
        var stop: () -> Result<[String], ClusterOnboardingFailure>
        var drained: () -> Bool
        var serve: () -> Result<[String], ClusterOnboardingFailure>
        var sendToPeer: (ClusterServiceCommand) throws -> Void
    }

    /// `checkApproval`'s change for `step` on both Macs (`ClusterApprovalSync.apply`), under the command lock. A pair
    /// that serves is stopped for it and started again as one restarting stop: when the stop or the start fails, the
    /// saved start is as it was, so the pair serves as before and the next check tries again. What the change did;
    /// nil, with nothing run, while this Mac's update restarts this service next or the setup record cannot be read
    /// (`ClusterRestartingStop.run`).
    func changeApproval(_ step: ClusterApprovalCheck.Step, serving: Bool, _ steps: ApprovalChange,
                        say: (String) -> Void) -> ClusterApprovalSync.Result? {
        restartingStops.run(.approvalChange) {
            ClusterApprovalSync.apply(step, grace: Self.soloGraceSeconds, paths: context.paths,
                providerConfiguration: settings.wizard.providerConfiguration, pairingStore: pairingStore,
                scratch: store.paths.directory, now: Date().timeIntervalSince1970,
                stop: { Self.stopForApprovalChange(serving: serving, stop: steps.stop, drained: steps.drained) },
                serve: { if let line = Self.restartAfterApprovalChange(serving: serving, serve: steps.serve) { say(line) } },
                sendToPeer: steps.sendToPeer)
        }
    }

    /// The approval change's stop of both parts before it changes the cluster approval on both Macs
    /// (`ClusterApprovalSync.apply`): nil once both stopped (or the pair was not serving), else the line why not.
    static func stopForApprovalChange(serving: Bool, stop: () -> Result<[String], ClusterOnboardingFailure>,
                                      drained: () -> Bool) -> String? {
        guard serving else { return nil }
        if case .failure(let failure) = stop() {
            return "could not stop the parts to change the cluster approval: " + failure.lines.joined(separator: " ")
                + " The pair stays started; the change is tried again at the next check."
        }
        guard drained() else { return "a part did not stop within 5 minutes: the cluster approval stays as it is" }
        return nil
    }

    /// The approval change's start of both parts again once the cluster approval changed (`ClusterApprovalSync.apply`
    /// calls it after every stop that succeeded): nil once started (or the pair was not serving), else the line why
    /// not. The service then starts this Mac's part again and syncs the other Mac's.
    static func restartAfterApprovalChange(serving: Bool, serve: () -> Result<[String], ClusterOnboardingFailure>) -> String? {
        guard serving, case .failure(let failure) = serve() else { return nil }
        return "could not start the parts again after the cluster approval changed: " + failure.lines.joined(separator: " ")
    }

    /// The marks of steps the previous run of this service, or a registration on this Mac, began and never ended (a
    /// service ended in the middle of a re-plan after an update, on DevNet pairs): the start the step's stop cleared is
    /// put back, as the step's own end would have (`ClusterRestartingStop.resume`). Only a recent mark of a step this
    /// Mac still leads is acted on (its control claim, `followsPeer`: the steps run on the derived control leader,
    /// whichever Mac drove the onboarding), and only while the start is still cleared and no stop a person asked for was
    /// counted since (`ClusterSetupRecord.stopsAsked`; a stop while the pair is down, which isn't counted, drops the
    /// marks: `forgetInterruptedRestart`). Every mark is dropped, the re-plan after an update's also with its switch
    /// off (`ClusterLocalPairUpdate` for a local-only pair, `ClusterUpdateReplanGuard` for another). The line for the
    /// log, or nil when there was nothing to put back.
    func resumeInterruptedRestart(now: Double = Date().timeIntervalSince1970) -> String? {
        let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore)
        return restartingStops.resume(now: now) { Self.leadsByControl(record: $0, pairing: pairing) }
            .map { ClusterRestartingStop.resumedLine($0.step, secondsAgo: $0.secondsAgo) }
    }

    /// Whether this Mac holds the recorded control claim (`followsPeer`); with the pairing unreadable (a locked
    /// Keychain at login), the onboarding's role says, as before the claim was asked.
    static func leadsByControl(record: ClusterSetupRecord, pairing: ClusterSetupLinkExchange.Pairing?) -> Bool {
        guard let pairing else { return record.leadership?.role == ClusterOnboardingRole.leader.rawValue }
        return !followsPeer(record: record, pairing: pairing)
    }

    /// A person stopped this Mac's pair while it was down (`darkbloom stop`, which counts no stop then, or `darkbloom
    /// start --solo` releasing this Mac's part, `releaseForSingleMac`): a step that a restart ended is not resumed.
    /// (Single-Mac serving started without a part to release holds the part back anyway.) False when this Mac's record
    /// could not be read or written (`ClusterRestartingStop.forget`). `darkbloom stop` goes on all the same: it has
    /// this Mac's provider to drain and stop yet.
    @discardableResult
    public static func forgetInterruptedRestart() -> Bool {
        guard let paths = try? ClusterUserPaths() else { return true }
        return ClusterRestartingStop(store: ClusterSetupStore(paths: ClusterSetupPaths(paths: paths))).forget()
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
