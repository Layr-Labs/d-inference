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
            let executable = URL(fileURLWithPath: Start.currentExecutablePath())
            let flow = ClusterLeaveFlow(
                pair: ClusterPairSummary.local(), pairing: ProviderUninstallPairing.read(),
                terminal: ClusterPairCommands.isTerminal(), yes: yes,
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
            let code = await flow.run()
            if code != 0 { throw ExitCode(code) }
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
    /// Stops this Mac's part and turns its cluster service off (`Cluster.Stop.beforeUnpairing`): `.done(nil)` when the
    /// pair stopped together, `.done(note)` when the other Mac was not asked, `.skipped` with no cluster service here.
    /// It returns only once this Mac's cluster service, and with it its part, no longer runs; else it throws.
    var stopPart: () async throws -> ProviderUninstall.Outcome
    /// Forgets the pairing with the Mac whose pin it is (`cluster pair --forget <pin>`).
    var forget: (String) throws -> Void
    /// Single-Mac serving runs on this Mac (beside, not in, the pair).
    var soloServing: () -> Bool
    var say: (String) -> Void

    static var cli: String { ClusterPairSummary.cli }
    static let question = "Leave the pair? [y/N] "

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
        let stopped: ProviderUninstall.Outcome
        do {
            stopped = try await stopPart()
        } catch {
            say("✗ This Mac's part didn't stop: \(Self.words(error))")
            say("This Mac is still paired. Try `\(cli) cluster leave` again; `\(cli) cluster status` shows what still runs.")
            return 1
        }
        if case .skipped(let reason) = stopped { say("  Nothing to stop: \(reason).") }

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

        say("✓ This Mac left the pair. " + (soloServing() ? "Single-Mac serving keeps running on this Mac."
            : "Nothing serves on this Mac now: `\(cli) start` serves it alone."))
        say(otherMacLine(stopped))
        say("To pair the two Macs again, run `\(cli) cluster` on each Mac.")
        return 0
    }

    /// An error as one line: a cluster failure's own lines, else its description.
    static func words(_ error: Error) -> String {
        (error as? ClusterOnboardingFailure)?.lines.joined(separator: " ") ?? "\(error)"
    }

    /// What happens to the other Mac: it keeps its pairing until it leaves too.
    func otherMacLine(_ stopped: ProviderUninstall.Outcome) -> String {
        let cli = Self.cli
        let other = ClusterOnboardingMacName.sentence(
            ClusterOnboardingMacName.other(named: pairing?.otherMacName ?? pair.otherMacName))
        let what: String
        switch stopped {
        case .done(nil): what = "\(other) stopped serving the pair too."
        case .done: what = "\(other) wasn't reached, so it wasn't asked to stop."
        case .skipped: what = "\(other) wasn't asked anything."
        }
        return what + " It keeps its pairing until you run `\(cli) cluster leave` on it; then `\(cli) start` there serves "
            + "it alone."
    }
}
