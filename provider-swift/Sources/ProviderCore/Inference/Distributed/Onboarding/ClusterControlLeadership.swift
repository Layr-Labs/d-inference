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
// superseded while it was away never starts a part), and acts as the leader
// at all (a model change, a setup write, a stop) only once its claim is
// confirmed or the confirmation window passed with no member reachable.
// Control fails over at the lease's time-to-live; serving ALONE waits for the
// absence grace (owner decision 6: 10 minutes of peer or link absence): until
// then the leader keeps its part ready for the missing member and says how
// long until it serves alone, and a member back before the grace re-forms the
// pair with nobody serving alone. After the grace it serves the model alone
// when the planner said it holds it alone ("degraded: serving on this Mac
// alone"), and otherwise states that it cannot serve and runs nothing. When the
// missing member answers again, the leader re-derives with it present and
// hands leadership over when derivation picks it: the pair re-forms with no
// question asked.
//
// Pure (Foundation only): times are seconds on the continuous clock
// (`ClusterControlClock`, counting through system sleep), so checks drive 2-4
// synthetic members through failover, return, sleep and split brain.

/// One member's detected facts, as the leader is derived from them.
public struct ClusterControlMember: Codable, Sendable, Equatable {
    /// `mac-` + the first 12 hex digits of the member's Secure Enclave key pin.
    public var memberID: String
    /// The name it showed at pairing (chip and memory, never a host name).
    public var name: String
    public var memoryBytes: UInt64
    public var gpuCores: Int
    /// Whether this member may serve the chosen model alone (`ClusterControlSoloAdmission`): the planner's verdict,
    /// narrowed by the member's own check; nil before a model is chosen.
    public var holdsModelAlone: Bool?
    /// Why the member cannot serve the chosen model alone although the planner said it holds it, in words (the member's
    /// own check: single-Mac Darkbloom refuses the model on its hardware, or its solo server kept ending); nil otherwise.
    public var aloneRefusal: String?

