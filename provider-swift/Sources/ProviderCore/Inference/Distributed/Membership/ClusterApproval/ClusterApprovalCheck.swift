import Foundation

/// Why a pair that was registered with the coordinator serves on the leader's local API instead.
public enum ClusterApprovalFallback: String, Codable, Equatable, Sendable {
    /// No HTTP answer for the absence grace (`ClusterService.soloGraceSeconds`, the grace before a Mac serves alone).
    case unreachable
    /// The coordinator answers (404, or a list without the saved approval) and serves no other matching entry.
    case withdrawn
    /// The coordinator-paired parts ended `ClusterControlSoloAdmission.maximumQuickEnds` times in a row right after
    /// starting with the approval (the rule for a solo server that keeps ending). The approval itself is not taken
    /// again; a later matching one is.
    case failing

    /// The one line for the screen, the log and the status.
    func line(_ approval: ClusterRuntimeApproval, grace: Double) -> String {
        switch self {
        case .unreachable:
            return "The coordinator has not answered for " + (grace >= 60 ? "\(Int(grace / 60)) minutes" : "\(Int(grace)) s")
                + ": the pair serves on the leader's local API until it answers again, then it is offered again with approval \(approval.id)"
        case .withdrawn:
            return "The coordinator no longer lists cluster approval \(approval.id): the pair serves on the leader's local API "
                + "until it lists a matching one again"
        case .failing:
            return "The coordinator-paired parts ended \(ClusterControlSoloAdmission.maximumQuickEnds) times in a row right after "
                + "starting with cluster approval \(approval.id): the pair serves on the leader's local API until the "
                + "coordinator lists a later one"
        }
    }
}

/// The control leader's check of the pair's cluster approval (`ClusterService.checkApproval`): whether to ask the
/// coordinator, and what to change after it answered, from the saved setup, the answer and how the members' parts
/// ended. `ClusterApprovalSync` makes the change on both Macs. A pair approval an operator saved by hand is never
/// changed here.
enum ClusterApprovalCheck {
    /// Whether the control leader asks its coordinator at this check. A cluster that serves locally only never does.
    /// Otherwise the first check of a service run asks, and every check while the two Macs' saved approvals differ;
    /// after it, only a serving pair that is offered, or that serves locally with its approval set aside, asks again: no
    /// other pair asks more than once per run.
    static func asks(first: Bool, serving: Bool, scope: ClusterServingScope, offered: Bool, setAside: Bool,
                     macsDiffer: Bool = false) -> Bool {
        guard !scope.isLocalOnly else { return false }
        return first || macsDiffer || (serving && (offered || setAside))
    }

    /// Whether the other Mac's saved cluster approval (`peerApprovalID`, from its status; nil: it did not answer) is not
    /// this Mac's. A pair approval saved by hand on this Mac is the operator's and never compared.
    static func macsDiffer(_ saved: ClusterConfigurationStore.Saved, peerApprovalID: String??) -> Bool {
        guard saved.configuration.nativeMember?.approval == nil, let peer = peerApprovalID else { return false }
        return peer != saved.configuration.nativeMember?.clusterApproval?.id
    }

    /// The no-answer clock the leader keeps between checks.
    struct Watch: Equatable, Sendable {
        /// Control-clock seconds of the first check in a row that got no answer; nil once the coordinator answered.
        var unreachableSince: Double?
        init() {}
    }

    enum Step: Equatable, Sendable {
        /// Nothing to write.
        case keep
        /// Save this approval on both Macs (`ClusterApprovalSync.run`): the first one, a later one, or one listed again
        /// for a pair that serves locally.
        case save(ClusterRuntimeApproval)
        /// Both Macs save their setups without this approval (`ClusterApprovalSync.serveLocally`); the leader keeps it
        /// aside (`ClusterSetupRecord.approvalSetAside`) and checks every minute until it can offer the pair again.
        case serveLocally(ClusterRuntimeApproval, ClusterApprovalFallback)
        /// The two Macs' saved approvals differ: the other Mac is given this Mac's (when it is offered now) or none
        /// (`ClusterApprovalSync.converge`).
        case converge(ClusterRuntimeApproval?)
    }

