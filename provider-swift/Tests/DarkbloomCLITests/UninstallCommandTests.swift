import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

// Parsing: nothing here runs a command, launchd or a prompt.
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
}