    public init(memberID: String, name: String, memoryBytes: UInt64, gpuCores: Int, holdsModelAlone: Bool? = nil,
                aloneRefusal: String? = nil) {
        self.memberID = memberID; self.name = name; self.memoryBytes = memoryBytes; self.gpuCores = gpuCores
        self.holdsModelAlone = holdsModelAlone; self.aloneRefusal = aloneRefusal
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
        /// The leader with plan members absent past their time-to-live, inside the absence grace: it keeps its part
        /// ready so the cluster re-forms when they return, and serves alone (or states it cannot) in `soloInSeconds`.
        case waiting(missing: [String], soloInSeconds: Int, canServeAlone: Bool)
        /// The leader, alone of the plan after the absence grace, and the planner said it holds the model alone.
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
    /// Owner decision 6: how long a plan member must be absent before this Mac serves alone.
    public let soloGrace: Double
    /// When this Mac (its ticks) first saw each member absent; cleared when it answers again.
    private var absentSince: [String: Double] = [:]
    private var lastTick: Double?
    /// The first tick after a gap no renewal could cross (system sleep, a suspended process): nobody could renew
    /// meanwhile, so a leader gets one time-to-live awake from here before it is passed over.
    private var awakeSince = -Double.infinity

    /// 10 minutes (owner decision 6), for every model, Mac and member count.
    public static let defaultSoloGraceSeconds: Double = 600

    /// `claim` as persisted, or nil before the first one (term 0: derived among the known members).
    public init(localID: String, members: [ClusterControlMember], claim: ClusterControlClaim?, rankOrder: [String]?, now: Double, ttl: Double,
                soloGrace: Double = ClusterControlNode.defaultSoloGraceSeconds) {
        self.localID = localID
        self.soloGrace = soloGrace
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

    /// This Mac may act as the leader (change the model, write a setup, stop the cluster): it leads, and every other
    /// member the claim names confirmed the claim in this process's lifetime or did not answer within its time-to-live
    /// (the confirmation window passed with no member reachable). A restarted Mac whose persisted claim was superseded
    /// learns so from the first refusal and steps down having acted on nothing.
    ///
    /// A confirmation counts only while its member answers within the time-to-live (a member silent for longer may have
    /// taken over), and a member counts as unreachable only after one time-to-live AWAKE: a leader that slept or was
    /// suspended past the lease acts only once the member answered again (or refused, and it stepped down) or that
    /// window passed awake. Never during a gap since the last tick that no tick has seen yet.
    public func leadershipConfirmed(now: Double) -> Bool {
        guard leads, !untickedGap(now: now) else { return false }
        let present = present(now: now)
        return claim.members.filter { $0 != localID }.allSatisfy { id in
            (confirmed.contains(id) && present.contains(id)) || now - max(heard[id] ?? -Double.infinity, awakeSince) >= ttl
        }
    }

    /// A gap since the last tick that no renewal could cross, not yet seen by a tick (`tick` then records the wake).
    private func untickedGap(now: Double) -> Bool {
        guard let last = lastTick else { return false }
        return now - last >= ttl / 3
    }

    /// When this Mac last woke from such a gap: now while the gap has not been ticked yet.
    private func wokeAt(now: Double) -> Double { untickedGap(now: now) ? now : awakeSince }

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
        if untickedGap(now: now) { awakeSince = now }
        lastTick = now
        defer { noteAbsences(now: now) }
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
        // A gap no renewal could cross (system sleep) is not silence: the leader gets one time-to-live awake.
        guard now - max(heard[awaited] ?? -Double.infinity, awakeSince) >= ttl else { return [] }
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

    private mutating func noteAbsences(now: Double) {
        let present = present(now: now)
        for id in Set(claim.members + (rankOrder ?? [])) where id != localID {
            if present.contains(id) { absentSince[id] = nil } else if absentSince[id] == nil { absentSince[id] = now }
        }
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
        let alonePossible = plan.contains(localID) && plan.filter({ present.contains($0) }) == [localID] && members[localID]?.holdsModelAlone == true
        // The grace counts from the most recent loss (a member not yet seen absent by a tick: from now).
        let since = missing.map { absentSince[$0] ?? now }.max() ?? now
        // A Mac that just woke gives the missing members one time-to-live awake to answer before it serves alone (one
        // may have come back while it slept), whatever its absence record from before the sleep says.
        let remaining = max(soloGrace - (now - since), ttl - (now - wokeAt(now: now)))
        if remaining > 0 {
            return .waiting(missing: missing, soloInSeconds: Int(remaining.rounded(.up)), canServeAlone: alonePossible)
        }
        if alonePossible { return .alone(missing: missing) }
        if plan.contains(localID), plan.filter({ present.contains($0) }) == [localID] {
            if let refusal = members[localID]?.aloneRefusal {
                return .cannotServe(missing: missing, reason: "this Mac cannot serve it alone (\(refusal)), so it waits for the other Mac")
            }
            return .cannotServe(missing: missing, reason: "this Mac cannot hold the model alone, so it waits for the other Mac")
        }
        return .cannotServe(missing: missing, reason: "it re-forms when the other Mac is back")
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

/// F14: whether this Mac may serve the saved model alone in degraded mode, decided on the Mac itself before any solo
/// server starts. Any one of three facts says no:
/// - the planner's verdict for the saved plan (`ClusterControlAloneVerdicts`: the model fits this Mac's admissible memory);
/// - the runtime requirements single-Mac Darkbloom enforces for the model (`start --local` serves no model whose required
///   runtime capabilities this Mac lacks): every requirement this Mac's hardware settles (the chip family) is checked here;
///   one only the runtime's own probe settles is left to the solo server, and the next fact catches its refusal;
/// - the solo server's own record on this Mac: one that ended soon after its start `maximumQuickEnds` times in a row is
///   not started again for this plan (a refusal nothing predicted), instead of restarting every 30 s for ever.
/// Universal: capability names come from the product's own requirements and detector, never a model or chip table here.
public enum ClusterControlSoloAdmission {
    public struct Verdict: Sendable, Equatable {
        public var holds: Bool?
        public var refusal: String?
        public init(holds: Bool?, refusal: String?) { self.holds = holds; self.refusal = refusal }
    }

    /// Solo-server ends in a row, each sooner than `quickEndSeconds` after its start, before it is not started again.
    public static let maximumQuickEnds = 3
    /// The supervisor's own rule: a part that ran this long was healthy (its restart backoff resets too).
    public static let quickEndSeconds: Double = 120

    /// The required capabilities this Mac's hardware settles and lacks (sorted); empty when the model may be tried here.
    public static func missingHardware(required: Set<String>, hardwareSettled: Set<String>, hardware: Set<String>) -> [String] {
        required.intersection(hardwareSettled).subtracting(hardware).sorted()
    }

    public static func decide(planned: Bool?, missingHardware: [String], quickEnds: Int) -> Verdict {
        guard let planned else { return .init(holds: nil, refusal: nil) }
        guard planned else { return .init(holds: false, refusal: nil) }
        if !missingHardware.isEmpty {
            return .init(holds: false, refusal: "single-Mac Darkbloom serves this model only on a Mac with "
                         + missingHardware.map(words).joined(separator: " and "))
        }
        if quickEnds >= maximumQuickEnds {
            return .init(holds: false, refusal: "its single-Mac server ended \(quickEnds) times right after starting")
        }
        return .init(holds: true, refusal: nil)
    }

    /// The count after a solo server ended `ranSeconds` after its start.
    public static func quickEnds(after count: Int, ranSeconds: Double) -> Int {
        ranSeconds < quickEndSeconds ? count + 1 : 0
    }

    /// A runtime capability in words (its raw name when it has none here).
    public static func words(_ capability: String) -> String {
        switch capability {
        case "apple_m5": return "an Apple M5 chip"
        case "mlx_nax": return "the GPU's neural accelerators"
        default: return "the \(capability) capability"
        }
    }
}

/// The control clock: seconds that keep counting through system sleep (`CLOCK_MONOTONIC_RAW`, the continuous mach
/// clock). Uptime stops while a Mac sleeps, so a woken leader would count a member that left during the sleep as present.
public enum ClusterControlClock {
    public static func seconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }
}

/// Owner decision 6's absence grace before serving alone: universal (no model, chip or member input). Only a developer
/// (DEBUG) build may shorten it for tests, through `environmentKey`, between 0 and 3600 s.
public enum ClusterControlSoloGrace {
    public static let environmentKey = "DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS"
    public static func seconds(environment: [String: String], debugBuild: Bool) -> Double {
        guard debugBuild, let raw = environment[environmentKey], let value = Double(raw), value.isFinite, value >= 0, value <= 3600 else {
            return ClusterControlNode.defaultSoloGraceSeconds
        }
        return value
    }
}

/// What a Mac's service runs for its mode.
public enum ClusterControlPartChoice: Sendable, Equatable {
    /// Leave whatever runs as it is.
    case keep
    case none
    /// This Mac's part of the saved setup.
    case cluster
    /// Degraded: the model on this Mac alone.
    case solo(String)

    public static func want(mode: ClusterControlNode.Mode, serving: Bool, hasSetup: Bool, leaderRunsCluster: Bool, runningSolo: Bool,
                            model: String?) -> ClusterControlPartChoice {
        switch mode {
        case .following: return serving && hasSetup && leaderRunsCluster ? .cluster : .none
        case .cluster: return serving && hasSetup ? .cluster : .none
        // Inside the absence grace this Mac's part stays ready for the member's return; a solo server already running
        // (the member came and went again) stays rather than being swapped back and forth.
        case .waiting: return runningSolo ? .keep : serving && hasSetup ? .cluster : .none
        case .confirming: return .keep
        case .idle, .cannotServe: return .none
        case .alone: return serving ? model.map { .solo($0) } ?? .none : .none
        }
    }

    /// Whether the wanted part (`key`) may start now: once the restart backoff of the part that ended last (`endedKey`)
    /// elapsed, or at once when the wanted part is another one: the backoff belongs to the part that kept ending (rank 0
    /// waiting for its missing follower), so serving alone after the grace never waits it out.
    public static func mayStart(key: String, endedKey: String?, backoffElapsed: Bool) -> Bool {
        backoffElapsed || key != endedKey
    }

    /// Whether the leader's lease tells its members that the cluster runs (they run their parts only then): while it
    /// runs as planned, and while it waits inside the absence grace for a member to return.
    public static func leaseSaysRunning(mode: ClusterControlNode.Mode, serving: Bool) -> Bool {
        guard serving else { return false }
        switch mode {
        case .cluster, .waiting: return true
        default: return false
        }
    }
}

/// The leader's serving intent (its setup record's `leadership.serving`: the user started or stopped the cluster)
/// travels with every lease and hand-over, and a Mac records it from an accepted lease of its current leader. So a stop
/// or start typed on a survivor while the plan's rank 0 was away is what rank 0 leads with once control is handed back,
/// instead of the intent rank 0 had before it went away. A refused (stale) leader's intent is never recorded.
public enum ClusterControlIntent {
    /// The value to record, or nil (nothing to change: a refused lease, no intent sent, or the same intent).
    public static func toRecord(answer: ClusterControlNode.LeaseAnswer, leaderServing: Bool?, recorded: Bool?) -> Bool? {
        guard case .accepted = answer, let leaderServing, leaderServing != recorded else { return nil }
        return leaderServing
    }
}

/// The words for a mode, one line for `darkbloom cluster` and the service log.
public enum ClusterControlWords {
    /// When the service log repeats a mode's line: when it changes, except that inside the grace (whose countdown changes
    /// every second) only when the whole minutes until solo change.
    public static func logKey(_ mode: ClusterControlNode.Mode, line: String) -> String {
        if case .waiting(let missing, let seconds, let canServeAlone) = mode {
            return "waiting \(missing.joined(separator: ",")) \(canServeAlone) \(seconds / 60)"
        }
        return line
    }

    /// "9 min 50 s", "45 s".
    public static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return value >= 60 ? "\(value / 60) min" + (value % 60 == 0 ? "" : " \(value % 60) s") : "\(value) s"
    }

    /// `aloneRefusal`: this Mac's own reason it cannot serve the model alone (`ClusterControlMember.aloneRefusal`).
    public static func line(_ mode: ClusterControlNode.Mode, names: [String: String], model: String?, aloneRefusal: String? = nil) -> String {
        func name(_ id: String) -> String { names[id] ?? id }
        let what = model ?? "the model"
        switch mode {
        case .following(let leader): return "commands typed here are handled by \(name(leader))"
        case .confirming: return "leading; waiting for every member to confirm"
        case .cluster: return "leading the cluster"
        case .idle: return "leading; no model chosen yet"
        case .waiting(let missing, let seconds, let canServeAlone):
            let gone = missing.map(name).joined(separator: ", ")
            return canServeAlone
                ? "\(gone) is gone; this Mac serves \(what) alone in \(duration(seconds)) unless it returns first (the cluster re-forms by itself when it is back)"
                : aloneRefusal.map { "\(gone) is gone; this Mac cannot serve \(what) alone (\($0)), so nothing of it runs after \(duration(seconds)) unless it returns first; it waits for \(gone)" }
                ?? "\(gone) is gone; this Mac cannot hold \(what) alone, so nothing of it runs after \(duration(seconds)) unless it returns first"
        case .alone(let missing):
            return "degraded: serving on this Mac alone (\(missing.map(name).joined(separator: ", ")) is gone; the cluster re-forms by itself when it is back)"
        case .cannotServe(let missing, let reason):
            let gone = missing.map(name).joined(separator: ", ")
            if let aloneRefusal, reason.contains(aloneRefusal) {
                return "not serving \(what): \(gone) is gone and this Mac cannot serve \(what) alone (\(aloneRefusal)); nothing of the model runs here, "
                    + "it waits for \(gone) and the cluster re-forms by itself when it is back"
            }
            return "not serving \(what): \(gone) is gone and \(reason); nothing of the model runs"
        }
    }
}

// MARK: - Forwarding (`darkbloom cluster` on any member)

/// A `darkbloom cluster` command, as a member forwards it to the control leader over the link control channel.
public struct ClusterControlRequest: Codable, Sendable, Equatable {
    /// `scope`: how the cluster serves from now on (`localOnly`, `bind`), saved on the leader. A leader whose build
    /// predates an operation cannot decode the request and answers with a failure.
    public enum Operation: String, Codable, Sendable {
        case status, reachMembers, planModels, adopt, serve, stop, readiness, test, verifyTeardown, scope
    }
    public var op: Operation
    /// `adopt`: the choice's index as `planModels` listed it on the leader.
    public var index: Int?
    /// `adopt`: the id of the model at `index`, so a leader whose list is gone (it restarted) plans again and finds it.
    /// Nil from an older build.
    public var model: String?
    public var localOnly: Bool?
    public var bind: String?
    public init(op: Operation, index: Int? = nil, model: String? = nil, scope: ClusterServingScope? = nil) {
        self.op = op; self.index = index; self.model = model; self.localOnly = scope.map(\.isLocalOnly); self.bind = scope?.bind
    }

    /// `scope`'s value; nil when it names none or an address the local API does not take.
    public var scope: ClusterServingScope? { ClusterServingScope.carried(localOnly: localOnly, bind: bind) }
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
    /// The Mac asked does not lead (any more): nothing ran there, and the asking Mac routes the command again.
    public var notLeader: Bool?

    public init(lines: [String], failed: Bool, leaderID: String? = nil, machines: [ClusterOnboardingMachine]? = nil,
                choices: [ClusterOnboardingModelChoice]? = nil, ready: ClusterOnboardingReady? = nil, progress: String? = nil,
                notLeader: Bool? = nil) {
        self.lines = lines; self.failed = failed; self.leaderID = leaderID; self.machines = machines; self.choices = choices
        self.ready = ready; self.progress = progress; self.notLeader = notLeader
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
        return "commands are handled by \(names[claim.leaderID] ?? claim.leaderID) now; it re-forms by itself if that changes"
    }
}

