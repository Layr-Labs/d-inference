import Foundation

/// How far a step is, as the rail shows it.
public enum ClusterSetupStepStatus: Equatable, Sendable {
    /// Nothing more to do here.
    case done
    /// Something can be done here now.
    case todo
    /// Something must change before this step can be done; the step says what.
    case blocked
    /// The step waits for something outside this Mac: a cable, the other Mac.
    case waiting
}

/// Which steps are done, from the snapshot and what the wizard has observed
/// since. A pure reading: nothing here starts anything.
extension ClusterSetupState {
    var local: ClusterSetupReport? { snapshot?.local }
    var pair: ClusterSetupPair? { snapshot?.pair }
    var record: ClusterSetupRecord { snapshot?.record ?? .init() }
    var savedSetup: ClusterSetupSetupSummary? { local?.saved.setup }

    /// The other Mac's report, when it was reached.
    public var peerReport: ClusterSetupReport? {
        if case .reached(let report, _, _) = peer { return report }
        return nil
    }

    /// This Mac leads: its saved setup says so, or the plan it adopted does.
    var leads: Bool { savedSetup?.isLeader ?? pair?.leads ?? (pair?.source == .description) }

    /// The code both screens should show: the pinned key's on the leader, its own key's elsewhere.
    var pairingCode: ClusterSetupPairingCode? { local?.pairingCode }

    var pairingConfirmed: Bool {
        if linkPaired { return true }
        guard let code = pairingCode else { return false }
        return record.confirmed(code: code.code) != nil
    }

    /// This Mac pinned another Mac's key in the ceremony over the link (S17).
    var linkPaired: Bool { local?.linkPairings?.pairings.isEmpty == false }

    /// The other Mac has saved the setup this Mac's plan gave it.
    var peerHasItsSetup: Bool? {
        guard let saved = savedSetup else { return false }
        guard let report = peerReport else { return nil }
        guard let theirs = report.saved.setup else { return false }
        return theirs.clusterID == saved.clusterID && theirs.planSHA256 == saved.planSHA256
            && theirs.artifactSHA256 == saved.artifactSHA256 && theirs.memberID == saved.peerID
    }

    var checkRunning: Bool { if case .running = check { return true }; return false }

    public func status(of step: ClusterSetupStep) -> ClusterSetupStepStatus {
        guard let local else { return .waiting }
        switch step {
        case .thisMac:
            if local.link.rdmaDisabled || local.link.rdmaUnavailable || !local.mac.osSupportsRDMA
                || local.memoryGuard.decision == .refused { return .blocked }
            return .done
        case .cable:
            if local.link.ready { return .done }
            if local.link.state == ClusterLinkReadinessState.noActivePort.rawValue { return .waiting }
            if local.link.clusterConnection?.generation == .thunderbolt4 { return .blocked }
            if local.link.rdmaDisabled || local.link.rdmaUnavailable { return .blocked }
            return .todo
        case .pair:
            if pairingConfirmed { return .done }
            guard pair != nil else { return snapshot?.pairError == nil ? .waiting : .blocked }
            if case .failed = peer { return .blocked }
            return .todo
        case .model:
            guard let pair else { return .waiting }
            if let saved = savedSetup, saved.clusterID == pair.clusterID {
                if !saved.isLeader {
                    // A follower is done once saved, unless a newer setup waits in its inbox.
                    if let inbox = local.inbox, inbox.configurationSHA256 != saved.configurationSHA256 { return .todo }
                    return .done
                }
                switch peerHasItsSetup {
                case true?: return .done
                case false?: return .waiting
                case nil: return record.sentSetup(clusterID: saved.clusterID, memberID: saved.peerID) != nil ? .done : .waiting
                }
            }
            if local.inbox != nil { return .todo }
            return pair.canReachPeer ? .todo : .waiting
        case .check:
            guard let saved = savedSetup else { return .waiting }
            guard saved.isLeader else { return .done }
            if record.checkPassed(configurationSHA256: saved.configurationSHA256) != nil { return .done }
            if case .failed = check { return .blocked }
            return .todo
        case .serve:
            // The check's own short session is not serving, and a session is serving once its ranks are ready.
            if case .running = session, !checkRunning { return live?.ready == true ? .done : .todo }
            return savedSetup == nil ? .waiting : .todo
        }
    }

    /// Where a new run of the wizard opens: the first step that is not done.
    public var firstUnfinished: ClusterSetupStep {
        ClusterSetupStep.allCases.first { status(of: $0) != .done } ?? .serve
    }
}
