import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The lines and calls of one cluster gate run.
private final class GateRun: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    private(set) var asked = 0

    func say(_ line: String) { lock.withLock { said.append(line) } }
    func asking() { lock.withLock { asked += 1 } }
    var lines: [String] { lock.withLock { said } }
}

/// `darkbloom cluster`'s gate: a new pair needs an approved account; a Mac that holds a pairing is never asked.
@Suite("darkbloom cluster waitlist gate")
struct ClusterWaitlistGateTests {
    static func cluster(_ status: FeatureWaitlistPlace.Status, position: Int? = nil) -> FeatureWaitlistLookup {
        .success(FeatureWaitlistTests.place("cluster", "Clusters", status, position: position, start: "darkbloom cluster"))
    }

    /// The gate's exit code (0 when setup goes on), its lines (`!` before a warning) and the waitlist calls made.
    static func run(_ pair: ClusterPairSummary = .notPaired, _ place: FeatureWaitlistLookup,
                    joined: FeatureWaitlistLookup? = nil, answer: Bool = false,
                    request: ClusterOnboardingRequest = .init()) async -> (code: Int32, lines: [String], calls: [String]) {
        let run = GateRun()
        let access = FeatureWaitlistAccess(
            coordinator: "https://coordinator.invalid",
            waitlists: { run.say("call list"); return place.map { FeatureWaitlists(data: [$0]) } },
            place: { run.say("call GET \($0)"); return place },
            join: { run.say("call POST \($0)"); return joined ?? place })
        let gate = Cluster.Setup.clusterWaitlistGate(access: access)
        do {
            try await Cluster.Setup.requireNewPairApproval(pair: pair, request: request) {
                var built = gate()
                built.ask = { run.say("ask \($0)"); return answer }
                built.say = { run.say($0) }
                built.warn = { run.say("! " + $0) }
                return built
            }
            return (0, run.lines.filter { !$0.hasPrefix("call ") }, run.lines.filter { $0.hasPrefix("call ") })
        } catch let code as ExitCode {
            return (code.rawValue, run.lines.filter { !$0.hasPrefix("call ") }, run.lines.filter { $0.hasPrefix("call ") })
        } catch {
            return (-1, ["\(error)"], [])
        }
    }

    static let cli = ClusterPairSummary.cli
    static var localNote: String { "  To use the pair just for yourself, run `\(cli) cluster local` (no approval needed)." }

    @Test("a Mac that holds a pairing, or one it can't read, is never asked, whatever the waitlist says")
    func existingPairsUntouched() async {
        var unreadable = ClusterPairSummary(paired: true, state: .pairingUnreadable)
        unreadable.reason = "the keychain is locked"
        var serving = ClusterPairSummary(paired: true)
        serving.role = .leader
        serving.started = true
        for pair in [ClusterPairSummary(paired: true), serving, unreadable] {
            for place in [Self.cluster(.none), Self.cluster(.waitlisted), Self.cluster(.revoked),
                          .failure(.needsLogin), .failure(.refused("no")), .failure(.unavailable("offline"))] {
                let result = await Self.run(pair, place)
                #expect(result.code == 0 && result.lines.isEmpty && result.calls.isEmpty, "\(pair.state) \(place)")
            }
        }
    }

    @Test("`darkbloom cluster local` is never gated: no waitlist call, so it works offline and for any account")
    func localOnlyUngated() async {
        let local = ClusterOnboardingRequest(scope: .localOnly(bind: ClusterServingScope.localOnlyDefaultBind))
        for place in [Self.cluster(.none), Self.cluster(.waitlisted), Self.cluster(.revoked), .failure(.notOffered),
                      .failure(.needsLogin), .failure(.refused("no")), .failure(.unavailable("offline"))] {
            let result = await Self.run(.notPaired, place, request: local)
            #expect(result.code == 0 && result.lines.isEmpty && result.calls.isEmpty, "\(place)")
        }
        // Through Darkbloom, chosen on the screen or asked for, stays gated.
        let publicServing = ClusterOnboardingRequest(scope: .publicServing)
        #expect(await Self.run(.notPaired, Self.cluster(.waitlisted), request: publicServing).code == 1)
    }

    @Test("an approved account sets up a new pair; so does one an older coordinator (404) knows no waitlist for")
    func admits() async {
        let approved = await Self.run(.notPaired, Self.cluster(.approved))
        #expect(approved.code == 0 && approved.lines.isEmpty && approved.calls == ["call GET cluster"])
        var leftover = ClusterPairSummary.notPaired
        leftover.leftoverService = true
        #expect(await Self.run(leftover, Self.cluster(.approved)).calls == ["call GET cluster"])
        let older = await Self.run(.notPaired, .failure(.notOffered))
        #expect(older.code == 0)
        #expect(older.lines == ["https://coordinator.invalid has no Clusters waitlist; going on."])
    }

