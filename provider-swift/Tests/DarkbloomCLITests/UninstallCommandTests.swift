import ArgumentParser
import ProviderCore
import Testing

@testable import darkbloom

// Parsing only: nothing here runs a command, launchd or a prompt.
@Suite("Uninstall command")
struct UninstallCommandTests {
    private let cli = BuildEnvironment.current.cliName

    @Test("uninstall is a command, with the mode flags, --yes, --dry-run, --json and stop's drain options")
    func uninstallParses() throws {
        for arguments in [["uninstall"], ["uninstall", "--keep-data", "--yes"], ["uninstall", "--everything", "-y"],
                          ["uninstall", "--everything", "--dry-run", "--json"], ["uninstall", "--dry-run"],
                          ["uninstall", "--keep-data", "--yes", "--force", "--timeout", "30"]] {
            let command = try Darkbloom.parseAsRoot(arguments)
            #expect(String(describing: type(of: command)) == "Uninstall", "\(arguments)")
        }
        #expect(Darkbloom.helpMessage().contains("uninstall"))
    }

    @Test("conflicting flags are refused before anything runs")
    func conflictingFlagsAreRefused() {
        for (arguments, message) in [(["uninstall", "--keep-data", "--everything"], "Choose one of --keep-data and --everything."),
                                     (["uninstall", "--everything", "--json"], "--json goes with --dry-run.")] {
            do {
                _ = try Darkbloom.parseAsRoot(arguments)
                Issue.record("\(arguments) parsed")
            } catch {
                #expect(Darkbloom.message(for: error).contains(message), "\(arguments)")
            }
        }
    }

    @Test("stop --uninstall still parses as before, and its help points to uninstall")
    func stopUninstallIsUnchanged() throws {
        let stop = try #require(try Darkbloom.parseAsRoot(["stop", "--uninstall"]) as? Stop)
        #expect(stop.uninstall)
        #expect(Stop.helpMessage().contains("`\(cli) uninstall`"))
    }
}
