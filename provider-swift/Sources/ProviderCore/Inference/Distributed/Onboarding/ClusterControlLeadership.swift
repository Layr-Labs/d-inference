import Foundation

// The cluster's control leader, derived (owner spec revision 2026-10-12).
//
// The Mac where `darkbloom cluster` first ran only drives the onboarding
// screens. Afterwards the control leader (the member that owns the session,
// syncs setups, starts and stops the members and answers `darkbloom cluster`
// for every member) is DERIVED from detected facts, never from a host role:
//
//   1. a plan is adopted and its rank 0 is present: rank 0 leads. Requests
//      enter there (the serving API runs beside rank 0's driver) and the
//      coordinator's registration v3 treats the plan's first member as the
//      cluster's head, so control and registration sit on one member;
//   2. otherwise the most capable member present leads: one that can hold
//      the chosen model alone first, then the most memory, then the most GPU
//      cores; ties go to the lowest member identity (from the member's Secure
//      Enclave key pin, stable across restarts).
//
// Every leadership is a CLAIM with a term. A claim supersedes another when its
// term is higher, or, at an equal term, when its leader's identity is lower:
// one total order, so two claims never tie. Claims travel only inside the
// pairing-keyed link control channel (S07), never as a file another Mac can
// write. A member follows the highest claim it knows and refuses anything
// older, telling the sender the claim that supersedes it; a leader that hears
// of a superseding claim steps down at once. The leader renews its lease with
// each member at the rank lease's own cadence; a member that hears nothing
// for the lease's time-to-live re-derives among the members the last claim
// named, and the member that derivation picks claims the next term.
//
// A leader acts on the cluster only once every member of the plan confirmed
// its claim in this process's lifetime (a restarted leader whose claim was
// superseded while it was away never starts a part). A leader left alone after
// the lease's time-to-live serves the model alone when the planner said it
// holds it alone ("degraded: serving on this Mac alone"), and otherwise states
// that it cannot serve and runs nothing. When the missing member answers
// again, the leader re-derives with it present and hands leadership over when
// derivation picks it: the pair re-forms with no question asked.
//
// Pure (Foundation only): times are seconds on any monotonic clock, so checks
// drive 2-4 synthetic members through failover, return and split brain.

/// One member's detected facts, as the leader is derived from them.
public struct ClusterControlMember: Codable, Sendable, Equatable {
    /// `mac-` + the first 12 hex digits of the member's Secure Enclave key pin.
    public var memberID: String
    /// The name it showed at pairing (chip and memory, never a host name).
    public var name: String
    public var memoryBytes: UInt64
    public var gpuCores: Int
    /// The planner's verdict for the chosen model on this member alone; nil before a model is chosen.
    public var holdsModelAlone: Bool?

    public init(memberID: String, name: String, memoryBytes: UInt64, gpuCores: Int, holdsModelAlone: Bool? = nil) {
        self.memberID = memberID; self.name = name; self.memoryBytes = memoryBytes; self.gpuCores = gpuCores
        self.holdsModelAlone = holdsModelAlone
    }
}

/// Who leads, from which term, and over which members.
public struct ClusterControlClaim: Codable, Sendable, Equatable {
    public var term: UInt64
    public var leaderID: String
    /// The members this claim leads (ascending identity), the leader among them.
    public var members: [String]
    /// Why derivation picked this leader, in words.
    public var reason: String

    public init(term: UInt64, leaderID: String, members: [String], reason: String) {
        self.term = term; self.leaderID = leaderID; self.members = Array(Set(members + [leaderID])).sorted(); self.reason = reason
    }

    /// The total order: a higher term wins; at an equal term the lower leader identity wins.
    public func supersedes(_ other: ClusterControlClaim) -> Bool {
        term != other.term ? term > other.term : leaderID < other.leaderID
    }

    public func sameLeadership(_ other: ClusterControlClaim) -> Bool { term == other.term && leaderID == other.leaderID }
}

public enum ClusterControlDerivation {
    public struct Choice: Sendable, Equatable {
        public var memberID: String
        public var reason: String
    }

