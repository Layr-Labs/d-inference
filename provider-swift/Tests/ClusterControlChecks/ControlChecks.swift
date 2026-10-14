import Foundation
import Darwin

/// Model-free checks of the derived control leader (`ClusterControlLeadership.swift`): derivation from synthetic
/// 2-4 member profiles, restarts re-forming identically, forwarding to the current leader, failover at lease expiry,
/// degraded serving alone, re-forming on return and split-brain refusal. Built with plain swiftc by run.sh.
@main enum ControlChecks {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures = [String]()

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition { passed += 1 } else { failures.append("line \(line): \(message())") }
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(60); defer { alarm(0) }
        derivation()
        restartsReformIdentically()
        forwarding()
        failoverAlone()
        failoverCannotServe()
        returnReforms()
        splitBrainRefused()
        threeMemberFailover()
        fourMembersOneLost()
        startupGrace()
        onboardingDriverKeepsClaimUntilAPlan()
        aloneVerdictsBoundToThePlan()
        rePairedWithAnotherMac()
        restartedLeaderActsOnlyWhenConfirmed()
        soloOnlyAfterTheAbsenceGrace()
        leaderFaultWaitsForTheGraceThenReforms()
        soloGraceSetting()
        partChoice()
        continuousClockAndWake()
        waitingLogsOncePerMinute()
        wokenLeaderReconfirms()
        wokenMacGivesMembersATimeToLiveBeforeSolo()
        leaderIntentSurvivesTheHandOver()
        soloStartsWithoutTheEndedPartsBackoff()
        // F14 (round 6b, 2026-10-14): failing first on 33da00709.
        soloAdmissionChecksTheRuntimeRequirements()
        print("control checks: \(passed) passed, \(failures.count) failed")
        for failure in failures { print("FAIL " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Synthetic hardware (no bench Mac)

    static let gib: UInt64 = 1 << 30
    static func mac(_ id: String, _ name: String, _ gigabytes: UInt64, _ cores: Int, alone: Bool? = nil) -> ClusterControlMember {
        .init(memberID: id, name: name, memoryBytes: gigabytes * gib, gpuCores: cores, holdsModelAlone: alone)
    }

    static func derivation() {
        // Two equal 64 GB M2 Max: the tie goes to the lower stable identity, whatever the input order.
        let twins = [mac("mac-bbbbbbbbbbbb", "Apple M2 Max, 64 GB", 64, 38), mac("mac-aaaaaaaaaaaa", "Apple M2 Max, 64 GB", 64, 38)]
        let all = Set(twins.map(\.memberID))
        expect(ClusterControlDerivation.derive(members: twins, present: all, rankOrder: nil)?.memberID == "mac-aaaaaaaaaaaa", "tie -> lowest identity")
        expect(ClusterControlDerivation.derive(members: twins.reversed(), present: all, rankOrder: nil)?.memberID == "mac-aaaaaaaaaaaa", "order-free")
        // M4 Pro 48 GB + M3 Ultra 256 GB: the Ultra (memory).
        let mixed = [mac("mac-000000000001", "Apple M4 Pro, 48 GB", 48, 20), mac("mac-ffffffffffff", "Apple M3 Ultra, 256 GB", 256, 80)]
        expect(ClusterControlDerivation.derive(members: mixed, present: Set(mixed.map(\.memberID)), rankOrder: nil)?.memberID == "mac-ffffffffffff",
               "most memory leads before a plan")
        // A plan: rank 0 leads although it has less memory (requests enter there), whoever started onboarding.
        let planned = ClusterControlDerivation.derive(members: mixed, present: Set(mixed.map(\.memberID)), rankOrder: ["mac-000000000001", "mac-ffffffffffff"])
        expect(planned?.memberID == "mac-000000000001" && planned!.reason.contains("rank 0"), "rank 0 of the plan leads: \(String(describing: planned))")
        // Three members, rank 0 absent: of those present, the one that holds the model alone first, then memory.
        let three = [mac("mac-111111111111", "Apple M2 Max, 64 GB", 64, 38, alone: false),
                     mac("mac-222222222222", "Apple M4 Max, 128 GB", 128, 40, alone: true),
                     mac("mac-333333333333", "Apple M3 Ultra, 192 GB", 192, 76, alone: false)]
        let survivor = ClusterControlDerivation.derive(members: three, present: ["mac-222222222222", "mac-333333333333"],
                                                       rankOrder: ["mac-111111111111", "mac-333333333333", "mac-222222222222"])
        expect(survivor?.memberID == "mac-222222222222", "holding the model alone comes before memory: \(String(describing: survivor))")
        expect(ClusterControlDerivation.derive(members: three, present: [], rankOrder: nil) == nil, "nobody present, nobody leads")
        // Same GPU memory, more cores wins.
        let cores = [mac("mac-aaaaaaaaaaaa", "Apple M4 Max, 128 GB", 128, 32), mac("mac-bbbbbbbbbbbb", "Apple M4 Max, 128 GB", 128, 40)]
        expect(ClusterControlDerivation.derive(members: cores, present: Set(cores.map(\.memberID)), rankOrder: nil)?.memberID == "mac-bbbbbbbbbbbb", "cores")
    }

    static func restartsReformIdentically() {
        let members = [mac("mac-aaaaaaaaaaaa", "Apple M3 Ultra, 256 GB", 256, 80), mac("mac-bbbbbbbbbbbb", "Apple M5 Ultra, 256 GB", 256, 80)]
        let plan = ["mac-bbbbbbbbbbbb", "mac-aaaaaaaaaaaa"]
        // Every member derives the same first claim from the same facts, with no message exchanged.
        let a = ClusterControlNode(localID: "mac-aaaaaaaaaaaa", members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30)
        let b = ClusterControlNode(localID: "mac-bbbbbbbbbbbb", members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30)
        expect(a.claim == b.claim && a.claim.leaderID == "mac-bbbbbbbbbbbb", "both derive rank 0: \(a.claim) / \(b.claim)")
        // A restart from the persisted record: the same claim, the same leader.
        let data = try! JSONEncoder().encode(a.persisted)
        let record = try! JSONDecoder().decode(ClusterControlRecord.self, from: data)
        let again = ClusterControlNode(localID: "mac-aaaaaaaaaaaa", members: record.members, claim: record.claim, rankOrder: record.rankOrder, now: 500, ttl: 30)
        expect(again.claim == a.claim && again.rankOrder == plan && !again.leads, "persisted claim re-forms the same way")
    }

    // MARK: - Forwarding

    static func forwarding() {
        let claim = ClusterControlClaim(term: 3, leaderID: "mac-bbbbbbbbbbbb", members: ["mac-aaaaaaaaaaaa", "mac-bbbbbbbbbbbb", "mac-cccccccccccc"], reason: "x")
        expect(ClusterControlRouting.route(localID: "mac-bbbbbbbbbbbb", claim: claim) == .local, "the leader runs a command itself")
        expect(ClusterControlRouting.route(localID: "mac-aaaaaaaaaaaa", claim: claim) == .forward(to: "mac-bbbbbbbbbbbb"), "a member forwards")
        expect(ClusterControlRouting.route(localID: "mac-cccccccccccc", claim: claim) == .forward(to: "mac-bbbbbbbbbbbb"), "any member forwards")
        // Every request survives the channel's encoding, and the leader's answer comes back whole.
        let requests: [ClusterControlRequest] = [.init(op: .status), .init(op: .reachMembers), .init(op: .planModels), .init(op: .adopt, index: 2),
                                                 .init(op: .serve), .init(op: .stop), .init(op: .readiness), .init(op: .test), .init(op: .verifyTeardown)]
        for request in requests {
            let decoded = try? JSONDecoder().decode(ClusterControlRequest.self, from: JSONEncoder().encode(request))
            expect(decoded == request, "request round trip \(request)")
        }
        let reply = ClusterControlReply(lines: ["Serving m from Apple M3 Ultra, 256 GB (2 of 2 parts ready)."], failed: false, leaderID: "mac-bbbbbbbbbbbb",
            machines: [.init(name: "Apple M3 Ultra, 256 GB", memoryGB: 256, gpuCores: 80, leads: true, models: 2)],
            choices: [.init(title: "m", lines: ["rank 0"], blocker: nil)], ready: .init(servedBy: "this Mac", port: 8000), progress: "1 of 2 parts ready")
        expect((try? JSONDecoder().decode(ClusterControlReply.self, from: JSONEncoder().encode(reply))) == reply, "reply round trip")
        // A Mac that stopped leading while a command was on its way runs nothing and says so: the sender routes it again.
        let moved = ClusterControlReply(lines: ["The command did not run: this Mac does not lead the cluster"], failed: true,
                                        leaderID: "mac-aaaaaaaaaaaa", notLeader: true)
        expect((try? JSONDecoder().decode(ClusterControlReply.self, from: JSONEncoder().encode(moved)))?.notLeader == true, "notLeader travels")
        let older = try? JSONDecoder().decode(ClusterControlReply.self, from: Data(#"{"lines":["x"],"failed":true}"#.utf8))
        expect(older != nil && older?.notLeader == nil, "a reply of the previous build still decodes")
        // A Mac that does not lead refuses a forwarded command and names the leader it follows.
        let refusal = ClusterControlRouting.refusal(localID: "mac-aaaaaaaaaaaa", claim: claim, names: ["mac-bbbbbbbbbbbb": "Apple M5 Ultra, 256 GB"])
        expect(refusal?.contains("Apple M5 Ultra, 256 GB") == true, "refusal names the leader: \(String(describing: refusal))")
        expect(refusal?.contains("term") == false && refusal?.contains("control leader") == false, "refusal in plain words: \(String(describing: refusal))")
        expect(ClusterControlRouting.refusal(localID: "mac-bbbbbbbbbbbb", claim: claim, names: [:]) == nil, "the leader accepts")
    }

    // MARK: - A small bus of nodes

    struct Bus {
        var nodes: [String: ClusterControlNode]
        var up: Set<String>
        var cut: Set<String> = []   // nodes with their cable out (alive, unreachable)
        var log: [String] = []
        /// Each Mac's recorded serving intent (its setup record's `leadership.serving`), when a check follows it.
        var serving: [String: Bool] = [:]

        func reachable(_ a: String, _ b: String) -> Bool { up.contains(a) && up.contains(b) && !cut.contains(a) && !cut.contains(b) }

        mutating func step(_ now: Double, running: [String: Bool] = [:]) {
            for id in nodes.keys.sorted() where up.contains(id) {
                let actions = nodes[id]!.tick(now: now)
                for action in actions { deliver(action, from: id, now: now, running: running[id] ?? true) }
            }
        }

        mutating func deliver(_ action: ClusterControlNode.Action, from sender: String, now: Double, running: Bool) {
            switch action {
            case .lease(let claim, let targets):
                for target in targets where reachable(sender, target) { exchange(claim, from: sender, to: target, now: now, running: running) }
            case .handOver(let claim, let target):
                if reachable(sender, target) { exchange(claim, from: sender, to: target, now: now, running: false) }
            case .tookOver(let claim, let from): log.append("\(sender) took over term \(claim.term) from \(from) at \(now)")
            case .steppedDown(let claim): log.append("\(sender) stepped down to \(claim.leaderID) term \(claim.term) at \(now)")
            }
        }

        mutating func exchange(_ claim: ClusterControlClaim, from sender: String, to target: String, now: Double, running: Bool) {
            let facts = Array(nodes[sender]!.members.values)
            let (answer, actions) = nodes[target]!.receiveLease(from: sender, offered: claim, running: running, facts: facts, now: now)
            if let intent = ClusterControlIntent.toRecord(answer: answer, leaderServing: serving[sender], recorded: serving[target]) {
                serving[target] = intent
            }
            for action in actions { deliver(action, from: target, now: now, running: false) }
            for action in nodes[sender]!.receiveAnswer(from: target, sent: claim, answer: answer, now: now) {
                deliver(action, from: sender, now: now, running: false)
            }
        }

        var leaders: [String] { nodes.keys.sorted().filter { up.contains($0) && nodes[$0]!.leads } }
    }

    /// `grace`: the absence grace before serving alone (owner decision 6); 0 here unless a check is about the grace.
    static func pair(aloneA: Bool, aloneB: Bool, grace: Double = 0) -> Bus {
        // Rank 0 = A (M3 Ultra), rank 1 = B (M5 Ultra) decodes; B started the onboarding (it does not matter).
        let members = [mac("mac-aaaaaaaaaaaa", "Apple M3 Ultra, 256 GB", 256, 80, alone: aloneA),
                       mac("mac-bbbbbbbbbbbb", "Apple M5 Ultra, 256 GB", 256, 80, alone: aloneB)]
        let plan = ["mac-aaaaaaaaaaaa", "mac-bbbbbbbbbbbb"]
        var nodes = [String: ClusterControlNode]()
        for m in members {
            nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30, soloGrace: grace)
        }
        return Bus(nodes: nodes, up: Set(nodes.keys))
    }

    static let A = "mac-aaaaaaaaaaaa", B = "mac-bbbbbbbbbbbb"

    static func failoverAlone() {
        var bus = pair(aloneA: true, aloneB: true)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        expect(bus.leaders == [A] && bus.nodes[A]!.mode(now: 20) == .cluster, "rank 0 leads and the cluster runs: \(bus.leaders)")
        expect(bus.nodes[B]!.mode(now: 20) == .following(leaderID: A) && bus.nodes[B]!.leaderRunsCluster, "B follows a running cluster")
        // The leader's service stops at t=22 (its last renewal was at 20).
        bus.up.remove(A)
        var tookOverAt: Double?
        for t in stride(from: 25.0, through: 60, by: 1) {
            bus.step(t)
            if tookOverAt == nil, bus.nodes[B]!.leads { tookOverAt = t }
        }
        expect(tookOverAt == 50, "failover exactly one time-to-live after the last renewal: \(String(describing: tookOverAt))")
        expect(bus.nodes[B]!.claim.term == 1 && bus.nodes[B]!.claim.reason.contains("failover"), "term 1, reason in words: \(bus.nodes[B]!.claim)")
        expect(bus.nodes[B]!.mode(now: 60) == .alone(missing: [A]), "the survivor serves alone: \(bus.nodes[B]!.mode(now: 60))")
        let words = ClusterControlWords.line(bus.nodes[B]!.mode(now: 60), names: [A: "Apple M3 Ultra, 256 GB"], model: "m")
        expect(words.hasPrefix("degraded: serving on this Mac alone"), "stated: \(words)")
    }

    static func failoverCannotServe() {
        var bus = pair(aloneA: true, aloneB: false)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        bus.up.remove(A)
        for t in stride(from: 25.0, through: 60, by: 5) { bus.step(t) }
        guard case .cannotServe(let missing, let reason)? = Optional(bus.nodes[B]!.mode(now: 60)) else {
            return expect(false, "a survivor that cannot hold the model alone states it: \(bus.nodes[B]!.mode(now: 60))")
        }
        expect(missing == [A] && reason.contains("cannot hold the model alone"), "reason: \(reason)")
        expect(ClusterControlWords.line(bus.nodes[B]!.mode(now: 60), names: [:], model: "m").contains("nothing of the model runs"), "words")
    }

    static func returnReforms() {
        var bus = pair(aloneA: true, aloneB: true)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        let stale = bus.nodes[A]!.persisted
        bus.up.remove(A)
        for t in stride(from: 25.0, through: 100, by: 5) { bus.step(t) }
        expect(bus.nodes[B]!.leads && bus.nodes[B]!.claim.term == 1, "B leads term 1")
        // A comes back from its persisted (now stale) claim: it believes it leads term 0, but must not act on it.
        bus.nodes[A] = ClusterControlNode(localID: A, members: stale.members, claim: stale.claim, rankOrder: stale.rankOrder, now: 101, ttl: 30, soloGrace: 0)
        bus.up.insert(A)
        expect(bus.nodes[A]!.mode(now: 101) == .confirming, "a restarted leader runs nothing before its claim is confirmed")
        var modesOfA = [ClusterControlNode.Mode]()
        for t in stride(from: 101.0, through: 140, by: 1) {
            bus.step(t)
            modesOfA.append(bus.nodes[A]!.mode(now: t))
            let acting = bus.leaders.filter { id in
                switch bus.nodes[id]!.mode(now: t) { case .cluster, .alone: return true; default: return false }
            }
            expect(acting.count <= 1, "never two leaders acting at \(t): \(acting)")
        }
        expect(!modesOfA.contains(.alone(missing: [B])), "the returning Mac never served alone")
        expect(bus.log.contains { $0.hasPrefix("\(A) stepped down to \(B) term 1") }, "the stale leader stepped down: \(bus.log)")
        expect(bus.leaders == [A] && bus.nodes[A]!.claim.term == 2, "rank 0 leads again from term 2: \(bus.leaders) \(bus.nodes[A]!.claim)")
        expect(bus.nodes[A]!.mode(now: 140) == .cluster, "the pair re-formed: \(bus.nodes[A]!.mode(now: 140))")
        expect(bus.nodes[B]!.mode(now: 140) == .following(leaderID: A) && bus.nodes[B]!.leaderRunsCluster, "B follows the running cluster")
    }

    static func splitBrainRefused() {
        var bus = pair(aloneA: true, aloneB: true)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        // The cable is pulled: both stay up. A keeps term 0, B takes term 1; each can only serve alone.
        bus.cut = [A]
        for t in stride(from: 25.0, through: 80, by: 5) { bus.step(t) }
        expect(bus.nodes[A]!.mode(now: 80) == .alone(missing: [B]) && bus.nodes[B]!.mode(now: 80) == .alone(missing: [A]),
               "partitioned: each serves alone, neither commands the other")
        // The cable is back: one exchange, and exactly one leader remains; the lower claim stepped down.
        bus.cut = []
        bus.step(85)
        expect(bus.leaders.count == 1, "one leader after the first exchange: \(bus.leaders)")
        for t in stride(from: 90.0, through: 120, by: 5) { bus.step(t) }
        expect(bus.leaders == [A] && bus.nodes[A]!.mode(now: 120) == .cluster, "re-formed under rank 0: \(bus.leaders)")
        // A stale lease (lower term) is refused with the claim that supersedes it.
        var member = ClusterControlNode(localID: B, members: [], claim: .init(term: 5, leaderID: B, members: [A, B], reason: "x"), rankOrder: nil, now: 0, ttl: 30)
        let stale = ClusterControlClaim(term: 4, leaderID: A, members: [A, B], reason: "old")
        let (answer, _) = member.receiveLease(from: A, offered: stale, running: true, facts: [], now: 1)
        guard case .refused(let newer, _) = answer else { return expect(false, "stale lease refused") }
        expect(newer.term == 5 && newer.leaderID == B, "the refusal carries the superseding claim")
        // Equal terms never tie: the lower identity wins, both ways.
        let a5 = ClusterControlClaim(term: 5, leaderID: A, members: [A, B], reason: ""), b5 = ClusterControlClaim(term: 5, leaderID: B, members: [A, B], reason: "")
        expect(a5.supersedes(b5) && !b5.supersedes(a5), "equal terms: one total order")
        // A lease whose sender is not the claim's leader is refused (no one relays another's claim).
        var other = ClusterControlNode(localID: B, members: [], claim: .init(term: 1, leaderID: B, members: [A, B], reason: ""), rankOrder: nil, now: 0, ttl: 30)
        let forged = ClusterControlClaim(term: 9, leaderID: "mac-cccccccccccc", members: [A, B], reason: "")
        if case .accepted = other.receiveLease(from: A, offered: forged, running: true, facts: [], now: 1).answer { expect(false, "relayed claim accepted") }
        else { expect(other.claim.term == 1, "relayed claim refused, claim unchanged") }
        // The stale leader's answer handling: a refusal with a newer claim makes it step down.
        var oldLeader = ClusterControlNode(localID: A, members: [], claim: stale, rankOrder: nil, now: 0, ttl: 30)
        let actions = oldLeader.receiveAnswer(from: B, sent: stale, answer: answer, now: 2)
        expect(!oldLeader.leads && actions == [.steppedDown(to: newer)], "stale leader steps down: \(actions)")
    }

    static func threeMemberFailover() {
        let members = [mac("mac-111111111111", "Apple M3 Ultra, 256 GB", 256, 80),
                       mac("mac-222222222222", "Apple M4 Max, 128 GB", 128, 40, alone: false),
                       mac("mac-333333333333", "Apple M2 Max, 64 GB", 64, 38, alone: false)]
        let plan = ["mac-111111111111", "mac-222222222222", "mac-333333333333"]
        var nodes = [String: ClusterControlNode]()
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30, soloGrace: 0) }
        var bus = Bus(nodes: nodes, up: Set(nodes.keys))
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        expect(bus.leaders == ["mac-111111111111"], "rank 0 leads three")
        // Rank 0 and the derived successor go at once: the third waits one time-to-live for the successor, then takes over.
        bus.up.subtract(["mac-111111111111", "mac-222222222222"])
        var at: Double?
        for t in stride(from: 21.0, through: 120, by: 1) { bus.step(t); if at == nil, bus.nodes["mac-333333333333"]!.leads { at = t } }
        expect(at == 80, "successor passed over after a second time-to-live: \(String(describing: at))")
        guard case .cannotServe = bus.nodes["mac-333333333333"]!.mode(now: 120) else { return expect(false, "M2 Max cannot hold it alone") }
        // Only rank 0 lost, both survivors up: they agree on one successor without talking to each other.
        nodes = [:]
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30, soloGrace: 0) }
        bus = Bus(nodes: nodes, up: Set(nodes.keys))
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        bus.up.remove("mac-111111111111")
        for t in stride(from: 21.0, through: 80, by: 1) { bus.step(t) }
        expect(bus.leaders == ["mac-222222222222"], "one successor (most memory present): \(bus.leaders)")
        expect(bus.nodes["mac-333333333333"]!.mode(now: 80) == .following(leaderID: "mac-222222222222"), "the other follows it")
        expect(bus.log.filter { $0.contains("took over") }.count == 1, "exactly one take-over: \(bus.log)")
    }

    static func fourMembersOneLost() {
        let members = (1...4).map { mac("mac-00000000000\($0)", "Apple M2 Max, 64 GB", 64, 38, alone: false) }
        let plan = members.map(\.memberID)
        var nodes = [String: ClusterControlNode]()
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30, soloGrace: 0) }
        var bus = Bus(nodes: nodes, up: Set(nodes.keys))
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        expect(bus.leaders == ["mac-000000000001"] && bus.nodes["mac-000000000001"]!.mode(now: 20) == .cluster, "four form")
        bus.up.remove("mac-000000000004")
        for t in stride(from: 25.0, through: 60, by: 5) { bus.step(t) }
        guard case .cannotServe(let missing, let reason) = bus.nodes["mac-000000000001"]!.mode(now: 60) else {
            return expect(false, "three of four: stated, not served")
        }
        expect(missing == ["mac-000000000004"] && reason.contains("re-forms when the other Mac is back") && !reason.contains("re-plan"), "\(missing) \(reason)")
        expect(bus.leaders == ["mac-000000000001"], "rank 0 keeps leading (it is present)")
    }

    static func startupGrace() {
        let members = [mac(A, "Apple M3 Ultra, 256 GB", 256, 80, alone: true), mac(B, "Apple M5 Ultra, 256 GB", 256, 80, alone: true)]
        var node = ClusterControlNode(localID: A, members: members, claim: nil, rankOrder: [A, B], now: 1000, ttl: 30, soloGrace: 0)
        expect(node.mode(now: 1000) == .confirming && node.mode(now: 1029) == .confirming, "no member heard yet: wait, do not serve alone")
        expect(node.mode(now: 1030) == .alone(missing: [B]), "after one time-to-live with nobody: alone")
        _ = node.tick(now: 1031)
        let answer = ClusterControlNode.LeaseAnswer.accepted(members[1])
        _ = node.receiveAnswer(from: B, sent: node.claim, answer: answer, now: 1032)
        expect(node.mode(now: 1032) == .cluster, "a confirmation forms the cluster")
        // No plan: nothing to run, whatever is present.
        let idle = ClusterControlNode(localID: A, members: members, claim: nil, rankOrder: nil, now: 0, ttl: 30)
        expect(idle.mode(now: 100) == .idle || !idle.leads, "no plan, no part")
    }

    /// The Mac that drove the onboarding (here the M5 Ultra, B) keeps the claim while no plan exists, although derivation
    /// by capability alone would pick A; once the plan is adopted, rank 0 (A) gets leadership by hand-over.
    static func onboardingDriverKeepsClaimUntilAPlan() {
        let members = [mac(A, "Apple M3 Ultra, 256 GB", 256, 80, alone: true), mac(B, "Apple M5 Ultra, 256 GB", 256, 80, alone: true)]
        let start = ClusterControlClaim(term: 0, leaderID: B, members: [A, B], reason: "drove the onboarding")
        let nodes = [A: ClusterControlNode(localID: A, members: members, claim: start, rankOrder: nil, now: 0, ttl: 30),
                     B: ClusterControlNode(localID: B, members: members, claim: start, rankOrder: nil, now: 0, ttl: 30)]
        var bus = Bus(nodes: nodes, up: [A, B])
        for t in stride(from: 0.0, through: 60, by: 5) { bus.step(t) }
        expect(bus.leaders == [B] && bus.nodes[B]!.mode(now: 60) == .idle, "no plan: the onboarding Mac keeps the claim: \(bus.leaders)")
        // The plan is adopted (rank 0 = A) on both Macs.
        for id in [A, B] { bus.nodes[id]!.rankOrder = [A, B] }
        for t in stride(from: 65.0, through: 80, by: 5) { bus.step(t) }
        expect(bus.leaders == [A] && bus.nodes[A]!.claim.term == 1, "plan adopted: rank 0 leads from term 1: \(bus.leaders)")
        expect(bus.nodes[A]!.mode(now: 80) == .cluster && bus.nodes[B]!.mode(now: 80) == .following(leaderID: A), "the pair runs under rank 0")
    }
    /// The planner's alone verdicts are for one plan. After a model change (a new plan SHA) a verdict recorded for the old
    /// plan must not let a survivor serve the new model alone, and a refused (stale) lease never rewrites the verdicts.
    static func aloneVerdictsBoundToThePlan() {
        typealias V = ClusterControlAloneVerdicts
        expect(V.holds(B, holders: [A, B], forPlan: "p1", savedPlan: "p1") == true, "verdict for the saved plan counts")
        expect(V.holds(B, holders: [A], forPlan: "p1", savedPlan: "p1") == false, "not a holder of the saved plan")
        expect(V.holds(B, holders: [A, B], forPlan: "p1", savedPlan: "p2") == nil, "verdict for another plan does not count")
        expect(V.holds(B, holders: [A, B], forPlan: nil, savedPlan: "p1") == nil, "verdict for no named plan does not count")
        expect(V.holds(B, holders: [A, B], forPlan: "p1", savedPlan: nil) == nil, "no saved plan: no verdict")
        let facts = [mac(A, "Apple M3 Ultra, 256 GB", 256, 80, alone: true), mac(B, "Apple M5 Ultra, 256 GB", 256, 80, alone: true)]
        expect(V.gated(facts, forPlan: "p1", savedPlan: "p1") == facts, "a lease's verdicts for the saved plan are kept")
        expect(V.gated(facts, forPlan: "p1", savedPlan: "p2").allSatisfy { $0.holdsModelAlone == nil }, "verdicts for another plan are dropped")
        expect(V.gated(facts, forPlan: "p1", savedPlan: "p2").map { $0.memoryBytes } == facts.map { $0.memoryBytes }, "the other facts stay")
        let accepted = ClusterControlNode.LeaseAnswer.accepted(facts[1])
        let refused = ClusterControlNode.LeaseAnswer.refused(.init(term: 3, leaderID: B, members: [A, B], reason: ""), facts[1])
        expect(V.toRecord(answer: accepted, facts: facts, forPlan: "p1", savedPlan: "p1").map { $0.holders == [A, B] && $0.plan == "p1" } == true,
               "an accepted lease's verdicts for the saved plan are recorded with the plan")
        expect(V.toRecord(answer: refused, facts: facts, forPlan: "p1", savedPlan: "p1") == nil, "a refused (stale) lease records nothing")
        expect(V.toRecord(answer: accepted, facts: facts, forPlan: "p0", savedPlan: "p1") == nil, "verdicts for another plan record nothing")
        // Failover after a model change whose verdicts B has not yet received: B states it cannot serve, runs nothing.
        let ownB = V.holds(B, holders: [A, B], forPlan: "old-plan", savedPlan: "new-plan")
        var bus = pair(aloneA: true, aloneB: true)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        var stale = bus.nodes[B]!.members[B]!
        stale.holdsModelAlone = ownB
        bus.nodes[B]!.learn(stale)
        bus.up.remove(A)
        for t in stride(from: 25.0, through: 60, by: 5) { bus.step(t) }
        guard case .cannotServe = bus.nodes[B]!.mode(now: 60) else {
            return expect(false, "a verdict for an older plan never serves the new model alone: \(bus.nodes[B]!.mode(now: 60))")
        }
        expect(true, "")
    }
    /// A Mac re-paired with ANOTHER Mac (a replaced Mac) still has the old pairing's control record. It must not carry
    /// that leadership history into the new pair: the old claim names a member that is gone and not the new one, so the
    /// new member would never get a lease, and spurious take-overs (each a solo load) would follow. A new pairing starts
    /// at term 0 led by the Mac that drove its onboarding; a record of the same pair is kept.
    static func rePairedWithAnotherMac() {
        let C = "mac-cccccccccccc", oldB = "mac-0b0b0b0b0b0b"
        let old = ClusterControlRecord(claim: .init(term: 5, leaderID: oldB, members: [A, oldB], reason: "rank 0 of the old plan"),
                                       members: [mac(A, "Apple M3 Ultra, 256 GB", 256, 80), mac(oldB, "Apple M5 Max, 128 GB", 128, 40)],
                                       rankOrder: [oldB, A])
        let fresh = ClusterControlRestart.start(persisted: old, localID: A, peerID: C, onboardingLeaderID: C)
        expect(fresh.claim.term == 0 && fresh.claim.leaderID == C && Set(fresh.claim.members) == [A, C],
               "another peer: a new history at term 0 led by the onboarding Mac: \(fresh.claim)")
        expect(!fresh.members.contains { $0.memberID == oldB }, "the gone Mac's facts are not carried over")
        let same = ClusterControlRestart.start(persisted: old, localID: A, peerID: oldB, onboardingLeaderID: A)
        expect(same.claim == old.claim, "the same pair re-forms from its record: \(same.claim)")
        let none = ClusterControlRestart.start(persisted: nil, localID: A, peerID: C, onboardingLeaderID: C)
        expect(none.claim.term == 0 && none.claim.leaderID == C, "no record: the onboarding Mac leads at term 0")
        // The new pair (A re-paired, C fresh, C drove the onboarding, plan rank 0 = A) forms with no take-over.
        let members = [mac(A, "Apple M3 Ultra, 256 GB", 256, 80, alone: true), mac(C, "Apple M5 Ultra, 256 GB", 256, 80, alone: true)]
        let startC = ClusterControlRestart.start(persisted: nil, localID: C, peerID: A, onboardingLeaderID: C)
        var bus = Bus(nodes: [A: ClusterControlNode(localID: A, members: members, claim: fresh.claim, rankOrder: [A, C], now: 0, ttl: 30),
                              C: ClusterControlNode(localID: C, members: members, claim: startC.claim, rankOrder: [A, C], now: 0, ttl: 30)],
                      up: [A, C])
        for t in stride(from: 0.0, through: 120, by: 5) { bus.step(t) }
        expect(!bus.log.contains { $0.contains("took over") }, "no take-over while both answer: \(bus.log)")
        expect(bus.leaders == [A] && bus.nodes[A]!.mode(now: 120) == .cluster, "rank 0 leads the new pair: \(bus.leaders)")
    }

    // MARK: - Finish (2026-10-13 night): confirmation before acting, solo after the absence grace, continuous clock

    /// (a) A Mac restarted from a persisted leader claim acts as the leader (a model change, a setup write, a stop) only
    /// once the members confirmed its claim, or once the confirmation window (one time-to-live) passed with no member
    /// reachable. A claim superseded while it was away is refused and it steps down having acted on nothing.
    static func restartedLeaderActsOnlyWhenConfirmed() {
        let members = [mac(A, "Apple M3 Ultra, 256 GB", 256, 80, alone: true), mac(B, "Apple M5 Ultra, 256 GB", 256, 80, alone: true)]
        let term1 = ClusterControlClaim(term: 1, leaderID: A, members: [A, B], reason: "rank 0 of the adopted plan")
        // Superseded while away: B leads term 2; A restarts believing it leads term 1.
        var a = ClusterControlNode(localID: A, members: members, claim: term1, rankOrder: [A, B], now: 0, ttl: 30)
        var b = ClusterControlNode(localID: B, members: members, claim: .init(term: 2, leaderID: B, members: [A, B], reason: "failover"),
                                   rankOrder: [A, B], now: 0, ttl: 30)
        expect(a.leads && !a.leadershipConfirmed(now: 0) && !a.leadershipConfirmed(now: 29), "a restarted leader is unconfirmed before any answer")
        let (refused, _) = b.receiveLease(from: A, offered: term1, running: false, facts: members, now: 1)
        _ = a.receiveAnswer(from: B, sent: term1, answer: refused, now: 1)
        expect(!a.leads && !a.leadershipConfirmed(now: 1) && !a.leadershipConfirmed(now: 100), "refused: it steps down, never confirmed")
        // Its claim is still current: confirmed once the member accepts it, not before.
        var a2 = ClusterControlNode(localID: A, members: members, claim: term1, rankOrder: [A, B], now: 0, ttl: 30)
        var b1 = ClusterControlNode(localID: B, members: members, claim: term1, rankOrder: [A, B], now: 0, ttl: 30)
        expect(!a2.leadershipConfirmed(now: 2), "not before the member answered")
        let (accepted, _) = b1.receiveLease(from: A, offered: term1, running: false, facts: members, now: 2)
        _ = a2.receiveAnswer(from: B, sent: term1, answer: accepted, now: 2)
        expect(a2.leadershipConfirmed(now: 2), "confirmed by the member")
        // Nobody reachable: it may act only once the window passed (the member's time-to-live from the start).
        var a3 = ClusterControlNode(localID: A, members: members, claim: term1, rankOrder: [A, B], now: 100, ttl: 30)
        // Ticked at the service's cadence (a tick gap of a third of the time-to-live or more reads as a wake).
        for t in stride(from: 110.0, through: 129, by: 1) { _ = a3.tick(now: t) }
        expect(!a3.leadershipConfirmed(now: 129.5), "inside the window with nobody answering: not yet")
        _ = a3.tick(now: 130)
        expect(a3.leadershipConfirmed(now: 130), "the window passed with no member reachable")
        // A follower is never a confirmed leader; before a plan (onboarding, term 0) the same rule holds.
        expect(!b1.leadershipConfirmed(now: 500), "a follower never acts as the leader")
        let onboarding = ClusterControlClaim(term: 0, leaderID: B, members: [A, B], reason: "drove the onboarding")
        var drive = ClusterControlNode(localID: B, members: members, claim: onboarding, rankOrder: nil, now: 0, ttl: 30)
        var other = ClusterControlNode(localID: A, members: members, claim: onboarding, rankOrder: nil, now: 0, ttl: 30)
        expect(!drive.leadershipConfirmed(now: 1), "term 0: not before the other Mac answered")
        let (yes, _) = other.receiveLease(from: B, offered: onboarding, running: false, facts: members, now: 1)
        _ = drive.receiveAnswer(from: A, sent: onboarding, answer: yes, now: 1)
        expect(drive.leadershipConfirmed(now: 1), "term 0: confirmed by the other Mac")
    }

    /// (3) Owner decision 6: control fails over at lease expiry, but serving alone starts only after the absence grace
    /// (600 s by default); until then the leader keeps its part ready for the other Mac and says how long until solo.
    static func soloOnlyAfterTheAbsenceGrace() {
        var bus = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        bus.up.remove(B)   // the member's service stops; its last answer was at 20, absent from 50
        var modes = [Double: ClusterControlNode.Mode]()
        for t in stride(from: 21.0, through: 700, by: 1) { bus.step(t); modes[t] = bus.nodes[A]!.mode(now: t) }
        expect(bus.leaders == [A], "rank 0 keeps leading")
        expect(modes[49] == .cluster, "inside the member's time-to-live: still the cluster: \(String(describing: modes[49]))")
        expect(modes[60] == .waiting(missing: [B], soloInSeconds: 590, canServeAlone: true), "waits, with the time until solo: \(String(describing: modes[60]))")
        expect(modes[649] == .waiting(missing: [B], soloInSeconds: 1, canServeAlone: true), "one second before the grace ends: \(String(describing: modes[649]))")
        expect(modes[650] == .alone(missing: [B]), "serving alone exactly when the grace ends: \(String(describing: modes[650]))")
        let line = ClusterControlWords.line(modes[60]!, names: [B: "Apple M5 Ultra, 256 GB"], model: "m")
        expect(line.contains("Apple M5 Ultra, 256 GB") && line.contains("alone in 9 min 50 s"), "status says how long until solo: \(line)")
        let cannot = ClusterControlWords.line(.waiting(missing: [B], soloInSeconds: 45, canServeAlone: false), names: [:], model: "m")
        expect(cannot.contains("cannot hold") && cannot.contains("45 s"), "words when it cannot serve alone: \(cannot)")
        // The member returns before the grace (its service restarts from its saved claim): the pair re-forms, nobody went solo.
        var back = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { back.step(t) }
        back.up.remove(B)
        for t in stride(from: 21.0, through: 299, by: 1) { back.step(t) }
        let saved = back.nodes[B]!.persisted
        back.nodes[B] = ClusterControlNode(localID: B, members: saved.members, claim: saved.claim, rankOrder: saved.rankOrder, now: 300, ttl: 30, soloGrace: 600)
        back.up.insert(B)
        var wentAlone = false
        for t in stride(from: 300.0, through: 400, by: 1) {
            back.step(t)
            for id in [A, B] { if case .alone = back.nodes[id]!.mode(now: t) { wentAlone = true } }
        }
        expect(!wentAlone, "returned before the grace: nobody served alone")
        expect(back.leaders == [A] && back.nodes[A]!.mode(now: 400) == .cluster, "re-formed under rank 0: \(back.nodes[A]!.mode(now: 400))")
        expect(back.nodes[B]!.mode(now: 400) == .following(leaderID: A) && back.nodes[B]!.leaderRunsCluster, "the member follows the running cluster")
        // A member that cannot hold the model alone: waits the grace too, then states it and runs nothing.
        var weak = pair(aloneA: false, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { weak.step(t) }
        weak.up.remove(B)
        for t in stride(from: 21.0, through: 660, by: 1) { weak.step(t) }
        expect(weak.nodes[A]!.mode(now: 640) == .waiting(missing: [B], soloInSeconds: 10, canServeAlone: false), "waits: \(weak.nodes[A]!.mode(now: 640))")
        guard case .cannotServe = weak.nodes[A]!.mode(now: 660) else { return expect(false, "after the grace: cannot serve: \(weak.nodes[A]!.mode(now: 660))") }
    }

    /// (3) The leader's service stops: control moves to the survivor at lease expiry (30 s), the survivor waits the grace
    /// before serving alone, and a leader back before the grace re-forms the pair with nobody serving alone.
    static func leaderFaultWaitsForTheGraceThenReforms() {
        var bus = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        let stale = bus.nodes[A]!.persisted
        bus.up.remove(A)
        var tookOverAt: Double?
        var wentAlone = false
        for t in stride(from: 21.0, through: 199, by: 1) {
            bus.step(t)
            if tookOverAt == nil, bus.nodes[B]!.leads { tookOverAt = t }
            if case .alone = bus.nodes[B]!.mode(now: t) { wentAlone = true }
        }
        expect(tookOverAt == 50, "control fails over at lease expiry: \(String(describing: tookOverAt))")
        expect(bus.nodes[B]!.mode(now: 60) == .waiting(missing: [A], soloInSeconds: 590, canServeAlone: true), "then waits the grace: \(bus.nodes[B]!.mode(now: 60))")
        expect(!wentAlone, "no solo inside the grace")
        bus.nodes[A] = ClusterControlNode(localID: A, members: stale.members, claim: stale.claim, rankOrder: stale.rankOrder, now: 200, ttl: 30, soloGrace: 600)
        bus.up.insert(A)
        for t in stride(from: 200.0, through: 260, by: 1) {
            bus.step(t)
            for id in [A, B] { if case .alone = bus.nodes[id]!.mode(now: t) { wentAlone = true } }
        }
        expect(!wentAlone, "the leader came back before the grace: nobody served alone")
        expect(bus.leaders == [A] && bus.nodes[A]!.mode(now: 260) == .cluster, "re-formed under rank 0: \(bus.leaders)")
        // The leader never returns: the survivor serves alone once the grace ends (it noticed the absence at 50).
        var gone = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { gone.step(t) }
        gone.up.remove(A)
        for t in stride(from: 21.0, through: 650, by: 1) { gone.step(t) }
        expect(gone.nodes[B]!.mode(now: 649) == .waiting(missing: [A], soloInSeconds: 1, canServeAlone: true), "\(gone.nodes[B]!.mode(now: 649))")
        expect(gone.nodes[B]!.mode(now: 650) == .alone(missing: [A]), "solo after the grace: \(gone.nodes[B]!.mode(now: 650))")
    }

    /// (3) The grace is universal (no model, chip or member input) and only a developer (DEBUG) build may shorten it.
    static func soloGraceSetting() {
        typealias G = ClusterControlSoloGrace
        expect(ClusterControlNode.defaultSoloGraceSeconds == 600, "owner decision 6: 10 minutes")
        expect(G.seconds(environment: [:], debugBuild: true) == 600, "no override: 600 s")
        expect(G.seconds(environment: [G.environmentKey: "45"], debugBuild: true) == 45, "developer override")
        expect(G.seconds(environment: [G.environmentKey: "45"], debugBuild: false) == 600, "a release build ignores the override")
        for bad in ["-1", "abc", "nan", "100000", ""] {
            expect(G.seconds(environment: [G.environmentKey: bad], debugBuild: true) == 600, "invalid override \(bad) ignored")
        }
    }

    /// What this Mac runs for each mode, and whether the leader's lease tells members the cluster runs.
    static func partChoice() {
        typealias P = ClusterControlPartChoice
        let waiting = ClusterControlNode.Mode.waiting(missing: [B], soloInSeconds: 100, canServeAlone: true)
        expect(P.want(mode: waiting, serving: true, hasSetup: true, leaderRunsCluster: false, runningSolo: false, model: "m") == .cluster,
               "waiting: keep this Mac's part ready so the pair re-forms")
        expect(P.want(mode: waiting, serving: true, hasSetup: true, leaderRunsCluster: false, runningSolo: true, model: "m") == .keep,
               "waiting while already alone (a member flapped): the solo server stays")
        expect(P.want(mode: .alone(missing: [B]), serving: true, hasSetup: true, leaderRunsCluster: false, runningSolo: false, model: "m") == .solo("m"), "alone: solo")
        expect(P.want(mode: .alone(missing: [B]), serving: false, hasSetup: true, leaderRunsCluster: false, runningSolo: false, model: "m") == .none, "stopped: nothing")
        expect(P.want(mode: .confirming, serving: true, hasSetup: true, leaderRunsCluster: false, runningSolo: false, model: "m") == .keep, "confirming: keep")
        expect(P.want(mode: .following(leaderID: A), serving: true, hasSetup: true, leaderRunsCluster: true, runningSolo: false, model: "m") == .cluster, "following a running cluster")
        expect(P.want(mode: .following(leaderID: A), serving: true, hasSetup: true, leaderRunsCluster: false, runningSolo: false, model: "m") == .none, "following a stopped cluster")
        expect(P.want(mode: .cannotServe(missing: [B], reason: "x"), serving: true, hasSetup: true, leaderRunsCluster: false, runningSolo: false, model: "m") == .none, "cannot serve")
        expect(P.want(mode: .cluster, serving: true, hasSetup: false, leaderRunsCluster: false, runningSolo: false, model: "m") == .none, "no setup")
        expect(P.leaseSaysRunning(mode: waiting, serving: true) && P.leaseSaysRunning(mode: .cluster, serving: true), "waiting and cluster: members keep their parts")
        expect(!P.leaseSaysRunning(mode: .confirming, serving: true) && !P.leaseSaysRunning(mode: .alone(missing: [B]), serving: true)
               && !P.leaseSaysRunning(mode: .cluster, serving: false), "otherwise members run nothing")
    }

    /// (c) The control clock keeps counting through system sleep; a woken leader does not count a member that went away
    /// while it slept as present, and a woken member gives its leader one time-to-live awake before it takes over.
    static func continuousClockAndWake() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let continuous = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        let clock = ClusterControlClock.seconds()
        expect(abs(clock - continuous) < 0.05, "the control clock is the continuous clock: \(clock) vs \(continuous)")
        let uptime = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
        expect(clock >= uptime - 0.05, "never behind uptime (ahead by the time this Mac slept): \(clock) vs \(uptime)")
        // The leader sleeps from 20 to 3620; its member went away meanwhile.
        var bus = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        bus.up.remove(B)
        bus.step(3620)
        expect(!bus.nodes[A]!.present(now: 3620).contains(B), "woken: the gone member is not present")
        expect(bus.nodes[A]!.mode(now: 3620) == .waiting(missing: [B], soloInSeconds: 600, canServeAlone: true),
               "woken: not the cluster; solo only after a full grace from the wake: \(bus.nodes[A]!.mode(now: 3620))")
        // Both slept; the member wakes 11 s before the leader: no take-over, the leader renews and the cluster runs on.
        var both = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { both.step(t) }
        both.up.remove(A)
        for t in stride(from: 3620.0, through: 3630, by: 1) { both.step(t) }
        both.up.insert(A)
        for t in stride(from: 3631.0, through: 3700, by: 1) { both.step(t) }
        expect(!both.log.contains { $0.contains("took over") }, "no take-over right after a wake: \(both.log)")
        expect(both.leaders == [A] && both.nodes[A]!.mode(now: 3700) == .cluster, "the pair runs on: \(both.nodes[A]!.mode(now: 3700))")
        // The leader is really gone at the wake: passed over one time-to-live after the wake.
        var gone = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { gone.step(t) }
        gone.up.remove(A)
        var at: Double?
        for t in stride(from: 3620.0, through: 3700, by: 1) { gone.step(t); if at == nil, gone.nodes[B]!.leads { at = t } }
        expect(at == 3650, "take-over one time-to-live after the wake: \(String(describing: at))")
    }

    /// The service log says a mode when it changes; inside the grace the countdown changes every second, so the log
    /// line is repeated only when the whole minutes until solo change (about ten lines for the 10-minute grace).
    static func waitingLogsOncePerMinute() {
        func key(_ seconds: Int) -> String {
            let mode = ClusterControlNode.Mode.waiting(missing: [B], soloInSeconds: seconds, canServeAlone: true)
            return ClusterControlWords.logKey(mode, line: ClusterControlWords.line(mode, names: [:], model: "m"))
        }
        let keys = Set((1...600).map(key))
        expect(keys.count == 11, "one log line per whole minute of the grace (0-10 min buckets): \(keys.count)")
        expect(key(599) == key(540) && key(539) != key(540), "same minute, same key")
        expect(ClusterControlWords.logKey(.cluster, line: "leading the cluster") == "leading the cluster", "other modes: the line itself")
    }

    // MARK: - Review of the finish (2026-10-13 night)

    /// (a)+(c) A leader that slept (or whose process was suspended) past the lease, while its member took over, is NOT a
    /// confirmed leader when it wakes: the confirmations it had before the sleep are void, and a member it has not heard
    /// from counts as unreachable only after one time-to-live AWAKE. Before the review it acted at once on its stale claim
    /// (the member it confirmed before the sleep still counted as confirmed).
    static func wokenLeaderReconfirms() {
        var bus = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        expect(bus.nodes[A]!.leadershipConfirmed(now: 20), "confirmed before the sleep")
        // A sleeps from 20 to 3620 (the continuous clock counts through it); B takes over meanwhile.
        bus.up.remove(A)
        for t in stride(from: 21.0, through: 300, by: 1) { bus.step(t) }
        expect(bus.leaders == [B] && bus.nodes[B]!.claim.term == 1, "B took over (term 1): \(bus.leaders)")
        // Woken, before its first tick and before the member's refusal came back: not confirmed.
        var woken = bus.nodes[A]!
        expect(woken.leads && !woken.leadershipConfirmed(now: 3620), "woken, not ticked yet: never a confirmed leader")
        _ = woken.tick(now: 3620)
        expect(!woken.leadershipConfirmed(now: 3620.5), "woken and ticked, nobody answered yet: not confirmed")
        // The renewal reaches B, B refuses with term 2: A steps down having acted on nothing.
        bus.up.insert(A)
        bus.step(3620)
        expect(!bus.nodes[A]!.leads && !bus.nodes[A]!.leadershipConfirmed(now: 3621), "the stale claim steps down")
        // Woken with the cable out (nobody can answer): it may act only after one time-to-live awake.
        var cut = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { cut.step(t) }
        cut.up.remove(A)
        for t in stride(from: 21.0, through: 300, by: 1) { cut.step(t) }
        cut.up.insert(A); cut.cut = [A]
        var confirmedAt: Double?
        for t in stride(from: 3620.0, through: 3700, by: 1) {
            cut.step(t)
            if confirmedAt == nil, cut.nodes[A]!.leadershipConfirmed(now: t) { confirmedAt = t }
        }
        expect(confirmedAt == 3650, "the window passed awake with nobody reachable: \(String(describing: confirmedAt))")
        // A short stall (15 s, inside the member's time-to-live, nobody could take over): nothing changes, the cluster
        // keeps running (the lease keeps saying so) and the leader stays confirmed.
        var short = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { short.step(t) }
        var stalled = short.nodes[A]!
        _ = stalled.tick(now: 35)
        expect(stalled.mode(now: 35) == .cluster && stalled.leadershipConfirmed(now: 35), "a short stall: still the confirmed cluster: \(stalled.mode(now: 35))")
    }

    /// (3)+(c) A Mac already inside the absence grace that sleeps past its end does not serve alone the moment it wakes:
    /// the missing member may have come back while it slept, so it gets one time-to-live awake to answer first. Before
    /// the review the woken Mac started its solo server at once and stopped it again when the member answered (a flap).
    static func wokenMacGivesMembersATimeToLiveBeforeSolo() {
        var bus = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        bus.up.remove(B)
        for t in stride(from: 21.0, through: 300, by: 1) { bus.step(t) }
        guard case .waiting = bus.nodes[A]!.mode(now: 300) else { return expect(false, "A waits the grace: \(bus.nodes[A]!.mode(now: 300))") }
        // A sleeps from 300 to 3600. B's service restarts at 3000 from its saved claim; A cannot answer, so B takes over.
        bus.up.remove(A)
        let saved = bus.nodes[B]!.persisted
        bus.nodes[B] = ClusterControlNode(localID: B, members: saved.members, claim: saved.claim, rankOrder: saved.rankOrder, now: 3000, ttl: 30, soloGrace: 600)
        bus.up.insert(B)
        for t in stride(from: 3000.0, through: 3599, by: 1) { bus.step(t) }
        expect(bus.nodes[B]!.leads, "B took over while A slept")
        // A wakes at 3600: its absence record of B is from before the sleep (more than the grace ago).
        let woken = bus.nodes[A]!
        if case .alone = woken.mode(now: 3600) { expect(false, "woken, not ticked yet: no solo at once") }
        bus.up.insert(A)
        var aloneAt = [Double]()
        for t in stride(from: 3600.0, through: 3700, by: 1) {
            bus.step(t)
            for id in [A, B] { if case .alone = bus.nodes[id]!.mode(now: t) { aloneAt.append(t) } }
        }
        expect(aloneAt.isEmpty, "nobody served alone around the wake: \(aloneAt.prefix(3))")
        expect(bus.leaders == [A] && bus.nodes[A]!.mode(now: 3700) == .cluster, "re-formed under rank 0: \(bus.leaders) \(bus.nodes[A]!.mode(now: 3700))")
        // The member is really gone at the wake: solo one time-to-live after it (not at once, not a whole new grace).
        var gone = pair(aloneA: true, aloneB: true, grace: 600)
        for t in stride(from: 0.0, through: 20, by: 5) { gone.step(t) }
        gone.up.remove(B)
        for t in stride(from: 21.0, through: 300, by: 1) { gone.step(t) }
        var soloAt: Double?
        for t in stride(from: 3600.0, through: 3700, by: 1) {
            gone.step(t)
            if soloAt == nil, case .alone = gone.nodes[A]!.mode(now: t) { soloAt = t }
        }
        expect(soloAt == 3630, "solo one time-to-live after the wake: \(String(describing: soloAt))")
    }

    /// A stop (or a start) typed on the survivor while the plan's rank 0 is away must survive rank 0's return: control is
    /// handed back to rank 0, which then leads with ITS record's serving intent. The leader's intent now travels with
    /// every lease and hand-over, and a Mac records it from an accepted lease of its current leader. Before the review
    /// the returning rank 0 led with the intent it had before it went away, restarted the cluster and synced `serve` to
    /// the survivor: the user's stop was lost (the screen had promised the other Mac would be told to stop).
    static func leaderIntentSurvivesTheHandOver() {
        var bus = pair(aloneA: true, aloneB: true, grace: 600)
        bus.serving = [A: true, B: true]
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        let stale = bus.nodes[A]!.persisted
        bus.up.remove(A)
        for t in stride(from: 21.0, through: 99, by: 1) { bus.step(t) }
        expect(bus.leaders == [B], "B took over")
        bus.serving[B] = false                       // `s` on B: A is away and cannot be told
        bus.nodes[A] = ClusterControlNode(localID: A, members: stale.members, claim: stale.claim, rankOrder: stale.rankOrder, now: 200, ttl: 30, soloGrace: 600)
        bus.up.insert(A)                             // A's record still says serving
        for t in stride(from: 200.0, through: 260, by: 1) { bus.step(t) }
        expect(bus.leaders == [A], "control back on rank 0: \(bus.leaders)")
        expect(bus.serving[A] == false && bus.serving[B] == false, "the stop survived the hand-over: \(bus.serving)")
        // The same for a start typed on the survivor while rank 0 was away and stopped.
        var start = pair(aloneA: true, aloneB: true, grace: 600)
        start.serving = [A: false, B: false]
        for t in stride(from: 0.0, through: 20, by: 5) { start.step(t) }
        let old = start.nodes[A]!.persisted
        start.up.remove(A)
        for t in stride(from: 21.0, through: 99, by: 1) { start.step(t) }
        start.serving[B] = true
        start.nodes[A] = ClusterControlNode(localID: A, members: old.members, claim: old.claim, rankOrder: old.rankOrder, now: 200, ttl: 30, soloGrace: 600)
        start.up.insert(A)
        for t in stride(from: 200.0, through: 260, by: 1) { start.step(t) }
        expect(start.leaders == [A] && start.serving[A] == true, "the start survived the hand-over: \(start.serving)")
        // A stale leader's intent is never recorded (its lease is refused), and a lease without one changes nothing.
        let members = [mac(A, "a", 256, 80), mac(B, "b", 256, 80)]
        expect(ClusterControlIntent.toRecord(answer: .refused(.init(term: 3, leaderID: B, members: [A, B], reason: "x"), members[1]),
                                             leaderServing: true, recorded: false) == nil, "refused: not recorded")
        expect(ClusterControlIntent.toRecord(answer: .accepted(members[1]), leaderServing: nil, recorded: false) == nil, "no intent sent")
        expect(ClusterControlIntent.toRecord(answer: .accepted(members[1]), leaderServing: false, recorded: false) == nil, "unchanged")
        expect(ClusterControlIntent.toRecord(answer: .accepted(members[1]), leaderServing: false, recorded: true) == false, "recorded")
    }

    /// After the grace the solo server starts at once: the restart backoff belongs to the part that kept ending (rank 0
    /// waiting for its missing follower), not to another part. In e3 solo waited 23 s for the cluster part's backoff.
    static func soloStartsWithoutTheEndedPartsBackoff() {
        typealias P = ClusterControlPartChoice
        expect(P.mayStart(key: "solo:m", endedKey: "cluster:abc", backoffElapsed: false), "another part: at once")
        expect(!P.mayStart(key: "cluster:abc", endedKey: "cluster:abc", backoffElapsed: false), "the part that ended: after its backoff")
        expect(P.mayStart(key: "cluster:abc", endedKey: "cluster:abc", backoffElapsed: true), "backoff elapsed")
        expect(!P.mayStart(key: "solo:m", endedKey: "solo:m", backoffElapsed: false), "a crashing solo server backs off too")
        expect(P.mayStart(key: "cluster:abc", endedKey: nil, backoffElapsed: false), "nothing ended: at once")
    }
    /// F14 (round 6b): a survivor that single-Mac Darkbloom would refuse for the model (the M3 Ultra for a model that needs
    /// an Apple M5 chip) never starts a solo server that ends at once and restarts every 30 s while the status says it
    /// serves alone: it says plainly that it cannot serve the model alone and waits for the other Mac. Synthetic
    /// capability names and Macs; no chip or model table.
    static func soloAdmissionChecksTheRuntimeRequirements() {
        typealias S = ClusterControlSoloAdmission
        expect(S.missingHardware(required: ["apple_m5", "mlx_nax"], hardwareSettled: ["apple_m5"], hardware: []) == ["apple_m5"],
               "the hardware settles the chip: refused before any start")
        expect(S.missingHardware(required: ["apple_m5", "mlx_nax"], hardwareSettled: ["apple_m5"], hardware: ["apple_m5"]).isEmpty,
               "a capability only the runtime's own probe settles is left to the solo server")
        expect(S.missingHardware(required: [], hardwareSettled: ["apple_m5"], hardware: []).isEmpty, "no requirement")
        let refused = S.decide(planned: true, missingHardware: ["apple_m5"], quickEnds: 0)
        expect(refused.holds == false && refused.refusal?.contains("an Apple M5 chip") == true,
               "the planner said it fits, single-Mac Darkbloom refuses it here: \(refused)")
        expect(S.decide(planned: true, missingHardware: [], quickEnds: 0) == .init(holds: true, refusal: nil), "fits and eligible")
        expect(S.decide(planned: nil, missingHardware: [], quickEnds: 0).holds == nil, "no verdict for the saved plan: unknown, never alone")
        expect(S.decide(planned: false, missingHardware: [], quickEnds: 0) == .init(holds: false, refusal: nil), "memory: the planner's verdict")
        let ended = S.decide(planned: true, missingHardware: [], quickEnds: S.maximumQuickEnds)
        expect(ended.holds == false && ended.refusal?.contains("ended") == true, "a solo server that keeps ending right after its start: \(ended)")
        expect(S.decide(planned: true, missingHardware: [], quickEnds: S.maximumQuickEnds - 1).holds == true, "below the limit: tried again")
        expect(S.quickEnds(after: 2, ranSeconds: 1) == 3 && S.quickEnds(after: 2, ranSeconds: S.quickEndSeconds) == 0,
               "an end soon after the start counts, a solo server that served a while clears the count")
        // In the node: rank 0 (A) survives, B's service stops; A cannot serve alone by its own check.
        var bus = pair(aloneA: true, aloneB: true, grace: 60)
        var own = bus.nodes[A]!.members[A]!
        own.holdsModelAlone = refused.holds; own.aloneRefusal = refused.refusal
        bus.nodes[A]!.learn(own)
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        bus.up.remove(B)
        for t in stride(from: 21.0, through: 200, by: 1) { bus.step(t) }
        let names = [B: "Apple M5 Ultra, 256 GB"]
        guard case .cannotServe(let missing, let reason) = bus.nodes[A]!.mode(now: 200) else {
            return expect(false, "after the grace: it cannot serve alone, never alone: \(bus.nodes[A]!.mode(now: 200))")
        }
        expect(missing == [B] && reason.contains("an Apple M5 chip"), "the reason is the refusal: \(reason)")
        let line = ClusterControlWords.line(bus.nodes[A]!.mode(now: 200), names: names, model: "m", aloneRefusal: own.aloneRefusal)
        expect(line.contains("cannot serve m alone") && line.contains("waits for Apple M5 Ultra, 256 GB") && !line.contains("degraded: serving"),
               "plain words, no claim of serving: \(line)")
        expect(ClusterControlPartChoice.want(mode: bus.nodes[A]!.mode(now: 200), serving: true, hasSetup: true, leaderRunsCluster: false,
                                             runningSolo: false, model: "m") == .none, "no solo server starts")
        let waiting = ClusterControlWords.line(.waiting(missing: [B], soloInSeconds: 45, canServeAlone: false), names: names, model: "m",
                                               aloneRefusal: own.aloneRefusal)
        expect(waiting.contains("cannot serve m alone") && waiting.contains("an Apple M5 chip") && waiting.contains("45 s"), "inside the grace: \(waiting)")
        // The fact travels in the lease answer, so the other Mac never prefers it as the Mac that holds the model alone.
        let data = try? JSONEncoder().encode(own)
        let back = data.flatMap { try? JSONDecoder().decode(ClusterControlMember.self, from: $0) }
        expect(back == own, "the refusal survives the wire")
        let older = try? JSONDecoder().decode(ClusterControlMember.self, from: Data(#"{"memberID":"mac-1","name":"x","memoryBytes":1,"gpuCores":1}"#.utf8))
        expect(older?.aloneRefusal == nil, "a fact from an older build decodes")
    }
}
