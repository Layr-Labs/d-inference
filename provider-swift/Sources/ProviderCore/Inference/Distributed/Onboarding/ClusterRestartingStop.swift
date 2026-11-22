import Foundation

/// A step that stops the pair only to start it again, as one transaction on the setup record.
///
/// The pair's stop (`OnboardingLive.localStop`) clears the saved start for such a step as it does for a person's stop,
/// and nothing starts a pair whose start is cleared. Each step used to put the start back itself on each of its
/// failures, and only the re-plan after an update left a mark for a service ended in the middle of it: a memory
/// re-plan, a change of the cluster approval or a registration ended between its stop and its start left the pair
/// stopped on both Macs. `run` is now the one way such a step runs:
/// - It begins nothing while this Mac's coordinated update restarts the cluster service next (`hold`): that restart
///   would end the step after its stop.
/// - It marks the record before the step's stop. The re-plan after an update keeps its own mark
///   (`ClusterSetupRecord.updateReplan`, which earlier builds resume); every other step writes
///   `ClusterSetupRecord.restartingStop`, which earlier builds neither read nor keep. Only a step the cluster service
///   runs is marked: a registration that the `darkbloom cluster` command runs itself writes none (`run`).
/// - However the step ends, the start is saved when it ends, the stop request a stop that failed midway keeps is
///   dropped (left in place, it would hold off every start, sync and hand-over: `OnboardingLive.localServe`,
///   `ClusterService.syncMembers`), and the mark is dropped, in one write.
/// - A run of the cluster service that finds a mark follows a step that never ended, and puts the start back
///   (`resume`, `ClusterService.resumeInterruptedRestart`).
///
/// A stop a person asked for is counted (`ClusterSetupRecord.stopsAsked`): one counted since the step began stands,
/// at the step's end and at the next run. The caller holds the control command lock, which every stop of the pair
/// holds, so the start a step finds cleared at its end is the one its own stop cleared.
struct ClusterRestartingStop: Sendable {
    /// The steps. Each is run to every point at which its service can end by the crash-point table
    /// (`ClusterServiceRestartingStopTests`), which names every case.
    enum Step: String, CaseIterable, Sendable {
        /// The re-plan after a Darkbloom update (`ClusterService.checkForUpdate`).
        case updateReplan
        /// The re-plan after a Mac's load gate refused its share twice (`ClusterService.replanForMemory`).
        case memoryReplan
        /// A change of the pair's cluster approval (`ClusterService.checkApproval`).
        case approvalChange
        /// The registration with the coordinator after a start's test (`OnboardingLive.localRegister`).
        case registration
    }

    /// A step under way as the record keeps it; `step` is nil for a name a later build wrote.
    struct Mark: Equatable {
        var step: Step?
        var stopsAsked: Int
        var startedAt: Double
    }

    let store: ClusterSetupStore
    /// Whether a local-only pair's re-plan after an update marks the record and is resumed (`ClusterLocalPairUpdate`).
    var localUpdateRestart = ClusterLocalPairUpdate.enabled()
    /// Whether a step waits for this Mac's coordinated update (`hold`), and any other pair's re-plan after an update
    /// marks the record and is resumed (`ClusterUpdateReplanGuard`).
    var updateReplanGuard = ClusterUpdateReplanGuard.enabled()

    /// How old a mark `resume` acts on may be: a restart follows the step it ended within minutes; an older mark is
    /// one a failed write left behind.
    static let resumeSeconds: Double = 3600

    /// This Mac's coordinated update while it restarts the cluster service next (`ClusterUpdateReplanGuard.holdsReplan`);
    /// nil when it does not, or with the guard switched off.
    func hold(now: Double = Date().timeIntervalSince1970) -> ClusterPairUpdateProgress? {
        guard updateReplanGuard,
              let progress = ClusterPairUpdate.readProgress(
                  from: ClusterServiceAgent.updateProgressPath(serviceDirectory: store.paths.directory)),
              ClusterUpdateReplanGuard.holdsReplan(progress, running: ProviderCore.version, now: now) else { return nil }
        return progress
    }