    /// The leader for these members, of which `present` answer now. `rankOrder` is the adopted plan's
    /// member order (rank 0 first), nil before a plan.
    public static func derive(members: [ClusterControlMember], present: Set<String>, rankOrder: [String]?) -> Choice? {
        let candidates = members.filter { present.contains($0.memberID) }
        guard !candidates.isEmpty else { return nil }
        if let first = rankOrder?.first, present.contains(first), candidates.contains(where: { $0.memberID == first }) {
            return .init(memberID: first, reason: "rank 0 of the adopted plan: requests enter there and the coordinator registers it as the head")
        }
        let best = candidates.min { a, b in
            let aloneA = a.holdsModelAlone == true, aloneB = b.holdsModelAlone == true
            if aloneA != aloneB { return aloneA }
            if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            if a.gpuCores != b.gpuCores { return a.gpuCores > b.gpuCores }
            return a.memberID < b.memberID
        }!
        let why = best.holdsModelAlone == true ? "holds the chosen model alone" : "the most memory and GPU cores present"
        return .init(memberID: best.memberID, reason: rankOrder == nil ? why : "rank 0 is absent; of the members present, \(why)")
    }
}

/// What one Mac's cluster service does about control, from its own observations only.
public struct ClusterControlNode: Sendable, Equatable {
    /// What this Mac's service should run.
    public enum Mode: Sendable, Equatable {
        /// A member: it runs its part of the saved setup while the leader's last lease said the cluster runs.
        case following(leaderID: String)
        /// The leader, waiting for every member of the plan to confirm its claim (or for their time-to-live to pass).
        case confirming
        /// The leader with every plan member present and confirmed: the cluster runs as planned.
        case cluster
        /// The leader with no plan adopted yet: nothing to run.
        case idle
        /// The leader, alone of the plan after the others' leases expired, and the planner said it holds the model alone.
        case alone(missing: [String])
        /// The members present cannot serve the plan: a stated failure, nothing runs.
        case cannotServe(missing: [String], reason: String)
    }

    public enum LeaseAnswer: Codable, Sendable, Equatable {
        /// The claim is this Mac's own now; its facts for the leader.
        case accepted(ClusterControlMember)
        /// A superseding claim is known here: the sender must step down.
        case refused(ClusterControlClaim, ClusterControlMember)
    }

    /// Something the service must send or say.
    public enum Action: Sendable, Equatable {
        /// Renew this claim with these members (the leader, every renewal interval).
        case lease(ClusterControlClaim, to: [String])
        /// Offer leadership to a member derivation now picks; adopted here once it accepts.
        case handOver(ClusterControlClaim, to: String)
        /// This Mac took leadership after the leader's lease expired.
        case tookOver(ClusterControlClaim, from: String)
        /// A superseding claim was heard: this Mac no longer leads.
        case steppedDown(to: ClusterControlClaim)
    }

    public let localID: String
    public private(set) var claim: ClusterControlClaim
    public private(set) var members: [String: ClusterControlMember]
    public var rankOrder: [String]?
    /// On a member: whether the leader's last lease said the cluster runs.
    public private(set) var leaderRunsCluster = false
    /// The leader: when each member last accepted this claim. A member: when the leader (or its awaited successor) last renewed.
    private var heard: [String: Double] = [:]
    /// Members that confirmed the current claim since this process started.
    private var confirmed: Set<String> = []
    /// Leaders whose lease expired while this Mac waited for a successor.
    private var expired: Set<String> = []
    /// On a member: the leader it waits for (the claim's leader, or the successor derivation picked after it expired).
    private var awaited: String
    private var pendingHandOver: ClusterControlClaim?
    public let ttl: Double

    /// `claim` as persisted, or nil before the first one (term 0: derived among the known members).
    public init(localID: String, members: [ClusterControlMember], claim: ClusterControlClaim?, rankOrder: [String]?, now: Double, ttl: Double) {
        self.localID = localID
        self.members = Dictionary(members.map { ($0.memberID, $0) }, uniquingKeysWith: { _, b in b })
        self.rankOrder = rankOrder
        self.ttl = ttl
        let resolved: ClusterControlClaim
        if let claim {
            resolved = claim
        } else {
            let ids = Set(members.map(\.memberID) + [localID])
            let choice = ClusterControlDerivation.derive(members: members, present: ids, rankOrder: rankOrder)
            resolved = ClusterControlClaim(term: 0, leaderID: choice?.memberID ?? localID, members: Array(ids),
                reason: choice?.reason ?? "the only member known")
        }
        self.claim = resolved
        awaited = resolved.leaderID
        // Everyone gets one time-to-live from this start to answer before being counted absent.
        for id in resolved.members where id != localID { heard[id] = now }
    }

    public var leads: Bool { claim.leaderID == localID }

