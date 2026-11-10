import Foundation

/// Candidate promotion and rollback on a `darkbloom cluster` Mac: what the watchdog does for a single Mac's provider
/// (`WatchdogRecoveryService`), done by the cluster service supervisor for the cluster service it runs. A release the
/// pair installed (`ClusterPairUpdateCycle`, or `darkbloom update`) stays a candidate until its cluster service has
/// beaten with the new version, continuously, for the stabilization window; the third start that ends before that
/// restores the verified predecessor and quarantines the release (`UpdateRecoveryState.rollbackThreshold`).
/// Every transition holds the cross-process update lease, as the watchdog's do. Before a start is noted or an end
/// counted, the record is reconciled with the installed app (`reconcile`), so an install outside the updater never
/// leaves a release pending that is not installed, or a rollback copy recorded as another release than it holds.
///
/// The supervisor restarts into a release by replacing itself (`execv`), so a release whose binary cannot start
/// at all would leave no supervisor to count its failed starts. The start check (`startCheckFailure`) runs that
/// binary first; one that fails it is rolled back at once (`recordFailedStartCheck`) and never restarted into.
public struct ClusterCandidateRecovery: Sendable {
    public enum Launch: Equatable, Sendable {
        case notCandidate
        /// The service about to start runs candidate `version`; `failedStarts` of its earlier starts failed.
        case candidate(version: String, failedStarts: Int)
    }

    public enum Health: Equatable, Sendable {
        case noCandidate
        case stabilizing
        case promoted(version: String)
    }

    public enum Failure: Equatable, Sendable {
        /// No candidate attempt was pending: an ordinary end.
        case notCandidate
        case counted(version: String, failures: Int)
        /// The verified predecessor is installed again; the supervisor starts again from it.
        case rolledBack(from: String, to: String)
        case rollbackRefused(version: String, reason: String)
    }

    private let updater: SelfUpdater
    private let stabilizationSeconds: Double

    public init(updater: SelfUpdater, stabilizationSeconds: Double = UpdateRecoveryState.defaultStabilizationSeconds) {
        self.updater = updater
        self.stabilizationSeconds = stabilizationSeconds
    }

    /// Before the supervisor starts its cluster service: the record is reconciled with the installed app (`reconcile`;
    /// `log` gets its one line), then a pending candidate gets a launch attempt (the one the restart prepared, or a new
    /// one after a failed start), so an end before promotion is counted exactly once.
    public func noteLaunch(now: Double, log: (String) -> Void = { _ in }) -> Launch {
        transition(operation: "cluster-candidate-launch", reconcilingAt: now, log: log) { state in
            Self.issueLaunch(&state, now: now)
            guard let current = state.candidate, current.pendingAttemptID != nil else { return Launch.notCandidate }
            return Launch.candidate(version: current.release.version, failedStarts: current.failureCount)
        } ?? .notCandidate
    }

    /// While the service runs: `healthy` is a fresh heartbeat of the candidate version from the running service. A
    /// lease another update holds (the pair's next cycle) leaves the candidate as it was.
    public func observe(healthy: Bool, processStartedAt: Double?, now: Double) -> Health {
        transition(operation: "cluster-candidate-health") { state in
            guard let candidate = state.candidate else { return Health.noCandidate }
            let promoted = state.observeCandidateHealth(healthySignal: healthy, processStartedAt: processStartedAt,
                                                        now: now, stabilizationSeconds: stabilizationSeconds)
            return promoted ? Health.promoted(version: candidate.release.version) : Health.stabilizing
        } ?? .stabilizing
    }