    @Test("a waitlisted or revoked account is told where it stands, and nothing is set up (exit 1)")
    func refusesUnapproved() async {
        let waitlisted = await Self.run(.notPaired, Self.cluster(.waitlisted, position: 4))
        #expect(waitlisted.code == 1)
        #expect(waitlisted.lines == [
            "You're on the Clusters waitlist: #4 in line.",
            "  Darkbloom reviews accounts in the order they joined and approves them by hand.",
            "  Check again: \(Self.cli) waitlist cluster",
            "  Nothing was set up. Run `\(Self.cli) cluster` again once Darkbloom approves your account.",
            Self.localNote,
        ])
        let revoked = await Self.run(.notPaired, Self.cluster(.revoked))
        #expect(revoked.code == 1 && revoked.calls == ["call GET cluster"])
        #expect(revoked.lines.first == "Darkbloom revoked your account's access to Clusters.")
        #expect(revoked.lines.last == Self.localNote)
    }

    @Test("an account not on the waitlist is offered to join: no joins nothing and names the command, yes joins")
    func offersToJoin() async {
        let declined = await Self.run(.notPaired, Self.cluster(.none), answer: false)
        #expect(declined.code == 1 && declined.calls == ["call GET cluster"])
        #expect(declined.lines == [
            "Clusters is open to the accounts Darkbloom approves from its waitlist.",
            "ask Join the Clusters waitlist now?",
            "  Join it: \(Self.cli) waitlist cluster",
            Self.localNote,
        ])
        let joined = await Self.run(.notPaired, Self.cluster(.none), joined: Self.cluster(.waitlisted, position: 9), answer: true)
        #expect(joined.code == 1 && joined.calls == ["call GET cluster", "call POST cluster"])
        #expect(joined.lines.contains("You're on the Clusters waitlist: #9 in line."))
        let approvedOnJoin = await Self.run(.notPaired, Self.cluster(.none), joined: Self.cluster(.approved), answer: true)
        #expect(approvedOnJoin.code == 0)
    }

    @Test("not logged in (401), refused (403) or no answer: the gate says why and what to do, and stops (exit 1)")
    func refusesWithoutAnswer() async {
        let login = await Self.run(.notPaired, .failure(.needsLogin))
        #expect(login.code == 1 && login.lines == ["! Link this Mac to your Darkbloom account first: \(Self.cli) login",
                                                   "! " + Self.localNote])
        let refused = await Self.run(.notPaired, .failure(.refused("this credential cannot read waitlists")))
        #expect(refused.code == 1 && refused.lines == [
            "! https://coordinator.invalid refused this account: HTTP 403: this credential cannot read waitlists",
            "!   Link this Mac to your Darkbloom account again: \(Self.cli) login",
            "! " + Self.localNote,
        ])
        let offline = await Self.run(.notPaired, .failure(.unavailable("no answer within 10 seconds")))
        #expect(offline.code == 1 && offline.lines == [
            "! Could not reach the Clusters waitlist at https://coordinator.invalid: no answer within 10 seconds",
            "!   Nothing was set up. Check this Mac's network and run `\(Self.cli) cluster` again.",
            "! " + Self.localNote,
        ])
    }

    @Test("the live gate asks the configured coordinator: GET /v1/waitlists/cluster with the login token")
    func liveRequest() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists/cluster": .json(200,
                #"{"feature":"cluster","title":"Clusters","status":"waitlisted","position":2}"#)])
            await exitWithCommandStatus {
                defer {
                    let request = CoordinatorStub.requests.first
                    print("request \(request?.httpMethod ?? "") \(request?.url?.absoluteString ?? "") "
                        + "\(request?.value(forHTTPHeaderField: "Authorization") ?? "none")")
                }
                try await Cluster.Setup.requireNewPairApproval(
                    request: .init(), gate: Cluster.Setup.clusterWaitlistGate(access: .live(configPath: sandbox.config.path)))
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasPrefix("You're on the Clusters waitlist: #2 in line.\n"))
        #expect(output.hasSuffix("request GET \(CLICommandSandbox.coordinatorURL)/v1/waitlists/cluster Bearer eigeninference-pt-waitlist\n"))
    }
}