    /// The step for the leader's saved setup and the coordinator's answer. `setAside` is the approval kept aside while
    /// the pair serves locally; `memberQuickEnds` the larger of both Macs' counts of coordinator-paired parts that
    /// ended in a row right after starting. `clock` and `grace` are control-clock seconds
    /// (`ClusterService.monotonicSeconds`); `now` is wall-clock seconds. `facts` runs only when an entry must be chosen.
    static func step(saved: ClusterConfigurationStore.Saved, fetched: ClusterApprovalFetch.Outcome,
                     setAside: ClusterSetupRecord.ApprovalSetAside?, scope: ClusterServingScope, memberQuickEnds: Int,
                     peerApprovalID: String??, watch: inout Watch, clock: Double, grace: Double, now: Double,
                     facts: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts = ClusterApprovalAttachment.installedFacts) -> Step {
        let configuration = saved.configuration
        // Both Macs carry the same approval, or neither does: a difference (a lost reply, a failed give-back) is
        // settled first, on this Mac's approval while it is offered, else on none.
        if macsDiffer(saved, peerApprovalID: peerApprovalID) {
            let offered = configuration.nativeMember.flatMap { member in
                ClusterApprovalLifetime.offers(member, scope: scope, now: now) ? member.clusterApproval : nil
            }
            return .converge(offered)
        }
        // A cluster that serves locally only is never offered, and changes nothing here.
        guard !scope.isLocalOnly else {
            watch.unreachableSince = nil
            return .keep
        }
        let answered: Bool
        if case .unreachable = fetched { answered = false } else { answered = true }
        // Only a pair offered now with a cluster approval falls back; a hand-saved pair approval is the operator's.
        if let member = configuration.nativeMember, let offered = member.clusterApproval,
           ClusterApprovalLifetime.offers(member, scope: scope, now: now) {
            if memberQuickEnds >= ClusterControlSoloAdmission.maximumQuickEnds { return .serveLocally(offered, .failing) }
            guard answered else {
                let since = watch.unreachableSince ?? clock
                watch.unreachableSince = since
                return clock - since >= grace ? .serveLocally(offered, .unreachable) : .keep
            }
            watch.unreachableSince = nil
            switch ClusterApprovalSync.decision(saved: saved, fetched: fetched, now: now, facts: facts) {
            case .save(let approval): return .save(approval)
            case .withdrawn: return .serveLocally(offered, .withdrawn)
            case .keep, .remove: return .keep
            }
        }
        watch.unreachableSince = nil
        guard answered else { return .keep }
        // Not offered now: the first matching entry, or one listed again for a pair that serves locally. An approval its
        // parts kept failing with is not taken again.
        var answer = fetched
        if let setAside, setAside.reason == .failing, case .approvals(let approvals) = fetched {
            answer = .approvals(approvals.filter { $0.id != setAside.approval.id })
        }
        if case .save(let approval) = ClusterApprovalSync.decision(saved: saved, fetched: answer, now: now, facts: facts) {
            return .save(approval)
        }
        return .keep
    }

    /// A coordinator-paired part's quick ends in a row after one more end that ran `ranSeconds`: one more for a quick
    /// end (`ClusterControlSoloAdmission.quickEnds`, the solo server's rule), none after a part that ran long enough,
    /// and none after an end because the coordinator could not be reached (`lastError`), which the no-answer grace
    /// handles instead.
    static func memberQuickEnds(after count: Int, ranSeconds: Double, lastError: String?) -> Int {
        if lastError?.contains(unreachableMemberEnd) == true { return 0 }
        return ClusterControlSoloAdmission.quickEnds(after: count, ranSeconds: ranSeconds)
    }

    /// How a member's error line starts when its registration wait never reached the coordinator.
    static let unreachableMemberEnd = String(ClusterMemberControlError.coordinatorUnreachable.rawValue.prefix(40))
}
