import Foundation

/// Operator rollback (`darkbloom update --rollback`): replace the installed
/// release with the retained, verified predecessor and quarantine it. It runs
/// the watchdog's journaled rollback (`UpdateSession.rollback`) under the
/// caller's cross-process update lease, so it shares its verification,
/// power-loss replay and single-slot quarantine. A promoted release is rolled
/// back as well as a pending candidate (`UpdateRecoveryState.rollbackSource`).
extension SelfUpdater {
    public struct RollbackPlan: Sendable, Equatable {
        /// The installed release that is replaced and quarantined.
        public let from: String
        /// `from` has not passed its stabilization window yet.
        public let fromIsCandidate: Bool
        /// The retained predecessor that is restored.
        public let to: String
        /// The install generation the predecessor was installed at.
        public let toGeneration: UInt64
        /// The install generation the rollback records.
        public let generation: UInt64
    }

    /// Why no rollback was carried out. Every refusal leaves the install unchanged.
    public enum RollbackRefusal: Error, Equatable, CustomStringConvertible {
        case busy(String)
        case noPredecessor
        case nothingToRollBack(installed: String)
        case predecessorNotOlder(installed: String, predecessor: String)
        case installNotRecorded(String)
        case predecessorUnusable(String)
        case changedSinceConfirmation(installed: String, predecessor: String)

        public var description: String {
            switch self {
            case .busy(let reason):
                return "Another update or recovery operation is running (\(reason)). Nothing was changed; retry when it finishes."
            case .noPredecessor:
                return "This Mac keeps no earlier release to roll back to. One is kept only when the updater installs a "
                    + "release over a signed one. Nothing was changed."
            case .nothingToRollBack(let installed):
                return "v\(installed) is installed and is already the release kept for rollback; this Mac keeps one "
                    + "earlier release, so there is nothing older to roll back to. Nothing was changed."
            case .predecessorNotOlder(let installed, let predecessor):
                return "The release kept for rollback, v\(predecessor), is not older than the installed v\(installed). "
                    + "Nothing was changed."
            case .installNotRecorded(let detail):
                return "The installed \(BuildEnvironment.current.appBundleName) is not the release the updater recorded "
                    + "(v\(detail)); it was changed outside the updater. Nothing was changed; reinstall with install.sh."
            case .predecessorUnusable(let reason):
                return "The release kept for rollback cannot be restored: \(reason). Nothing was changed."
            case .changedSinceConfirmation(let installed, let predecessor):
                return "The installed release changed after the rollback was confirmed (now v\(installed), "
                    + "kept for rollback v\(predecessor)). Nothing was changed; run the command again."
            }
        }
    }

    /// Plans a rollback under a lease of its own, released before returning,
    /// so the caller can ask for confirmation without holding it.
    public func rollbackPlan() throws -> RollbackPlan {
        let session: UpdateSession
        do {
            session = try beginUpdateSession(operation: "operator-rollback-plan", timeout: 0)
        } catch UpdateError.lockBusy(let reason, _) {
            throw RollbackRefusal.busy(reason)
        }
        defer { session.release() }
        try session.recover(now: now())
        return try rollbackPlan(session: session)
    }

    /// Plans a rollback from the recovery state `session` reads: the installed
    /// release must be the recorded one, and the predecessor must verify.
    public func rollbackPlan(session: UpdateSession) throws -> RollbackPlan {
        let state = try session.readState()
        guard let predecessor = state.predecessor else { throw RollbackRefusal.noPredecessor }
        guard let installed = state.rollbackSource else {
            throw RollbackRefusal.nothingToRollBack(
                installed: state.current?.version ?? predecessor.release.version)
        }
        guard Self.isNewer(latest: installed.version, current: predecessor.release.version) else {
            throw RollbackRefusal.predecessorNotOlder(
                installed: installed.version, predecessor: predecessor.release.version)
        }
        let liveIsRecorded: Bool
        do {
            liveIsRecorded = try session.store.liveMatches(installed)
        } catch {
            throw RollbackRefusal.installNotRecorded("\(installed.version): \(error)")
        }
        guard liveIsRecorded else { throw RollbackRefusal.installNotRecorded(installed.version) }
        do {
            try session.store.verifyPredecessor(predecessor)
        } catch {
            throw RollbackRefusal.predecessorUnusable("\(error)")
        }
        let (generation, overflow) = state.installGeneration.addingReportingOverflow(1)
        guard !overflow else { throw RollbackRefusal.predecessorUnusable("install generation overflow") }
        return RollbackPlan(
            from: installed.version,
            fromIsCandidate: state.candidate != nil,
            to: predecessor.release.version,
            toGeneration: predecessor.release.installGeneration,
            generation: generation)
    }

    /// Under `session`: `plan`, confirmed without the lease, still holds. A
    /// promotion since then is the same rollback; any other install or
    /// rollback is not (`changedSinceConfirmation`).
    public func confirmRollbackPlan(_ plan: RollbackPlan, session: UpdateSession) throws {
        try session.recover(now: now())
        let current = try rollbackPlan(session: session)
        guard current.from == plan.from, current.to == plan.to, current.generation == plan.generation else {
            throw RollbackRefusal.changedSinceConfirmation(installed: current.from, predecessor: current.to)
        }
    }

    /// Carries out a confirmed `plan` while the caller holds `session` (for a
    /// running provider, the lease its drain took). Returns the restored version.
    @discardableResult
    public func rollBackToPredecessor(session: UpdateSession, plan: RollbackPlan) throws -> String {
        try confirmRollbackPlan(plan, session: session)
        let reason = "rolled back by the operator to v\(plan.to) (\(BuildEnvironment.current.cliName) update --rollback)"
        do {
            return try session.rollback(now: now(), reason: reason)
        } catch {
            // Finish a rollback that failed after its journal was written while
            // this lease is still held, so no restart runs an unfinished layout.
            try? session.recover(now: now())
            if let state = try? session.readState(), state.rollbackSource == nil,
               state.current?.version == plan.to, state.quarantine?.version == plan.from {
                return plan.to
            }
            throw error
        }
    }
}
