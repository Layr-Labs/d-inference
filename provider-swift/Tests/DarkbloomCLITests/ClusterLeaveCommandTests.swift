import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom cluster leave`: leaves a pair from either Mac in one command. It stops this Mac's part (the pair stops on
/// both Macs while the other Mac answers), forgets this Mac's pairing, and says what happens to the other Mac and how to
/// pair again. It asks first in a terminal, and refuses without one unless `--yes`. Every test stands in for the
/// terminal, the pair's services and the pairing store; nothing of this Mac's own cluster is read or changed.
@Suite("cluster leave")
struct ClusterLeaveCommandTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        func append(_ call: String) { lock.withLock { stored.append(call) } }
    }

    static var cli: String { BuildEnvironment.current.cliName }
    static let pin = String(repeating: "a1", count: 32)
    static let otherPin = String(repeating: "b2", count: 32)
    static let otherName = "Apple M3 Ultra, 256 GB"
    static var other: String { "The other Mac (\(otherName))" }

    static func paired(role: ClusterPairSummary.Role = .leader) -> ClusterPairSummary {
        var pair = ClusterPairSummary(paired: true)
        pair.role = role
        pair.otherMacName = otherName
        pair.modelName = "Qwen 3.8 27B"
        pair.started = true
        return pair
    }

    static let pairing = ProviderUninstallPairing(peers: [.init(pin: pin, name: otherName)], otherMacName: otherName,
                                                  role: .leader)

    private func flow(pair: ClusterPairSummary = paired(), pairing: ProviderUninstallPairing? = pairing,
                      terminal: Bool = true, yes: Bool = false, answer: String? = "y",
                      stopped: Result<Cluster.Stop.BeforeUnpairing, ClusterOnboardingFailure> = .success(.stopped(.stopped)),
                      forgetFails: Bool = false, soloServing: Bool = false) -> (ClusterLeaveFlow, Calls, Calls) {
        let calls = Calls(), lines = Calls()
        let flow = ClusterLeaveFlow(
            pair: pair, pairing: pairing, terminal: terminal, yes: yes,
            ask: { question in
                calls.append("ask")
                lines.append(question)
                return answer
            },
            stopPart: {
                calls.append("stop")
                return try stopped.get()
            },
            forget: { pin in
                calls.append("forget \(pin.prefix(4))")
                if forgetFails { throw ValidationError("pairings.json could not be written") }
            },
            soloServing: { soloServing },
            say: { lines.append($0) })
        return (flow, calls, lines)
    }

    /// A leave's last lines: this Mac's next steps (serve alone, or pair again), `other` (what the stop did to the other
    /// Mac, and how it leaves too), and how these two Macs pair again.
    static func lastLines(other: String, soloServing: Bool = false) -> [String] {
        ["✓ This Mac left the pair. " + (soloServing
            ? "Single-Mac serving keeps running on this Mac; `\(cli) cluster` pairs it again."
            : "Nothing serves on this Mac now: `\(cli) start` serves it alone, or `\(cli) cluster` pairs it again."),
         other,
         "To pair these two Macs again instead, run `\(cli) cluster` on each Mac; if the other Mac offers Start over, choose it."]
    }

    static var keepsItsPairing: String { " It keeps its pairing until you run `\(cli) cluster leave` there." }
    static var unansweredLine: String {
        "\(other) didn't answer, so it wasn't asked to stop; it may have left the pair already. If it hasn't, "
            + "`\(cli) cluster leave` there unpairs it too."
    }

    /// A whole leave through the real stop before unpairing (`Cluster.Stop.beforeUnpairing`, `finishStop`), whose pair
    /// stop gives `pairStop`; nil: nobody was asked, as on the Mac that follows a pair that isn't serving.
    static func leave(pairStop: Result<[String], ClusterOnboardingFailure>?, forwarded: Bool = false,
                      role: ClusterPairSummary.Role = .leader) async -> (code: Int32, text: String) {
        let lines = Calls()
        let flow = ClusterLeaveFlow(
            pair: paired(role: role), pairing: pairing, terminal: false, yes: true, ask: { _ in nil },
            stopPart: {
                try await Cluster.Stop.beforeUnpairing(hasService: true, say: { lines.append($0) }) { localOnly in
                    try Cluster.Stop.finishStop(localOnly ? nil : pairStop, localOnly: localOnly, forwarded: forwarded,
                                                leaving: true) { ["agent"] }
                }
            },
            forget: { _ in }, soloServing: { false }, say: { lines.append($0) })
        let code = await flow.run()
        return (code, lines.all.joined(separator: "\n"))
    }

    @Test func leaveParsesWithAndWithoutYes() throws {
        #expect(try Darkbloom.parseAsRoot(["cluster", "leave"]) is Cluster.Leave)
        #expect((try Darkbloom.parseAsRoot(["cluster", "leave", "--yes"]) as? Cluster.Leave)?.yes == true)
        #expect((try Darkbloom.parseAsRoot(["cluster", "leave", "-y"]) as? Cluster.Leave)?.yes == true)
        #expect(Cluster.commandList.contains("darkbloom cluster leave"))
    }

    @Test func aMacInNoPairHasNothingToLeave() async {
        let (flow, calls, lines) = flow(pair: .notPaired, pairing: nil)
        #expect(await flow.run() == 0)
        #expect(calls.all.isEmpty)
        #expect(lines.all.first == "This Mac isn't in a two-Mac cluster: nothing to leave.")
    }

    @Test func aPairingThatCantBeReadChangesNothing() async {
        let (flow, calls, lines) = flow(pair: ClusterPairSummary(paired: true, state: .pairingUnreadable), pairing: nil)
        #expect(await flow.run() == 1)
        #expect(calls.all.isEmpty)
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("nothing was changed"))
        #expect(text.contains("`\(Self.cli) cluster`"))
    }

    @Test func withoutATerminalItLeavesOnlyWithYes() async {
        let (refused, refusedCalls, refusedLines) = flow(terminal: false, yes: false)
        #expect(await refused.run() == 1)
        #expect(refusedCalls.all.isEmpty)
        #expect(refusedLines.all.joined().contains("--yes"))

        let (scripted, calls, _) = flow(terminal: false, yes: true)
        #expect(await scripted.run() == 0)
        #expect(calls.all == ["stop", "forget a1a1"])
    }

    @Test(arguments: [String?.none, "", "n", "no", "maybe"])
    func inATerminalNoIsTheDefault(_ answer: String?) async {
        let (flow, calls, lines) = flow(answer: answer)
        #expect(await flow.run() == 0)
        #expect(calls.all == ["ask"])
        #expect(lines.all.last == "Nothing changed.")
    }

    @Test func itSaysWhatLeavingDoesBeforeItAsks() async {
        let (flow, _, lines) = flow(answer: "n")
        _ = await flow.run()
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("This Mac serves in a two-Mac cluster with the other Mac (\(Self.otherName))"))
        #expect(text.contains("stops the pair"))
        #expect(text.contains("forgets this Mac's pairing"))
        #expect(text.contains("Leave the pair? [y/N] "))
    }

    /// The command's own wiring (`Cluster.Leave.flow`), the one place --yes and the terminal reach the flow: without
    /// --yes it asks first in a terminal and refuses without one; with --yes it leaves without asking. The base flow
    /// would leave at once (--yes, a terminal, a Yes), so only the command decides.
    @Test func theCommandNeverLeavesWithoutAskingUnlessYes() async throws {
        let plain = try #require(try Darkbloom.parseAsRoot(["cluster", "leave"]) as? Cluster.Leave)
        let scripted = try #require(try Darkbloom.parseAsRoot(["cluster", "leave", "--yes"]) as? Cluster.Leave)
        func wired(_ command: Cluster.Leave, terminal: Bool, answer: String?) async -> (code: Int32, calls: [String]) {
            let (base, calls, _) = flow(terminal: true, yes: true, answer: answer)
            let leave = ClusterPairCommands.$terminalForTesting.withValue(terminal) { command.flow(base) }
            let code = await leave.run()
            return (code, calls.all)
        }
        let noTerminal = await wired(plain, terminal: false, answer: "y")
        #expect(noTerminal.code == 1 && noTerminal.calls.isEmpty, "no terminal and no --yes: refused, nothing changed")
        let no = await wired(plain, terminal: true, answer: "n")
        #expect(no.code == 0 && no.calls == ["ask"])
        let yes = await wired(plain, terminal: true, answer: "y")
        #expect(yes.code == 0 && yes.calls == ["ask", "stop", "forget a1a1"])
        let script = await wired(scripted, terminal: false, answer: nil)
        #expect(script.code == 0 && script.calls == ["stop", "forget a1a1"])
    }

    /// The flow made for the command, before `Cluster.Leave.flow` wires it: it refuses, and its stop is the stop before
    /// unpairing, as a Mac that leaves.
    @Test func theLiveFlowRefusesUntilWiredAndStopsAsALeavingMac() async throws {
        let live = ClusterLeaveFlow.live(pair: Self.paired(), pairing: Self.pairing)
        #expect(!live.yes && !live.terminal)
        let seen = Calls()
        let service = Cluster.Stop.ServiceForTesting(installed: true) { localOnly, leaving in
            seen.append("localOnly \(localOnly), leaving \(leaving)")
            return .init(lines: [], otherMac: .stopped)
        }
        let stopped = try await Cluster.Stop.$serviceForTesting.withValue(service) { try await live.stopPart() }
        #expect(stopped == .stopped(.stopped))
        #expect(seen.all == ["localOnly false, leaving true"])
    }

    @Test func yesStopsThisMacsPartThenForgetsThePairing() async {
        let (flow, calls, lines) = flow(answer: "yes")
        #expect(await flow.run() == 0)
        #expect(calls.all == ["ask", "stop", "forget a1a1"])
        #expect(Array(lines.all.suffix(3)) == Self.lastLines(other: "\(Self.other) stopped serving the pair too." + Self.keepsItsPairing))
        let text = lines.all.joined(separator: "\n")
        #expect(!text.contains("tok/s") && !text.contains("dk-local-"))
    }

    @Test func fromTheMacThatFollowsItLeavesTheSameWay() async {
        let (flow, calls, lines) = flow(pair: Self.paired(role: .member), yes: true)
        #expect(await flow.run() == 0)
        #expect(calls.all == ["stop", "forget a1a1"])
        #expect(lines.all.joined(separator: "\n").contains("`\(Self.cli) cluster leave` there"))
    }

    /// What the stop did to the other Mac, as it happened: "stopped serving the pair too" only when it stopped, and
    /// never "wasn't reached" for a Mac that may have answered (this Mac's part was still releasing its memory). One
    /// that didn't answer may have left already, so it isn't said to keep its pairing.
    @Test func whatTheOtherMacWasAskedIsSaidAsItHappened() async {
        let notAsked = "\(Self.other) wasn't asked to stop." + Self.keepsItsPairing
        let cases: [(Cluster.Stop.BeforeUnpairing, String)] = [
            (.stopped(.stopped), "\(Self.other) stopped serving the pair too." + Self.keepsItsPairing),
            (.stopped(.unanswered("\(Self.other) did not answer (its cluster service did not answer on the cable)")),
             Self.unansweredLine),
            // The Mac that follows forwards the stop: the leading Mac's silence comes back as the stop's failure.
            (.stoppedAlone("\(Self.other) did not answer over the cable: timed out\nThe leading Mac didn't confirm the stop in "
                + "time; it may still be finishing."), Self.unansweredLine),
            (.stoppedAlone("This Mac's part has not finished releasing its memory, so the other Mac was not asked to stop yet."),
             notAsked),
            (.stopped(.notAsked), notAsked),
            (.noService, "\(Self.other) wasn't asked anything." + Self.keepsItsPairing),
        ]
        for (stopped, said) in cases {
            let (flow, _, lines) = flow(yes: true, stopped: .success(stopped))
            #expect(await flow.run() == 0)
            #expect(Array(lines.all.suffix(3)) == Self.lastLines(other: said), "\(stopped)")
            let text = lines.all.joined(separator: "\n")
            #expect(text.contains("stopped serving the pair too") == (stopped == .stopped(.stopped)), "\(stopped)")
            #expect(!text.contains("wasn't reached"), "\(stopped)")
        }
    }

    /// The leading Mac's pair stop when the other Mac doesn't answer (`ClusterOnboardingLive.localStop`'s
    /// `otherMacUnanswered`, which `finishStop` says without throwing): through the real stop, the leave says only that
    /// it didn't answer, and `uninstall`'s step says so too.
    @Test func theLeadingMacSaysOnlyThatTheOtherMacDidntAnswer() async throws {
        let unanswered = "\(Self.other) did not answer (its cluster service did not answer on the cable)"
        let stop = ClusterOnboardingFailure(["This Mac stopped serving; the other Mac did not answer."],
                                            otherMacUnanswered: unanswered)
        let (code, text) = await Self.leave(pairStop: .failure(stop))
        #expect(code == 0)
        #expect(text.contains(unanswered + ", so it was not asked to stop (its cluster service may already be off)."))
        #expect(text.contains(Self.unansweredLine))
        #expect(!text.contains("stopped serving the pair too"))
        let off = try Cluster.Stop.finishStop(.failure(stop), leaving: true) { ["agent"] }
        #expect(off.otherMac == .unanswered(unanswered))
        #expect(Cluster.Stop.BeforeUnpairing.stopped(off.otherMac).outcome
            == .done("the other Mac did not answer, so it was not asked to stop"))
    }

    /// The leading Mac's forget step when the other Mac isn't reached (`ClusterService.tellMemberOfUnpair`, which
    /// `cluster pair --forget` and `uninstall` print too): that Mac may have left the pair already, so the line says what
    /// to run there only if it is still paired, and names no pin.
    @Test func theForgetStepTellsAnUnreachedMacToLeaveOnlyIfStillPaired() {
        let line = ClusterService.memberNotReachedLine(reason: "timed out")
        #expect(line == "The other Mac was not reached (timed out). If that Mac is still paired, run "
            + "`\(ClusterPairSummary.cli) cluster leave` there.")
        #expect(!line.contains("--forget") && !line.contains("pair cache"))
    }

    /// The pair's stop ends "Run `darkbloom cluster` to serve again." (the leading Mac's own line, forwarded to the Mac
    /// that follows): while leaving, neither Mac's screen says it, and the leave's last lines say what's next.
    @Test func leavingNeverSaysToServeThePairAgain() async throws {
        let serveAgain = "Stopping both Macs. Run `\(ClusterPairSummary.cli) cluster` to serve again."
        for forwarded in [false, true] {
            let off = try Cluster.Stop.finishStop(.success([serveAgain]), forwarded: forwarded, leaving: true) { ["agent"] }
            #expect(off == .init(lines: ["This Mac's cluster service is stopped and will not start at login."],
                                 otherMac: .stopped), "forwarded \(forwarded)")
            let (code, text) = await Self.leave(pairStop: .success([serveAgain]), forwarded: forwarded)
            #expect(code == 0)
            #expect(!text.contains("to serve again") && !text.contains("to start it again"), "forwarded \(forwarded)")
            #expect(text.hasSuffix(Self.lastLines(other: "\(Self.other) stopped serving the pair too." + Self.keepsItsPairing)
                .joined(separator: "\n")))
        }
        // `cluster stop --service` keeps it: that pair can serve again.
        #expect(try Cluster.Stop.finishStop(.success([serveAgain])) { ["agent"] }.lines.first == serveAgain)
    }

    /// The Mac that follows a pair that isn't serving asks nobody (`pairStop` is `.stopHere`): it says the other Mac
    /// wasn't asked to stop, not that it stopped.
    @Test func theMacThatFollowsAPairThatIsntServingSaysTheOtherMacWasntAsked() async {
        #expect(Cluster.Stop.pairStop(role: .member, serving: false) == .stopHere)
        let (code, text) = await Self.leave(pairStop: nil, role: .member)
        #expect(code == 0)
        #expect(text.contains("\(Self.other) wasn't asked to stop." + Self.keepsItsPairing))
        #expect(!text.contains("stopped serving the pair too"))
    }

    @Test func singleMacServingOnThisMacKeepsRunning() async {
        let (flow, _, lines) = flow(yes: true, soloServing: true)
        #expect(await flow.run() == 0)
        #expect(Array(lines.all.suffix(3)) == Self.lastLines(other: "\(Self.other) stopped serving the pair too." + Self.keepsItsPairing,
                                                             soloServing: true))
        #expect(!lines.all.joined(separator: "\n").contains("Nothing serves on this Mac now"))
    }

    @Test func aPartThatDoesntStopUnpairsNothing() async {
        let (flow, calls, lines) = flow(yes: true, stopped: .failure(.init("This Mac's part has not finished releasing its memory")))
        #expect(await flow.run() == 1)
        #expect(calls.all == ["stop"])
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("This Mac's part has not finished releasing its memory"))
        #expect(text.contains("This Mac is still paired"))
        #expect(text.contains("`\(Self.cli) cluster leave` again"))
    }

    @Test func aPairingThatCantBeForgottenSaysSo() async {
        let (flow, calls, lines) = flow(yes: true, forgetFails: true)
        #expect(await flow.run() == 1)
        #expect(calls.all == ["stop", "forget a1a1"])
        #expect(lines.all.joined(separator: "\n").contains("pairings.json could not be written"))
        #expect(!lines.all.contains { $0.hasPrefix("✓ This Mac left the pair.") })
    }

    @Test func everyPairingOfThisMacIsForgotten() async {
        let both = ProviderUninstallPairing(peers: [.init(pin: Self.pin, name: Self.otherName),
                                                    .init(pin: Self.otherPin, name: "Apple M5 Max, 128 GB")],
                                            otherMacName: Self.otherName, role: .leader)
        let (flow, calls, _) = flow(pairing: both, yes: true)
        #expect(await flow.run() == 0)
        #expect(calls.all == ["stop", "forget a1a1", "forget b2b2"])
    }

    /// The stop before unpairing, `darkbloom uninstall`'s step 2 too: skipped with no cluster service; the pair's stop
    /// when it works; else this Mac's part alone, with why the other Mac wasn't asked; and an error when even that
    /// fails, so neither command unpairs a Mac whose part still runs.
    @Test func theStopBeforeUnpairingIsUninstallsStop() async throws {
        struct NotAnswered: Error, CustomStringConvertible { var description: String { "the other Mac did not answer" } }
        func stop(hasService: Bool = true, failing: Set<Bool> = []) async throws
            -> (stop: Cluster.Stop.BeforeUnpairing, calls: [String], lines: [String]) {
            let calls = Calls(), lines = Calls()
            let stop = try await Cluster.Stop.beforeUnpairing(hasService: hasService, say: { lines.append($0) }) { localOnly in
                calls.append(localOnly ? "--local-only" : "--service")
                if failing.contains(localOnly) { throw NotAnswered() }
                return .init(lines: ["stopped \(localOnly ? "here" : "together")"], otherMac: localOnly ? .notAsked : .stopped)
            }
            return (stop, calls.all, lines.all)
        }

        let none = try await stop(hasService: false)
        #expect(none.stop == .noService && none.stop.outcome == .skipped("no cluster service on this Mac"))
        #expect(none.calls.isEmpty && none.lines.isEmpty)

        let together = try await stop()
        #expect(together.stop == .stopped(.stopped) && together.stop.outcome == .done())
        #expect(together.calls == ["--service"] && together.lines == ["stopped together"])

        let alone = try await stop(failing: [false])
        #expect(alone.stop == .stoppedAlone("the other Mac did not answer"))
        #expect(alone.stop.outcome == .done("the other Mac was not asked to stop (the other Mac did not answer)"))
        #expect(alone.calls == ["--service", "--local-only"] && alone.lines == ["stopped here"])

        let stuck = Calls()
        await #expect(throws: NotAnswered.self) {
            _ = try await Cluster.Stop.beforeUnpairing(hasService: true, say: { _ in }) { localOnly in
                stuck.append(localOnly ? "--local-only" : "--service")
                throw NotAnswered()
            }
        }
        #expect(stuck.all == ["--service", "--local-only"])
    }

    /// The live stop before unpairing (`cluster leave`'s and `uninstall`'s) asks for the pair's stop first, then this
    /// Mac's part alone when that fails, each as a Mac that leaves (no "start it again"), and nothing without a cluster
    /// service.
    @Test func theLiveStopBeforeUnpairingTurnsTheServiceOffAsALeavingMac() async throws {
        struct PairDidntStop: Error, CustomStringConvertible { var description: String { "the pair did not stop" } }
        let executable = URL(fileURLWithPath: "/Applications/Darkbloom.app/Contents/MacOS/darkbloom")
        let seen = Calls()
        let service = Cluster.Stop.ServiceForTesting(installed: true) { localOnly, leaving in
            seen.append("localOnly \(localOnly), leaving \(leaving)")
            if !localOnly { throw PairDidntStop() }
            return .init(lines: [], otherMac: .notAsked)
        }
        let stopped = try await Cluster.Stop.$serviceForTesting.withValue(service) {
            try await Cluster.Stop.beforeUnpairing(executable: executable, say: { _ in })
        }
        #expect(seen.all == ["localOnly false, leaving true", "localOnly true, leaving true"])
        #expect(stopped == .stoppedAlone("the pair did not stop"))

        let nothing = Cluster.Stop.ServiceForTesting(installed: false) { _, _ in
            Issue.record("no cluster service: nothing to turn off")
            return .init(lines: [], otherMac: .notAsked)
        }
        let none = try await Cluster.Stop.$serviceForTesting.withValue(nothing) {
            try await Cluster.Stop.beforeUnpairing(executable: executable, say: { _ in })
        }
        #expect(none == .noService)
    }

    /// `uninstall`'s cluster step is this stop, as a Mac that leaves, and its summary says the other Mac's silence.
    @Test func uninstallsClusterStepIsTheStopBeforeUnpairing() async throws {
        let seen = Calls()
        let service = Cluster.Stop.ServiceForTesting(installed: true) { localOnly, leaving in
            seen.append("localOnly \(localOnly), leaving \(leaving)")
            return .init(lines: [], otherMac: .unanswered("\(Self.other) did not answer (timed out)"))
        }
        let operations = Uninstall.operations(drain: DrainOptions())
        let outcome = try await Cluster.Stop.$serviceForTesting.withValue(service) { try await operations.stopClusterPart() }
        #expect(seen.all == ["localOnly false, leaving true"])
        #expect(outcome == .done("the other Mac did not answer, so it was not asked to stop"))
    }

    @Test func leavingStopsThisMacsServiceWithoutSayingToStartItAgain() throws {
        let ordinary = try Cluster.Stop.finishStop(.success([])) { ["agent"] }
        #expect(ordinary.lines.last?.contains("Run `\(ClusterPairSummary.cli) cluster` to start it again.") == true)
        let leaving = try Cluster.Stop.finishStop(.success([]), leaving: true) { ["agent"] }
        #expect(leaving == .init(lines: ["This Mac's cluster service is stopped and will not start at login."], otherMac: .stopped))
        let alone = try Cluster.Stop.finishStop(nil, localOnly: true, leaving: true) { ["agent"] }
        #expect(alone.lines.last == "The other Mac was not asked to stop." && alone.otherMac == .notAsked)
        let other = "The other Mac (\(Self.otherName)) did not answer (its cluster service did not answer on the cable)"
        let unanswered = try Cluster.Stop.finishStop(
            .failure(.init(["This Mac stopped serving; the other Mac did not answer."], otherMacUnanswered: other)),
            leaving: true
        ) { ["agent"] }
        #expect(unanswered.lines == ["This Mac stopped serving.",
                                     other + ", so it was not asked to stop (its cluster service may already be off).",
                                     "This Mac's cluster service is stopped and will not start at login."])
    }

    /// The Mac left behind stays paired, and can't tell the other Mac having left from it being off: where its lines
    /// (`status`, `cluster status`, a start's result, and `darkbloom cluster`, which `start` opens in a terminal) say how
    /// to start the pair, they say how to leave it here too, and never that either Mac starts it.
    @Test func theMacLeftBehindIsToldHowToLeaveToo() {
        let cli = ClusterPairSummary.cli
        let leaveHere = "If the other Mac left the pair, `\(cli) cluster leave` here unpairs this Mac too."
        var stopped = ClusterPairSummary(paired: true, state: .stopped)
        stopped.role = .leader
        stopped.otherMacName = Self.otherName
        stopped.serviceRunning = true
        #expect(stopped.next == "`\(cli) start` starts the pair again. " + leaveHere)
        var off = stopped
        off.serviceRunning = false
        let offNext = "`\(cli) start` starts the pair again. This Mac's cluster service is off; `\(cli) start` here turns it "
            + "back on. " + leaveHere
        #expect(off.next == offNext)
        var away = stopped
        away.state = .otherMacAway
        away.started = true
        #expect(away.next?.hasSuffix("On that Mac, run `\(cli) start` (or `\(cli) cluster`). " + leaveHere) == true)
        var idle = Self.paired()
        idle.pairRunning = false
        #expect(idle.clusterStatusLines.last
            == "Next: `\(cli) start --solo` serves this Mac alone; `\(cli) start` starts the pair again. " + leaveHere)
        #expect(ClusterOnboardingDriver.otherMacSilentLine(Self.otherName).hasSuffix(
            "On that Mac, run `darkbloom start` or `darkbloom cluster`. If it left the pair, choose Start over to pair again, "
                + "or Quit and run `darkbloom cluster leave` here."))
    }
}
