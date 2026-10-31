import Foundation

/// Candidate promotion and rollback on a `darkbloom cluster` Mac: what the watchdog does for a single Mac's provider
/// (`WatchdogRecoveryService`), done by the cluster service supervisor for the cluster service it runs. A release the
/// pair installed (`ClusterPairUpdateCycle`, or `darkbloom update`) stays a candidate until its cluster service has
/// beaten with the new version, continuously, for the stabilization window; the third start that ends before that
/// restores the verified predecessor and quarantines the release (`UpdateRecoveryState.rollbackThreshold`).
/// Every transition holds the cross-process update lease, as the watchdog's do.
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

    /// Before the supervisor starts its cluster service: a pending candidate gets a launch attempt (the one the
    /// restart prepared, or a new one after a failed start), so an end before promotion is counted exactly once.
    public func noteLaunch(now: Double) -> Launch {
        transition(operation: "cluster-candidate-launch") { state in
            guard let candidate = state.candidate else { return Launch.notCandidate }
            if candidate.pendingAttemptID == nil {
                if candidate.launchIntent == nil { _ = state.prepareLaunchIntent(now: now, baseline: nil) }
                _ = state.markLaunchIssued(now: now)
            }
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

    /// After the service ended without being asked to.
    public func recordFailedStart(now: Double) -> Failure {
        guard let session = try? updater.beginUpdateSession(operation: "cluster-candidate-failure", timeout: 1) else { return .notCandidate }
        defer { session.release() }
        do {
            try session.recover(now: now)
            var state = try session.readState()
            guard let failures = state.recordPendingAttemptFailure(now: now), let candidate = state.candidate else { return .notCandidate }
            try session.writeState(state)
            let version = candidate.release.version
            guard failures >= UpdateRecoveryState.rollbackThreshold else { return .counted(version: version, failures: failures) }
            do {
                let restored = try session.rollback(now: now, reason: "automatic rollback after \(failures) failed starts of the cluster service")
                return .rolledBack(from: version, to: restored)
            } catch {
                state.deferRetryAfterRollbackFailure(now: now, reason: "\(error)")
                try? session.writeState(state)
                return .rollbackRefused(version: version, reason: "\(error)")
            }
        } catch {
            return .notCandidate
        }
    }

    private func transition<Value>(operation: String, _ body: (inout UpdateRecoveryState) -> Value) -> Value? {
        guard let session = try? updater.beginUpdateSession(operation: operation, timeout: 1) else { return nil }
        defer { session.release() }
        do {
            try session.recover()
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