    public mutating func learn(_ member: ClusterControlMember) { members[member.memberID] = member }

    /// The members that answered within the time-to-live, this Mac among them.
    public func present(now: Double) -> Set<String> {
        var ids: Set<String> = [localID]
        for (id, at) in heard where now - at < ttl { ids.insert(id) }
        return ids
    }

    private mutating func adopt(_ newer: ClusterControlClaim, heardFrom sender: String, now: Double) -> [Action] {
        let wasLeader = leads
        claim = newer
        confirmed = []
        expired = []
        pendingHandOver = nil
        awaited = newer.leaderID
        heard[sender] = now
        if newer.leaderID != sender { heard[newer.leaderID] = now }
        return wasLeader && !leads ? [.steppedDown(to: newer)] : []
    }

    // MARK: - Leases

    /// A lease (or a hand-over) from `sender` carrying `offered`, whether the sender runs the cluster now, and its member facts.
    public mutating func receiveLease(from sender: String, offered: ClusterControlClaim, running: Bool, facts: [ClusterControlMember],
                                      now: Double) -> (answer: LeaseAnswer, actions: [Action]) {
        let own = members[localID] ?? ClusterControlMember(memberID: localID, name: localID, memoryBytes: 0, gpuCores: 0)
        // Only the claim's leader renews it; a hand-over names this Mac and comes from the leader of the claim it supersedes.
        let handOver = offered.leaderID == localID && sender == claim.leaderID && offered.supersedes(claim)
        guard offered.leaderID == sender || handOver else { return (.refused(claim, own), []) }
        if claim.supersedes(offered) { return (.refused(claim, own), []) }
        for fact in facts where fact.memberID != localID { members[fact.memberID] = fact }
        var actions = [Action]()
        if !offered.sameLeadership(claim) { actions = adopt(offered, heardFrom: sender, now: now) }
        claim = offered
        expired = []
        awaited = claim.leaderID
        heard[sender] = now
        leaderRunsCluster = !handOver && running
        if handOver {
            // The previous leader handed it over: it has seen this claim, so it confirmed it.
            confirmed.insert(sender)
            for id in claim.members where id != localID && heard[id] == nil { heard[id] = now }
        }
        return (.accepted(own), actions)
    }

    /// A member's answer to this Mac's lease or hand-over of `sent`.
    public mutating func receiveAnswer(from member: String, sent: ClusterControlClaim, answer: LeaseAnswer, now: Double) -> [Action] {
        switch answer {
        case .accepted(let facts):
            members[facts.memberID] = facts
            heard[member] = now
            if sent.leaderID == member, let pending = pendingHandOver, pending.sameLeadership(sent), leads {
                // The hand-over was accepted: the new leader leads from now on, and inherits a running cluster
                // (this Mac keeps its part running instead of stopping it until the new leader's first renewal).
                let wasRunning = mode(now: now) == .cluster
                let actions = adopt(sent, heardFrom: member, now: now)
                heard = [member: now]
                leaderRunsCluster = wasRunning
                return actions
            }
            if sent.sameLeadership(claim) { confirmed.insert(member) }
            return []
        case .refused(let newer, let facts):
            members[facts.memberID] = facts
            guard newer.supersedes(claim) else { return [] }
            leaderRunsCluster = false
            return adopt(newer, heardFrom: member, now: now)
        }
    }

    // MARK: - Time

