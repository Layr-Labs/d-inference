import Foundation
import Testing
@testable import ProviderCore

/// A pair served through Darkbloom can also run its leader's local API, with Darkbloom paused while the owner uses it
/// ("Both, me first", `darkbloom cluster`). The scope travels in the record and over the cable, only the part that
/// hosts the pair's slot gets the API, its port is never 8000 or 47420–47423, and nothing keys on two Macs.
@Suite("Cluster pair: Both, me first")
struct ClusterPairBothMeFirstTests {
    let both = ClusterServingScope.publicServingWithLocalAPI(bind: "0.0.0.0")
    let member = ["start", "--foreground", "--cluster-member", "--config", "/Users/me/.darkbloom/provider.toml"]

    // MARK: - The scope

    @Test func bothIsThroughDarkbloomWithALocalAPI() {
        #expect(!both.isLocalOnly && both.addsLocalAPI)
        // `bind` stays local only's, so nothing that reads it for `cluster local` changes.
        #expect(both.bind == nil && both.localAPIBind == "0.0.0.0")
        #expect(both.reachableFromNetwork)
        #expect(!ClusterServingScope.publicServingWithLocalAPI(bind: "127.0.0.1").reachableFromNetwork)
        let local = ClusterServingScope.localOnly(bind: "::1")
        #expect(local.isLocalOnly && !local.addsLocalAPI && local.bind == "::1" && local.localAPIBind == "::1")
        #expect(!ClusterServingScope.publicServing.addsLocalAPI && ClusterServingScope.publicServing.localAPIBind == nil)
    }

