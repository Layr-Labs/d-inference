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
        // A Mac that does not lead refuses a forwarded command and names the leader it follows.
        let refusal = ClusterControlRouting.refusal(localID: "mac-aaaaaaaaaaaa", claim: claim, names: ["mac-bbbbbbbbbbbb": "Apple M5 Ultra, 256 GB"])
        expect(refusal?.contains("Apple M5 Ultra, 256 GB") == true, "refusal names the leader: \(String(describing: refusal))")
        expect(ClusterControlRouting.refusal(localID: "mac-bbbbbbbbbbbb", claim: claim, names: [:]) == nil, "the leader accepts")
    }

    // MARK: - A small bus of nodes

    struct Bus {
        var nodes: [String: ClusterControlNode]
        var up: Set<String>
        var cut: Set<String> = []   // nodes with their cable out (alive, unreachable)
        var log: [String] = []

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
            for action in actions { deliver(action, from: target, now: now, running: false) }
            for action in nodes[sender]!.receiveAnswer(from: target, sent: claim, answer: answer, now: now) {
                deliver(action, from: sender, now: now, running: false)
            }
        }

        var leaders: [String] { nodes.keys.sorted().filter { up.contains($0) && nodes[$0]!.leads } }
    }

    static func pair(aloneA: Bool, aloneB: Bool) -> Bus {
        // Rank 0 = A (M3 Ultra), rank 1 = B (M5 Ultra) decodes; B started the onboarding (it does not matter).
        let members = [mac("mac-aaaaaaaaaaaa", "Apple M3 Ultra, 256 GB", 256, 80, alone: aloneA),
                       mac("mac-bbbbbbbbbbbb", "Apple M5 Ultra, 256 GB", 256, 80, alone: aloneB)]
        let plan = ["mac-aaaaaaaaaaaa", "mac-bbbbbbbbbbbb"]
        var nodes = [String: ClusterControlNode]()
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30) }
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
        bus.nodes[A] = ClusterControlNode(localID: A, members: stale.members, claim: stale.claim, rankOrder: stale.rankOrder, now: 101, ttl: 30)
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
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30) }
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
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30) }
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
        for m in members { nodes[m.memberID] = ClusterControlNode(localID: m.memberID, members: members, claim: nil, rankOrder: plan, now: 0, ttl: 30) }
        var bus = Bus(nodes: nodes, up: Set(nodes.keys))
        for t in stride(from: 0.0, through: 20, by: 5) { bus.step(t) }
        expect(bus.leaders == ["mac-000000000001"] && bus.nodes["mac-000000000001"]!.mode(now: 20) == .cluster, "four form")
        bus.up.remove("mac-000000000004")
        for t in stride(from: 25.0, through: 60, by: 5) { bus.step(t) }
        guard case .cannotServe(let missing, let reason) = bus.nodes["mac-000000000001"]!.mode(now: 60) else {
            return expect(false, "three of four: stated, not served")
        }
        expect(missing == ["mac-000000000004"] && reason.contains("re-plan"), "\(missing) \(reason)")
        expect(bus.leaders == ["mac-000000000001"], "rank 0 keeps leading (it is present)")
    }

    static func startupGrace() {
        let members = [mac(A, "Apple M3 Ultra, 256 GB", 256, 80, alone: true), mac(B, "Apple M5 Ultra, 256 GB", 256, 80, alone: true)]
        var node = ClusterControlNode(localID: A, members: members, claim: nil, rankOrder: [A, B], now: 1000, ttl: 30)
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
}