    /// What is due now: renewals and a hand-over on the leader, a take-over on a member whose leader's lease expired.
    public mutating func tick(now: Double) -> [Action] {
        if leads {
            let others = claim.members.filter { $0 != localID }
            var actions: [Action] = others.isEmpty ? [] : [.lease(claim, to: others)]
            // Leadership moves by derivation once a plan exists (before it, the Mac that drives the onboarding keeps
            // the screens and the claim; a failover's survivor keeps it until the plan's rank 0 is back).
            if let plan = rankOrder, !plan.isEmpty,
               let choice = ClusterControlDerivation.derive(members: Array(members.values), present: present(now: now), rankOrder: plan),
               choice.memberID != localID, confirmed.contains(choice.memberID) {
                let offer = ClusterControlClaim(term: claim.term + 1, leaderID: choice.memberID, members: claim.members, reason: choice.reason)
                pendingHandOver = offer
                actions.append(.handOver(offer, to: choice.memberID))
            }
            return actions
        }
        guard now - (heard[awaited] ?? -Double.infinity) >= ttl else { return [] }
        // The awaited leader's lease expired: derive among the members the claim named, without every expired leader.
        let previous = awaited
        expired.insert(previous)
        heard[previous] = nil
        leaderRunsCluster = false
        let remaining = Set(claim.members).subtracting(expired).union([localID])
        guard let choice = ClusterControlDerivation.derive(members: Array(members.values), present: remaining, rankOrder: rankOrder)
        else { return [] }
        if choice.memberID == localID {
            claim = ClusterControlClaim(term: claim.term + 1, leaderID: localID, members: claim.members,
                reason: "failover: \(members[previous]?.name ?? previous) stopped renewing its lease; " + choice.reason)
            confirmed = []
            awaited = localID
            for id in claim.members where id != localID && !expired.contains(id) { heard[id] = now }
            expired = []
            return [.tookOver(claim, from: previous)]
        }
        // Another survivor is the successor: it gets one time-to-live to renew before it is passed over too.
        awaited = choice.memberID
        heard[choice.memberID] = now
        return []
    }

    /// What this Mac's service should run now.
    public func mode(now: Double) -> Mode {
        guard leads else { return .following(leaderID: claim.leaderID) }
        guard let plan = rankOrder, !plan.isEmpty else { return .idle }
        let present = present(now: now)
        let others = plan.filter { $0 != localID }
        if others.allSatisfy({ confirmed.contains($0) && present.contains($0) }) { return .cluster }
        let missing = others.filter { !present.contains($0) }
        // Every member answers within its time-to-live: wait for each to confirm this claim.
        if missing.isEmpty { return .confirming }
        if plan.contains(localID), plan.filter({ present.contains($0) }) == [localID] {
            if members[localID]?.holdsModelAlone == true { return .alone(missing: missing) }
            return .cannotServe(missing: missing, reason: "this Mac cannot hold the model alone")
        }
        return .cannotServe(missing: missing, reason: "a plan for the members still present is not built (re-plan with fewer members)")
    }

    /// The persisted part: restarts start from it.
    public var persisted: ClusterControlRecord {
        .init(claim: claim, members: members.values.sorted { $0.memberID < $1.memberID }, rankOrder: rankOrder)
    }
}

/// What a Mac keeps of control between restarts (in its setup record, owner-only).
public struct ClusterControlRecord: Codable, Sendable, Equatable {
    public var claim: ClusterControlClaim
    public var members: [ClusterControlMember]
    public var rankOrder: [String]?
    public init(claim: ClusterControlClaim, members: [ClusterControlMember], rankOrder: [String]?) {
        self.claim = claim; self.members = members; self.rankOrder = rankOrder
    }

    /// The claim, while it belongs to the current pairing (it names this Mac and its paired Mac); nil for a record of an
    /// earlier pairing with another Mac.
    public func claim(localID: String, peerID: String) -> ClusterControlClaim? {
        claim.members.contains(localID) && claim.members.contains(peerID) ? claim : nil
    }
}

/// Where a Mac's control starts when its cluster service starts. A persisted record belongs to ONE pairing: it is used
/// only while its claim names both this Mac and the Mac it is paired with now. A Mac re-paired with another Mac (a
/// replaced Mac) starts a new leadership history at term 0, led by the Mac that drove that onboarding, exactly as the
/// new member does; the old claim would name a member that is gone and not the new one (no lease would reach it).
public enum ClusterControlRestart {
    public static func start(persisted: ClusterControlRecord?, localID: String, peerID: String,
                             onboardingLeaderID: String) -> (claim: ClusterControlClaim, members: [ClusterControlMember]) {
        if let persisted, let claim = persisted.claim(localID: localID, peerID: peerID) { return (claim, persisted.members) }
        return (ClusterControlClaim(term: 0, leaderID: onboardingLeaderID, members: [localID, peerID],
                                    reason: "drove the onboarding (no plan adopted yet)"),
                (persisted?.members ?? []).filter { $0.memberID == localID || $0.memberID == peerID })
    }
}

/// The planner's "holds the model alone" verdicts are for ONE plan (the saved setup's signed plan SHA, the same on every
/// member). A verdict recorded for another plan never counts: after a model change, a member that has the new setup but
/// not yet the new verdicts must state that it cannot serve alone rather than load a model the planner never checked
/// for it. Only an accepted lease (never a refused, stale one) updates what a member records.
public enum ClusterControlAloneVerdicts {
    /// This member's verdict, or nil (unknown: never serve alone) unless the recorded verdicts are for the saved plan.
    public static func holds(_ memberID: String, holders: [String]?, forPlan: String?, savedPlan: String?) -> Bool? {
        guard let holders, let forPlan, let savedPlan, forPlan == savedPlan else { return nil }
        return holders.contains(memberID)
    }