    /// Whether an end of the candidate's cluster service that its supervisor did not ask for (`end`) is a failed start:
    /// a crash (a signal), an exit with an error, and a stop the supervisor's liveness guard asked for (`recycled`: the
    /// service stopped beating) are, as a crash and a start that sends no heartbeat are on a single Mac. A clean stop
    /// (exit 0) is not: the service exits 0 only once asked to stop (SIGTERM or SIGINT), as when `darkbloom cluster`
    /// replaces a service started from a terminal (`ClusterService.stopDetached`), or on a `kill`.
    public static func endIsFailedStart(_ end: ClusterMemberRunEnd, recycled: Bool) -> Bool {
        recycled || end != .failure(exitCode: 0)
    }

    /// After the service ended without being asked to. Reconciled first (`reconcile`): an end of a release that is not
    /// the pending one is never counted toward rolling the pending one back.
    public func recordFailedStart(now: Double, log: (String) -> Void = { _ in }) -> Failure {
        guard let session = try? updater.beginUpdateSession(operation: "cluster-candidate-failure", timeout: 1) else { return .notCandidate }
        defer { session.release() }
        do {
            try session.recover(now: now)
            try reconcile(session, now: now, log: log)
            var state = try session.readState()
            guard let failures = state.recordPendingAttemptFailure(now: now), let candidate = state.candidate else { return .notCandidate }
            try session.writeState(state)
            let version = candidate.release.version
            guard failures >= UpdateRecoveryState.rollbackThreshold else { return .counted(version: version, failures: failures) }
            return rollBack(session, state: state, version: version,
                            reason: "automatic rollback after \(failures) failed starts of the cluster service", now: now)
        } catch {
            return .notCandidate
        }
    }

    /// How long the binary the supervisor restarts into may take to answer its start check.
    public static let startCheckTimeoutSeconds: Double = 30

    /// Before the supervisor replaces itself with the installed binary at `executable`, that binary runs once as the
    /// supervisor's child with `--version`: it is loaded as the restart would load it (the dynamic loader and the
    /// frameworks it links, its code signature, the argument parser) while the supervisor, which alone can still roll
    /// the release back, keeps running. It passes when it exits 0 within `timeout` and prints exactly `version`.
    /// Returns why it did not; nil when it passed.
    public static func startCheckFailure(executable: String, version: String,
                                         timeout: Double = startCheckTimeoutSeconds) -> String? {
        let output: Data
        do {
            output = try BoundedProcess.runCapturingStandardOutput(URL(fileURLWithPath: executable),
                                                                   arguments: ["--version"], timeout: timeout)
        } catch BoundedProcess.Failure.exited(let status, _) {
            return "`--version` exited \(status)"
        } catch BoundedProcess.Failure.signalled(let signal) {
            return "`--version` ended on signal \(signal)"
        } catch BoundedProcess.Failure.timedOut, BoundedProcess.Failure.wouldNotTerminate {
            return "`--version` did not finish within \(Int(timeout)) s"
        } catch {
            return "it could not be run: \(error.localizedDescription)"
        }
        let reported = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported != version else { return nil }
        // Only a version is repeated: whatever else a wrong binary prints stays out of the log.
        return SemanticVersion(reported) == nil ? "it printed no version" : "it reports v\(reported)"
    }

    /// Before the supervisor restarts into candidate `version`, its binary failed the start check (`reason`). After
    /// that restart no supervisor would be left to count its failed starts, so this one is conclusive: it counts as a
    /// failed start, and the verified predecessor is restored and the release quarantined at once.
    public func recordFailedStartCheck(version: String, reason: String, now: Double) -> Failure {
        guard let session = try? updater.beginUpdateSession(operation: "cluster-candidate-start-check", timeout: 1) else { return .notCandidate }
        defer { session.release() }
        do {
            try session.recover(now: now)
            var state = try session.readState()
            guard state.candidate?.release.version == version else { return .notCandidate }
            Self.issueLaunch(&state, now: now)
            state.recordPendingAttemptFailure(now: now)
            try session.writeState(state)
            return rollBack(session, state: state, version: version,
                            reason: "automatic rollback: v\(version) failed its start check before the restart (\(reason))", now: now)
        } catch {
            return .notCandidate
        }
    }

