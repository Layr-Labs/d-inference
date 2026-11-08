import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// `darkbloom cluster leave`: this Mac leaves its pair, from either Mac, with the steps `darkbloom uninstall` takes
    /// for the pair: this Mac's part stops (`Cluster.Stop.beforeUnpairing`), then its pairing is forgotten
    /// (`cluster pair --forget`, `ClusterUnpairing`). Nothing else changes: single-Mac serving, models and the cable
    /// port setup stay.
    struct Leave: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "leave",
            abstract: "Leave the pair on this Mac: stop its part and forget its pairing (asks first).",
            discussion: """
                Stops the pair (on both Macs while the other Mac answers) and this Mac's cluster service, then forgets \
                this Mac's pairing, as Start over and `\(ClusterPairSummary.cli) cluster pair --forget` do. The other \
                Mac keeps its own pairing until you run `\(ClusterPairSummary.cli) cluster leave` there too. Then \
                `\(ClusterPairSummary.cli) start` serves each Mac alone, and `\(ClusterPairSummary.cli) cluster` on \
                each Mac pairs them again. In a terminal it asks first; without one it needs --yes.
                """)

        @Flag(name: .shortAndLong, help: "Don't ask (needed without a terminal).")
        var yes = false

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let code = await flow(.live()).run()
            if code != 0 { throw ExitCode(code) }
        }

        /// `base` (this Mac's pair, services and pairing store) as this command runs it: with its own --yes, asking in
        /// this Mac's terminal (`ClusterPairCommands.isTerminal`). The one place both are wired, so a leave without
        /// --yes always asks first, and refuses where it can't ask.
        func flow(_ base: ClusterLeaveFlow) -> ClusterLeaveFlow {
            var flow = base
            flow.yes = yes
            flow.terminal = ClusterPairCommands.isTerminal()
            return flow
        }
    }
}

/// The steps of `darkbloom cluster leave`, apart from the terminal, the pair's services and the pairing store. It asks
/// before anything changes, stops this Mac's part before it forgets the pairing (a part that doesn't stop leaves the
/// Mac paired), and ends with what happens to the other Mac and how to pair again. No key and no speed.
struct ClusterLeaveFlow {
    /// This Mac's pair, as it knows it by itself (`ClusterPairSummary.local`).
    var pair: ClusterPairSummary
    /// The pairings this Mac holds (`ProviderUninstallPairing.read`); nil when it holds none.
    var pairing: ProviderUninstallPairing?
    var terminal: Bool
    var yes: Bool
    /// Asks `question` in the terminal and reads the answer; nil when the input ends.
    var ask: (String) -> String?
    /// Stops this Mac's part and turns its cluster service off (`Cluster.Stop.beforeUnpairing`), saying what the other
    /// Mac was asked. It must return only once this Mac's cluster service, and with it its part, has ended, and throw
    /// otherwise.
    var stopPart: () async throws -> Cluster.Stop.BeforeUnpairing
    /// Forgets the pairing with the Mac whose pin it is (`cluster pair --forget <pin>`).
    var forget: (String) throws -> Void
    /// Single-Mac serving runs on this Mac (beside, not in, the pair).
    var soloServing: () -> Bool
    var say: (String) -> Void

    static var cli: String { ClusterPairSummary.cli }
    static let question = "Leave the pair? [y/N] "

    /// This Mac's pair, cluster service and pairing store, and its terminal's question. It asks nothing and leaves
    /// nothing until `Cluster.Leave.flow` gives it the command's --yes and this Mac's terminal: as made here, with
    /// neither, it refuses.
    static func live(pair: ClusterPairSummary = .local(), pairing: ProviderUninstallPairing? = .read()) -> ClusterLeaveFlow {
        let executable = URL(fileURLWithPath: Start.currentExecutablePath())
        return ClusterLeaveFlow(
            pair: pair, pairing: pairing, terminal: false, yes: false,
            ask: { question in
                print(question, terminator: "")
                fflush(stdout)
                let answer = readLine()
                if answer == nil { print() }
                return answer
            },
            stopPart: { try await Cluster.Stop.beforeUnpairing(executable: executable, say: ClusterPairCommands.printLine) },
            forget: Cluster.Pair.forget(pin:),
            soloServing: { ServiceDrain.soloProviderState().map { daemonProcessAlive(pid: $0.pid) } ?? false },
            say: ClusterPairCommands.printLine)
    }