    /// A lease's member facts with every verdict dropped unless they are for the plan saved here.
    public static func gated(_ facts: [ClusterControlMember], forPlan: String?, savedPlan: String?) -> [ClusterControlMember] {
        guard let forPlan, let savedPlan, forPlan == savedPlan else {
            return facts.map { var fact = $0; fact.holdsModelAlone = nil; return fact }
        }
        return facts
    }

    /// What a member records of a lease's verdicts: only from an accepted lease whose verdicts are for the saved plan.
    public static func toRecord(answer: ClusterControlNode.LeaseAnswer, facts: [ClusterControlMember], forPlan: String?,
                                savedPlan: String?) -> (holders: [String], plan: String)? {
        guard case .accepted = answer, let forPlan, let savedPlan, forPlan == savedPlan,
              facts.contains(where: { $0.holdsModelAlone != nil }) else { return nil }
        return (facts.filter { $0.holdsModelAlone == true }.map(\.memberID).sorted(), forPlan)
    }
}

/// The words for a mode, one line for `darkbloom cluster` and the service log.
public enum ClusterControlWords {
    public static func line(_ mode: ClusterControlNode.Mode, names: [String: String], model: String?) -> String {
        func name(_ id: String) -> String { names[id] ?? id }
        let what = model ?? "the model"
        switch mode {
        case .following(let leader): return "following the control leader \(name(leader))"
        case .confirming: return "leading; waiting for every member to confirm"
        case .cluster: return "leading the cluster"
        case .idle: return "leading; no model chosen yet"
        case .alone(let missing):
            return "degraded: serving on this Mac alone (\(missing.map(name).joined(separator: ", ")) is gone; the cluster re-forms by itself when it is back)"
        case .cannotServe(let missing, let reason):
            return "not serving \(what): \(missing.map(name).joined(separator: ", ")) is gone and \(reason); nothing of the model runs"
        }
    }
}

// MARK: - Forwarding (`darkbloom cluster` on any member)

/// A `darkbloom cluster` command, as a member forwards it to the control leader over the link control channel.
public struct ClusterControlRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        case status, reachMembers, planModels, adopt, serve, stop, readiness, test, verifyTeardown
    }
    public var op: Operation
    /// `adopt`: the choice's index as `planModels` listed it on the leader.
    public var index: Int?
    public init(op: Operation, index: Int? = nil) { self.op = op; self.index = index }
}

/// The leader's answer, shown as it is on the Mac that asked.
public struct ClusterControlReply: Codable, Sendable, Equatable {
    public var lines: [String]
    public var failed: Bool
    /// The leader that answered.
    public var leaderID: String?
    public var machines: [ClusterOnboardingMachine]?
    public var choices: [ClusterOnboardingModelChoice]?
    public var ready: ClusterOnboardingReady?
    /// `readiness` while not ready: the progress line.
    public var progress: String?

    public init(lines: [String], failed: Bool, leaderID: String? = nil, machines: [ClusterOnboardingMachine]? = nil,
                choices: [ClusterOnboardingModelChoice]? = nil, ready: ClusterOnboardingReady? = nil, progress: String? = nil) {
        self.lines = lines; self.failed = failed; self.leaderID = leaderID; self.machines = machines; self.choices = choices
        self.ready = ready; self.progress = progress
    }
}

public enum ClusterControlRouting {
    public enum Route: Sendable, Equatable {
        case local
        case forward(to: String)
    }

    /// Where a `darkbloom cluster` command runs: on the control leader, wherever it was typed.
    public static func route(localID: String, claim: ClusterControlClaim) -> Route {
        claim.leaderID == localID ? .local : .forward(to: claim.leaderID)
    }

    /// Nil when this Mac leads and runs a forwarded command; otherwise the words of its refusal.
    public static func refusal(localID: String, claim: ClusterControlClaim, names: [String: String]) -> String? {
        guard claim.leaderID != localID else { return nil }
        return "this Mac does not lead the cluster; it follows \(names[claim.leaderID] ?? claim.leaderID) (term \(claim.term))"
    }
}
