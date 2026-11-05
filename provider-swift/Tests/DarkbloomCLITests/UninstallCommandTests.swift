import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

// Parsing, and the pair's stop with stand-in actions: nothing here runs a command, launchd or a prompt.
@Suite("Uninstall command")
struct UninstallCommandTests {
    private let cli = BuildEnvironment.current.cliName

    @Test("uninstall is a command, with --everything or --keep-models, --yes, --dry-run, --json and stop's drain options")
    func uninstallParses() throws {
        for arguments in [["uninstall"], ["uninstall", "--everything", "--yes"], ["uninstall", "--keep-models", "-y"],
                          ["uninstall", "--keep-models", "--dry-run", "--json"], ["uninstall", "--dry-run"],
                          ["uninstall", "--everything", "--yes", "--force", "--timeout", "30"]] {
            let command = try Darkbloom.parseAsRoot(arguments)
            #expect(String(describing: type(of: command)) == "Uninstall", "\(arguments)")
        }
        #expect(Darkbloom.helpMessage().contains("uninstall"))
    }

    @Test("conflicting flags, and the old --keep-data, are refused with the usage before anything runs")
    func conflictingFlagsAreRefused() {
        for (arguments, message) in [(["uninstall", "--everything", "--keep-models"], "Choose one of --everything and --keep-models."),
                                     (["uninstall", "--everything", "--json"], "--json goes with --dry-run."),
                                     (["uninstall", "--keep-data", "--yes"], "Unknown option '--keep-data'")] {
            do {
                _ = try Darkbloom.parseAsRoot(arguments)
                Issue.record("\(arguments) parsed")
            } catch {
                #expect(Darkbloom.message(for: error).contains(message), "\(arguments)")
                #expect(Darkbloom.fullMessage(for: error).contains("Usage: \(cli) uninstall [--everything] [--keep-models]"),
                        "\(arguments)")
                #expect(Darkbloom.exitCode(for: error) == .validationFailure, "\(arguments)")
            }
        }
    }

    @Test("stop --uninstall still parses as before, and its help points to uninstall")
    func stopUninstallIsUnchanged() throws {
        let stop = try #require(try Darkbloom.parseAsRoot(["stop", "--uninstall"]) as? Stop)
        #expect(stop.uninstall)
        #expect(Stop.helpMessage().contains("`\(cli) uninstall`"))
    }

    @Test("beside the other install, the pair is asked to stop as `stop` asks it, after saying what it waits for")
    func pairStopAsksAsStopDoes() {
        let asked = Asked()
        let say: ClusterPairCommands.Say = { asked.add($0) }
        func actions(_ role: ClusterOnboardingRole?, serving: Bool,
                     stop: Result<[String], ClusterOnboardingFailure> = .success(["Stopping both Macs."])) -> ClusterPairActions {
            ClusterPairActions(resume: { ClusterOnboardingResume(role: role, peerName: "M3 Ultra, 512 GB", serving: serving) },
                               ensureService: { .success(()) }, serve: { .success([]) },
                               stop: { asked.add("stop"); return stop }, verifyTeardown: { .success([]) })
        }
        // The stop answers once both Macs have stopped, after their accepted requests: minutes, said before, not after.
        let wait = "Asking the pair to stop; accepted requests finish first (up to about 6 min)."
        #expect(Uninstall.stopBothMacs(actions(.member, serving: true), say: say) == .stopped)
        #expect(Uninstall.stopBothMacs(actions(.leader, serving: false), say: say) == .stopped, "a leader finishes a stop already saved")
        #expect(asked.all == [wait, "stop", wait, "stop"])
        let idle: [(ClusterOnboardingRole?, Bool)] = [(.member, false), (nil, true)]
        for (role, serving) in idle {
            #expect(Uninstall.stopBothMacs(actions(role, serving: serving), say: say) == .notServing, "\(String(describing: role))")
        }
        #expect(asked.all == [wait, "stop", wait, "stop"],
                "nothing serves that this Mac's stop would break: the pair is not asked, and nothing is said")
        let unanswered = ClusterOnboardingFailure(["The other Mac (M3 Ultra, 512 GB) did not answer over the cable: timed out.",
                                                   "Check the cable."])
        #expect(Uninstall.stopBothMacs(actions(.member, serving: true, stop: .failure(unanswered)), say: say)
            == .noAnswer("The other Mac (M3 Ultra, 512 GB) did not answer over the cable: timed out. Check the cable."))
        #expect(Uninstall.stopBothMacs(nil, say: say) == .noAnswer("this Mac's cluster service could not be asked"))
        #expect(asked.all == [wait, "stop", wait, "stop", wait, "stop"], "said once per stop asked, before it")
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}