    /// Runs `body`, which stops the pair and starts it again, as `step`: marked before it, the start saved after it.
    /// Nil, with nothing run, while `hold` holds. On a pair that is not started `body` runs as it is.
    ///
    /// `marked` false: a command runs the step itself, not the cluster service. The service's next run follows the end
    /// of the service, not of that command, so a mark the command left when it was killed would stay until the service
    /// next started, and put a start back then, long after and whatever was decided meanwhile. Such a step writes no
    /// mark; its own end still saves the start.
    func run<Outcome>(_ step: Step, marked: Bool = true, _ body: () -> Outcome) -> Outcome? {
        let before = try? store.readRecord()
        // A pair that is not started has no start to lose: the step runs as it is and nothing is put back after it.
        if let before, before.leadership?.serving != true { return body() }
        guard hold() == nil else { return nil }
        if marked, marks(step, localOnly: before?.leadership?.scope.isLocalOnly == true) {
            // A mark that cannot be written leaves the step as it was.
            let startedAt = Date().timeIntervalSince1970
            _ = try? store.updateRecord { $0.markRestartingStop(step, startedAt: startedAt) }
        }
        let counted = before.map { $0.stopsAsked ?? 0 }
        defer {
            // When this write fails the mark stays, and the next run of the service puts the start back.
            _ = try? store.updateRecord { record in
                record.clearRestartingStop(step)
                guard counted == nil || (record.stopsAsked ?? 0) == counted else { return }
                record.leadership?.serving = true
                record.stopDrain = nil
            }
        }
        return body()
    }

    /// What the next run of the cluster service makes of the marks it finds: the start a step's stop cleared is put
    /// back, as the step's own end would have. Only for a recent mark, while the start is still cleared, no stop a
    /// person asked for was counted since, and this Mac still leads (`leads`: the steps run on the control leader).
    /// Every mark is dropped. The step resumed and its mark's age, or nil when nothing was put back.
    func resume(now: Double, leads: (ClusterSetupRecord) -> Bool) -> (step: Step?, secondsAgo: Double)? {
        var resumed: (step: Step?, secondsAgo: Double)?
        _ = try? store.updateRecord { record in
            let found = record.restartingStopMarks
            record.dropRestartingStopMarks()
            let localOnly = record.leadership?.scope.isLocalOnly == true
            guard let mark = found.first(where: {
                marks($0.step, localOnly: localOnly) && (0...Self.resumeSeconds).contains(now - $0.startedAt)
                    && (record.stopsAsked ?? 0) == $0.stopsAsked
            }), leads(record), record.leadership?.serving == false else { return }
            record.leadership?.serving = true
            record.stopDrain = nil
            resumed = (mark.step, now - mark.startedAt)
        }
        return resumed
    }

    /// A person stopped this Mac's pair while it was down, which counts no stop: no step is resumed.
    func forget() {
        guard let record = try? store.readRecord(), !record.restartingStopMarks.isEmpty else { return }
        _ = try? store.updateRecord { $0.dropRestartingStopMarks() }
    }

    /// The line for the service log once `resume` put a start back.
    static func resumedLine(_ step: Step?, secondsAgo: Double) -> String {
        let ended: String
        switch step {
        case .updateReplan?:
            ended = "the previous run of this Mac's cluster service was ended while it set the cluster up again after an update"
        case .memoryReplan?:
            ended = "the previous run of this Mac's cluster service was ended while it planned the model again for the Macs' memory"
        case .approvalChange?:
            ended = "the previous run of this Mac's cluster service was ended while it changed the pair's cluster approval"
        case .registration?:
            ended = "the pair's registration with the coordinator was ended"
        case nil:
            ended = "a step that stops the pair only to start it again was ended"
        }
        return ended + " (\(Int(secondsAgo)) s ago), after it stopped the pair: the pair's start is put back"
            + (step == .updateReplan ? ", so it is set up again once both Macs run one build" : "")
    }

    /// Whether `step` marks the record and is resumed: the re-plan after an update by its pair's switch
    /// (`ClusterLocalPairUpdate` for a local-only pair, `ClusterUpdateReplanGuard` for another), every other step always.
    private func marks(_ step: Step?, localOnly: Bool) -> Bool {
        step != .updateReplan || (localOnly ? localUpdateRestart : updateReplanGuard)
    }
}

extension ClusterSetupRecord {
    /// The marks of steps under way: the re-plan after an update's, then another step's.
    var restartingStopMarks: [ClusterRestartingStop.Mark] {
        [updateReplan.map { .init(step: .updateReplan, stopsAsked: $0.stopsAsked, startedAt: $0.startedAt) },
         restartingStop.map { .init(step: .init(rawValue: $0.step), stopsAsked: $0.stopsAsked, startedAt: $0.startedAt) }]
            .compactMap { $0 }
    }

    /// Marks `step` as under way from `startedAt`, with the stops counted now.
    mutating func markRestartingStop(_ step: ClusterRestartingStop.Step, startedAt: Double) {
        let counted = stopsAsked ?? 0
        if step == .updateReplan {
            updateReplan = .init(stopsAsked: counted, startedAt: startedAt)
        } else {
            restartingStop = .init(step: step.rawValue, stopsAsked: counted, startedAt: startedAt)
        }
    }

    mutating func clearRestartingStop(_ step: ClusterRestartingStop.Step) {
        if step == .updateReplan { updateReplan = nil } else { restartingStop = nil }
    }

    mutating func dropRestartingStopMarks() {
        updateReplan = nil
        restartingStop = nil
    }
}
