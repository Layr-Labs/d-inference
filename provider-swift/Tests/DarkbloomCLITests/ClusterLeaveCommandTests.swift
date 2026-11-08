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
                      stopped: Result<ProviderUninstall.Outcome, ClusterOnboardingFailure> = .success(.done()),
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

    @Test func yesStopsThisMacsPartThenForgetsThePairing() async {
        let (flow, calls, lines) = flow(answer: "yes")
        #expect(await flow.run() == 0)
        #expect(calls.all == ["ask", "stop", "forget a1a1"])
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("✓ This Mac left the pair."))
        #expect(text.contains("Nothing serves on this Mac now: `\(Self.cli) start` serves it alone."))
        #expect(text.contains("The other Mac (\(Self.otherName)) stopped serving the pair too. It keeps its pairing "
            + "until you run `\(Self.cli) cluster leave` on it; then `\(Self.cli) start` there serves it alone."))
        #expect(text.contains("To pair the two Macs again, run `\(Self.cli) cluster` on each Mac."))
        #expect(!text.contains("tok/s") && !text.contains("dk-local-"))
    }

    @Test func fromTheMacThatFollowsItLeavesTheSameWay() async {
        let (flow, calls, lines) = flow(pair: Self.paired(role: .member), yes: true)
        #expect(await flow.run() == 0)
        #expect(calls.all == ["stop", "forget a1a1"])
        #expect(lines.all.joined(separator: "\n").contains("`\(Self.cli) cluster leave` on it"))
    }

    @Test func anOtherMacThatWasntReachedIsSaidSo() async {
        let (flow, _, lines) = flow(yes: true, stopped: .success(.done("the other Mac was not asked to stop (timed out)")))
        #expect(await flow.run() == 0)
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("The other Mac (\(Self.otherName)) wasn't reached, so it wasn't asked to stop. It keeps its "
            + "pairing until you run `\(Self.cli) cluster leave` on it"))
        #expect(!text.contains("stopped serving the pair too"))
    }

    @Test func singleMacServingOnThisMacKeepsRunning() async {
        let (flow, _, lines) = flow(yes: true, soloServing: true)
        #expect(await flow.run() == 0)
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("Single-Mac serving keeps running on this Mac."))
        #expect(!text.contains("Nothing serves on this Mac now"))
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

    @Test func leavingStopsThisMacsServiceWithoutSayingToStartItAgain() throws {
        let ordinary = try Cluster.Stop.finishStop(.success([])) { ["agent"] }
        #expect(ordinary.last?.contains("Run `\(ClusterPairSummary.cli) cluster` to start it again.") == true)
        let leaving = try Cluster.Stop.finishStop(.success([]), leaving: true) { ["agent"] }
        #expect(leaving == ["This Mac's cluster service is stopped and will not start at login."])
        let alone = try Cluster.Stop.finishStop(nil, localOnly: true, leaving: true) { ["agent"] }
        #expect(alone.last == "The other Mac was not asked to stop.")
        let other = "The other Mac (\(Self.otherName)) did not answer (its cluster service did not answer on the cable)"
        let unanswered = try Cluster.Stop.finishStop(
            .failure(.init(["This Mac stopped serving; the other Mac did not answer."], otherMacUnanswered: other)),
            leaving: true
        ) { ["agent"] }
        #expect(unanswered == ["This Mac stopped serving.",
                               other + ", so it was not asked to stop (its cluster service may already be off).",
                               "This Mac's cluster service is stopped and will not start at login."])
    }
}