    func run() async -> Int32 {
        let cli = Self.cli
        if pair.pairingUnreadable {
            say(pair.pairSentence)
            say("`\(cli) cluster leave` can't tell which pair to leave, so nothing was changed. " + ClusterPairSummary.checkPairingLine)
            return 1
        }
        guard let pairing, !pairing.peers.isEmpty else {
            say("This Mac isn't in a two-Mac cluster: nothing to leave.")
            if pair.leftoverService {
                say("A cluster service from an earlier pairing is still here: `\(cli) cluster stop --service` removes it.")
            }
            return 0
        }
        if !yes {
            guard terminal else {
                say("`\(cli) cluster leave` asks before it unpairs this Mac, and there's no terminal to ask in: run it in "
                    + "Terminal, or add --yes.")
                return 1
            }
            say(pair.pairSentence)
            say("Leaving stops the pair (on both Macs while the other Mac answers) and this Mac's cluster service, and "
                + "forgets this Mac's pairing. The other Mac keeps its own pairing until it leaves too.")
            guard ProviderUninstall.confirmed(ask(Self.question)) else {
                say("Nothing changed.")
                return 0
            }
        }

        say("→ Stopping this Mac's part of the pair")
        let stopped: Cluster.Stop.BeforeUnpairing
        do {
            stopped = try await stopPart()
        } catch {
            say("✗ This Mac's part didn't stop: \(Self.words(error))")
            say("This Mac is still paired. Try `\(cli) cluster leave` again; `\(cli) cluster status` shows what still runs.")
            return 1
        }
        if stopped == .noService { say("  Nothing to stop: no cluster service on this Mac.") }

        // Only now, with this Mac's part stopped: a Mac whose part still runs is never unpaired.
        say("→ Forgetting this Mac's pairing")
        for peer in pairing.peers {
            do {
                try forget(peer.pin)
            } catch {
                say("✗ The pairing with \(peer.name) wasn't forgotten: \(Self.words(error))")
                say("This Mac's part is stopped. Try `\(cli) cluster leave` again.")
                return 1
            }
        }

        say("✓ This Mac left the pair. " + (soloServing()
            ? "Single-Mac serving keeps running on this Mac; `\(cli) cluster` pairs it again."
            : "Nothing serves on this Mac now: `\(cli) start` serves it alone, or `\(cli) cluster` pairs it again."))
        say(otherMacLine(stopped))
        say("To pair these two Macs again instead, run `\(cli) cluster` on each Mac; if the other Mac offers Start over, "
            + "choose it.")
        return 0
    }

    /// An error as one line: a cluster failure's own lines, else its description.
    static func words(_ error: Error) -> String {
        (error as? ClusterOnboardingFailure)?.lines.joined(separator: " ") ?? "\(error)"
    }

    /// What the stop did to the other Mac, only what this Mac knows, and how it leaves too.
    func otherMacLine(_ stopped: Cluster.Stop.BeforeUnpairing) -> String {
        let other = ClusterOnboardingMacName.sentence(
            ClusterOnboardingMacName.other(named: pairing?.otherMacName ?? pair.otherMacName))
        let keepsItsPairing = " It keeps its pairing until you run `\(Self.cli) cluster leave` there."
        switch stopped {
        case .stopped(.stopped): return "\(other) stopped serving the pair too." + keepsItsPairing
        case .stopped(.unanswered): return Self.unansweredLine(other)
        // The Mac that follows forwards the stop; the leading Mac's silence comes back as its failure.
        case .stoppedAlone(let why) where ClusterPairSummary.saysOtherMacSilent(why): return Self.unansweredLine(other)
        case .stopped(.notAsked), .stoppedAlone: return "\(other) wasn't asked to stop." + keepsItsPairing
        case .noService: return "\(other) wasn't asked anything." + keepsItsPairing
        }
    }

    /// The other Mac didn't answer: this Mac can't tell it being away from it having left the pair already.
    static func unansweredLine(_ other: String) -> String {
        "\(other) didn't answer, so it wasn't asked to stop; it may have left the pair already. If it hasn't, "
            + "`\(cli) cluster leave` there unpairs it too."
    }
}