    /// A pending candidate's launch attempt: the one the restart prepared, or a new one after a failed start.
    private static func issueLaunch(_ state: inout UpdateRecoveryState, now: Double) {
        guard let candidate = state.candidate, candidate.pendingAttemptID == nil else { return }
        if candidate.launchIntent == nil { _ = state.prepareLaunchIntent(now: now, baseline: nil) }
        _ = state.markLaunchIssued(now: now)
    }

    /// Restores the verified predecessor of candidate `version`; a refused rollback keeps it and backs its retry off.
    private func rollBack(_ session: SelfUpdater.UpdateSession, state: UpdateRecoveryState, version: String,
                          reason: String, now: Double) -> Failure {
        do {
            return .rolledBack(from: version, to: try session.rollback(now: now, reason: reason))
        } catch {
            var state = state
            state.deferRetryAfterRollbackFailure(now: now, reason: "\(error)")
            try? session.writeState(state)
            return .rollbackRefused(version: version, reason: "\(error)")
        }
    }

    /// Under the session's lease, before anything acts on the pending release: the record must name the installed app
    /// (`UpdateRecoveryStore.reconcileWithInstalledApp`, as the release this process runs when the app names none). An
    /// install outside the updater left it naming releases that are not installed, and acting on them would restart
    /// into, count failed starts of and roll back a release that does not run. An installed app that cannot be read
    /// changes nothing, so a damaged release is still rolled back. A record that cannot be checked throws: nothing is
    /// counted or rolled back then.
    private func reconcile(_ session: SelfUpdater.UpdateSession, now: Double, log: (String) -> Void) throws {
        do {
            if let change = try session.reconcileWithInstalledApp(runningVersion: updater.currentVersion, now: now) {
                log(Self.line(change))
            }
        } catch {
            log("the update record could not be checked against the installed app (\(error)); no start is counted toward a rollback")
            throw error
        }
    }

    /// One plain line for the supervisor's log.
    static func line(_ change: UpdateRecoveryReconciliation) -> String {
        switch change {
        case .installedOutsideTheUpdater(let installed, let recorded, let pending, let removedCopy):
            let said = (recorded.map { "v\($0)" } ?? "no release") + (pending.map { " with v\($0) pending" } ?? "")
            let changes = ["it now records v\(installed)"] + (pending.map { ["v\($0) is no longer pending"] } ?? [])
                + (removedCopy.map { ["the rollback copy (recorded as v\($0)) is removed"] } ?? [])
            return "v\(installed) is installed, but the update record said \(said) (installed outside the updater): "
                + changes.dropLast().joined(separator: ", ") + (changes.count > 1 ? " and " : "") + (changes.last ?? "")
                + "; nothing is rolled back until an update keeps a copy of v\(installed)"
        case .rollbackCopyRelabelled(let recordedAs, let signed):
            return "the rollback copy recorded as v\(recordedAs) is a v\(signed) app: it is now recorded as v\(signed) and "
                + "kept for rollback"
        case .unverifiedRollbackCopyRemoved(let recordedAs):
            return "the rollback copy recorded as v\(recordedAs) could not be verified as the release its app is signed as, "
                + "so it is removed; nothing is rolled back until an update keeps a copy of the installed release"
        }
    }

    private func transition<Value>(operation: String, reconcilingAt now: Double? = nil, log: (String) -> Void = { _ in },
                                   _ body: (inout UpdateRecoveryState) -> Value) -> Value? {
        guard let session = try? updater.beginUpdateSession(operation: operation, timeout: 1) else { return nil }
        defer { session.release() }
        do {
            try session.recover()
            if let now { try reconcile(session, now: now, log: log) }
            var state = try session.readState()
            let before = state
            let value = body(&state)
            if state != before { try session.writeState(state) }
            return value
        } catch {
            return nil
        }
    }
}