    @Test func theRecordKeepsBothAndAnOlderRecordReadsAsToday() throws {
        var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: "a", peerPin: "b", peerName: "B", since: "s")
        leadership.scope = both
        #expect(leadership.localOnly == nil && leadership.localAPI == true && leadership.localBind == "0.0.0.0")
        let read = try JSONDecoder().decode(ClusterOnboardingLeadership.self, from: JSONEncoder().encode(leadership))
        #expect(read.scope == both)
        // Back to the Darkbloom network leaves no field behind; local only keeps its own two.
        leadership.scope = .publicServing
        #expect(leadership.localOnly == nil && leadership.localAPI == nil && leadership.localBind == nil)
        leadership.scope = .localOnly(bind: "0.0.0.0")
        #expect(leadership.localOnly == true && leadership.localAPI == nil && leadership.localBind == "0.0.0.0")
        // A record from before this build has no `localAPI`: the Darkbloom network, as today.
        let older = #"{"role":"leader","leaderPin":"a","peerPin":"b","peerName":"B","since":"s","serving":true}"#
        #expect(try JSONDecoder().decode(ClusterOnboardingLeadership.self, from: Data(older.utf8)).scope == .publicServing)
        // A saved address the API does not take falls back to loopback, never wider; local only wins.
        #expect(ClusterServingScope(localOnly: nil, localAPI: true, bind: "0.0.0.0 --no-auth")
            == .publicServingWithLocalAPI(bind: "127.0.0.1"))
        #expect(ClusterServingScope(localOnly: nil, localAPI: true, bind: nil) == both)
        #expect(ClusterServingScope(localOnly: true, localAPI: true, bind: "::1") == .localOnly(bind: "::1"))
    }

    @Test func theScopeTravelsToTheOtherMacAndBackToTheLeader() throws {
        let serve = try JSONDecoder().decode(ClusterServiceCommand.self,
            from: JSONEncoder().encode(ClusterServiceCommand(op: .serve, model: "m", scope: both)))
        #expect(serve.scope == both)
        let forwarded = try JSONDecoder().decode(ClusterControlRequest.self,
            from: JSONEncoder().encode(ClusterControlRequest(op: .scope, scope: both)))
        #expect(forwarded.op == .scope && forwarded.scope == both)
        // An older leader's start says nothing of a local API: the Darkbloom network.
        let older = try JSONDecoder().decode(ClusterServiceCommand.self, from: Data(#"{"op":"serve","model":"m","localOnly":false}"#.utf8))
        #expect(older.scope == .publicServing)
        // An address the API does not take is not carried at all, as for local only.
        let tampered = try JSONDecoder().decode(ClusterServiceCommand.self,
            from: Data(#"{"op":"serve","localOnly":false,"localAPI":true,"bind":"0.0.0.0 --no-auth"}"#.utf8))
        #expect(tampered.scope == nil)
        // The other two travel as before.
        for scope in [ClusterServingScope.publicServing, .localOnly(bind: "0.0.0.0")] {
            let sent = try JSONDecoder().decode(ClusterServiceCommand.self,
                from: JSONEncoder().encode(ClusterServiceCommand(op: .serve, scope: scope)))
            #expect(sent.scope == scope && sent.localAPI == nil)
        }
        let status = try JSONDecoder().decode(ClusterServiceStatus.self,
            from: Data(#"{"serving":true,"sessionLeader":false,"child":{"running":true,"starts":1}}"#.utf8))
        #expect(status.localAPI == nil)
    }

    @Test func theLeaderStartsAMemberAgainWhoseRecordSaysAnotherWay() {
        func action(_ leader: Bool, _ member: Bool?) -> ClusterOnboardingSync.Action {
            ClusterOnboardingSync.action(leaderServing: true, leaderModel: "m", memberServing: true, memberModel: "m",
                                         leaderLocalOnly: false, memberLocalOnly: false,
                                         leaderLocalAPI: leader, memberLocalAPI: member)
        }
        #expect(action(true, false) == .serve("m"))
        #expect(action(false, true) == .serve("m"))
        #expect(action(true, true) == .none)
        // A member whose build doesn't report it: only the model and the start are compared, as for local only.
        #expect(action(true, nil) == .none)
    }

    // MARK: - The parts

    /// A three-Mac roster: ranks 0, 1 and 2. Only rank 0, which hosts the pair's slot, gets the local API.
    @Test func onlyThePartThatHostsThePairsSlotGetsTheLocalAPI() {
        for rank in 0...2 {
            let arguments = ClusterLocalServing.memberArguments(member, scope: both, localRank: rank, port: 8001)
            if rank == 0 {
                #expect(arguments == member + ["--local-endpoint", "--port", "8001", "--bind", "0.0.0.0"])
            } else {
                #expect(arguments == member, "rank \(rank) runs no local API")
            }
        }
        // The Darkbloom network and local only: every member's arguments are today's, byte for byte.
        for scope in [ClusterServingScope.publicServing, .localOnly(bind: "0.0.0.0")] {
            for rank in 0...2 {
                #expect(ClusterLocalServing.memberArguments(member, scope: scope, localRank: rank, port: 8001) == member)
            }
        }
    }

    /// `cluster local` and the not-offered leader keep their arguments: Both never skips the coordinator.
    @Test func clusterLocalAndTheLeadersOwnAPIAreUnchanged() {
        let leader = ["start", "--local", "--distributed"]
        #expect(ClusterLocalServing.leaderArguments(leader, scope: both) == leader)
        #expect(ClusterLocalServing.leaderArguments(leader, scope: .localOnly(bind: "0.0.0.0"))
            == leader + [ClusterLocalServing.noCoordinatorFlag, "--bind", "0.0.0.0"])
        #expect(ClusterLocalServing.soloArguments(["start", "--local"], scope: both) == ["start", "--local"])
        #expect(ClusterLocalServing.soloArguments(["start", "--local"], scope: .localOnly(bind: "::1")) == ["start", "--local", "--bind", "::1"])
    }

    @Test func switchingBetweenTheNetworkAndBothRestartsOnlyTheLeadingPart() {
        let sha = String(repeating: "a", count: 64)
        let publicKey = ClusterLocalServing.partKey(setupSHA256: sha, scope: .publicServing)
        let bothKey = ClusterLocalServing.partKey(setupSHA256: sha, scope: both)
        let localKey = ClusterLocalServing.partKey(setupSHA256: sha, scope: .localOnly(bind: "0.0.0.0"))
        #expect(publicKey == "cluster:" + sha, "a running public part would restart on upgrade")
        #expect(localKey == "cluster:" + sha + ":local-only@0.0.0.0", "cluster local's key changed")
        #expect(bothKey != publicKey && bothKey != localKey)
        #expect(ClusterLocalServing.scopeChangedOnly(from: publicKey, to: bothKey))
        #expect(ClusterLocalServing.scopeChangedOnly(from: bothKey, to: publicKey))
        #expect(ClusterLocalServing.scopeChangedOnly(from: bothKey, to: localKey))
        #expect(ClusterLocalServing.scopeChangedOnly(from: bothKey,
            to: ClusterLocalServing.partKey(setupSHA256: sha, scope: .publicServingWithLocalAPI(bind: "127.0.0.1"))))
        let other = ClusterLocalServing.partKey(setupSHA256: String(repeating: "b", count: 64), scope: both)
        #expect(!ClusterLocalServing.scopeChangedOnly(from: bothKey, to: other), "a new setup read as a scope change")
    }

    // MARK: - The port

    @Test func thePairsLocalAPIPortIsNever8000OrAPairPortAndIsFreeOnEveryMac() {
        let all = Array(ClusterLocalServing.servingPorts)
        #expect(ClusterLocalServing.localAPIPort(localFree: all, peersFree: [all, all]) == 8001)
        // Three Macs: the first port free on every one of them.
        #expect(ClusterLocalServing.localAPIPort(localFree: all, peersFree: [[8000, 8001, 8003, 8004], [8000, 8003, 8004]]) == 8003)
        // The port used last is kept while it is free on every Mac.
        #expect(ClusterLocalServing.localAPIPort(localFree: all, peersFree: [all, all], preferred: 8004) == 8004)
        // `cluster local`'s 8000 is never kept.
        #expect(ClusterLocalServing.localAPIPort(localFree: all, peersFree: [all], preferred: 8000) == 8001)
        // No port free on every Mac, or the other Macs don't say: this Mac's own first free one.
        #expect(ClusterLocalServing.localAPIPort(localFree: [8000, 8002, 8005], peersFree: [[8003], [8004]]) == 8002)
        #expect(ClusterLocalServing.localAPIPort(localFree: [8000, 8007], peersFree: nil) == 8007)
        // Nothing free here: the first port that may be chosen (its bind then fails and says so; Darkbloom keeps serving).
        #expect(ClusterLocalServing.localAPIPort(localFree: [], peersFree: nil) == 8001)
        for port in LocalSettings.neverChosenPorts.map(Int.init) {
            #expect(ClusterLocalServing.localAPIPort(localFree: [port], peersFree: [[port]], preferred: port) != port)
        }
        // The owner's rule, whatever build: 8000 and production's pair ports, plus this build's own pair ports.
        #expect(LocalSettings.neverChosenPorts.isSuperset(of: [8000, 47420, 47421, 47422, 47423]))
        #expect(ClusterLocalServing.pairPortsWords == "47420–47423")
        let cable = ClusterCablePorts.current
        #expect(LocalSettings.neverChosenPorts.isSuperset(of: [cable.linkControl, cable.pairing, cable.exchange, cable.control]))
    }

    /// This Mac's own free ports for the pair's API: 8000 and the pair ports are never even test-bound.
    @Test func theFreePortProbeNeverTouches8000() {
        var asked: [Int] = []
        let free = ClusterLocalServing.localAPIFreePorts { port in asked.append(port); return port != 8002 }
        #expect(!asked.contains(8000))
        #expect(asked.allSatisfy { !LocalSettings.neverChosenPorts.contains(UInt16($0)) })
        #expect(free.first == 8001 && !free.contains(8002) && !free.contains(8000))
        // `cluster local`'s own probe is unchanged: it still asks about 8000.
        var askedForClusterLocal: [Int] = []
        _ = ClusterLocalServing.freePorts { port in askedForClusterLocal.append(port); return true }
        #expect(askedForClusterLocal.first == 8000)
    }

    // MARK: - The choice

    @Test func theThreeAnswersAreThePairsThreeWaysToServe() {
        #expect(ClusterServingChoice.onlyMe.scope(keeping: .publicServing) == .localOnly(bind: "0.0.0.0"))
        #expect(ClusterServingChoice.network.scope(keeping: both) == .publicServing)
        #expect(ClusterServingChoice.bothMeFirst.scope(keeping: .publicServing) == both)
        // An address the person chose for the pair's API is kept.
        #expect(ClusterServingChoice.bothMeFirst.scope(keeping: .localOnly(bind: "127.0.0.1")) == .publicServingWithLocalAPI(bind: "127.0.0.1"))
        #expect(ClusterServingChoice.onlyMe.scope(keeping: .publicServingWithLocalAPI(bind: "::1")) == .localOnly(bind: "::1"))
        #expect(ClusterServingChoice(scope: both) == .bothMeFirst)
        #expect(ClusterServingChoice(scope: .localOnly(bind: "::1")) == .onlyMe)
        #expect(ClusterServingChoice(scope: .publicServing) == .network)
        // The answer is saved as `[local] mode`.
        #expect(ClusterServingChoice.allCases.map(\.rawValue) == LocalSettings.Mode.allCases.map(\.rawValue))
    }
}
