import ArgumentParser
import Testing

@testable import ProviderCore
@testable import darkbloom

/// `darkbloom --opencode` and `darkbloom --hermes`: with no subcommand, a tool flag makes the arguments `start`'s
/// (`Darkbloom.expandingToolShortcuts`, which `main` applies before it hosts or parses anything). Parsing only: no
/// command runs.
@Suite("darkbloom --opencode and --hermes")
struct ToolShortcutTests {
    static let cli = BuildEnvironment.current.cliName

    /// What `main` parses for `arguments`, typed after `darkbloom`.
    static func parsed(_ arguments: [String]) throws -> any ParsableCommand {
        try Darkbloom.parseAsRoot(Darkbloom.expandingToolShortcuts(arguments))
    }

    /// The error `main` reports for `arguments`; nil when they parse.
    static func failure(_ arguments: [String]) -> Error? {
        do {
            _ = try parsed(arguments)
            return nil
        } catch {
            return error
        }
    }

    /// The help `main` prints for `arguments` that ask for it: they parse to ArgumentParser's own help command, whose
    /// `run` only throws the help request.
    static func help(_ arguments: [String]) throws -> String {
        var command = try parsed(arguments)
        #expect(!(command is Darkbloom) && !(command is Start), "\(arguments) parse to the help command")
        do {
            try command.run()
        } catch {
            #expect(Darkbloom.exitCode(for: error) == .success)
            return Darkbloom.fullMessage(for: error, columns: 80)
        }
        Issue.record("\(arguments): the help command didn't throw its request")
        return ""
    }

    static let shortcuts: [([String], [IntegrationTool])] = [
        (["--opencode"], [.opencode]),
        (["--hermes"], [.hermes]),
        (["--opencode", "--hermes"], [.opencode, .hermes]),
        (["--hermes", "--opencode"], [.opencode, .hermes]),
        (["--opencode", "--me-first"], [.opencode]),
        (["--me-first", "--opencode"], [.opencode]),
        (["--local", "--hermes"], [.hermes]),
        (["--port", "8123", "--opencode", "--model", "fixture/a", "--model", "fixture/b"], [.opencode]),
        (["-c", "/tmp/fixture/provider.toml", "--hermes", "--route", "my-macs", "--opencode"], [.opencode, .hermes]),
    ]

    @Test("each form is `start` with its tool flags and every other option, in any order",
          arguments: ToolShortcutTests.shortcuts)
    func shortcutsAreStart(arguments: [String], tools: [IntegrationTool]) throws {
        #expect(Darkbloom.expandingToolShortcuts(arguments) == ["start"] + arguments)
        let short = try #require(try Self.parsed(arguments) as? Start, "\(arguments) must parse to start")
        let long = try Start.parse(arguments)
        #expect(short.requestedTools == tools)
        #expect(short.localFirstOptions == long.localFirstOptions)
        #expect(short.singleMacOptions == long.singleMacOptions)
        #expect(short.model == long.model && short.configOptions.config == long.configOptions.config)
    }

    @Test("start's own refusals and errors still apply, with start's usage")
    func startStillRefuses() throws {
        let network = try #require(Self.failure(["--opencode", "--network"]))
        #expect(Darkbloom.message(for: network) == "`--opencode` needs this Mac's local API, which `--network` "
            + "doesn't serve. Use --me-first or --local instead.")
        let typo = try #require(Self.failure(["--opencode", "--me-firs"]))
        #expect(Darkbloom.message(for: typo) == "Unknown option '--me-firs'. Did you mean '--me-first'?")
        #expect(Darkbloom.fullMessage(for: typo, columns: 80).contains("Usage: \(Self.cli) start "))
    }

    @Test("`start --opencode` keeps working", arguments: [["start", "--opencode"], ["start", "--hermes", "--me-first"]])
    func longFormKeepsWorking(arguments: [String]) throws {
        #expect(Darkbloom.expandingToolShortcuts(arguments) == arguments)
        let start = try #require(try Self.parsed(arguments) as? Start)
        #expect(start.requestedTools == (arguments.contains("--opencode") ? [.opencode] : [.hermes]))
    }

    @Test("help, the version, plain darkbloom, subcommands and other arguments are parsed as typed",
          arguments: [[], ["--help"], ["-h"], ["--version"], ["help"], ["help", "start"], ["status"], ["local"],
                      ["status", "--opencode"], ["cluster", "local"], ["--opencod"], ["--", "--opencode"]])
    func otherArgumentsAreUnchanged(arguments: [String]) {
        #expect(Darkbloom.expandingToolShortcuts(arguments) == arguments)
    }

    @Test("plain darkbloom, --help and --version answer as before; a subcommand keeps its own options")
    func rootAnswersAsBefore() throws {
        #expect(try Self.parsed([]) is Darkbloom, "the root command runs, and prints its help")
        for flag in ["--help", "-h"] {
            #expect(try Self.help([flag]) == Darkbloom.helpMessage(includeHidden: false, columns: 80))
        }
        let version = try #require(Self.failure(["--version"]))
        #expect(Darkbloom.exitCode(for: version) == .success)
        #expect(Darkbloom.fullMessage(for: version, columns: 80) == Darkbloom.configuration.version)
        let status = try #require(Self.failure(["status", "--opencode"]))
        #expect(Darkbloom.message(for: status) == "Unknown option '--opencode'")
        #expect(Darkbloom.fullMessage(for: status, columns: 80).contains("Usage: \(Self.cli) status "))
        // `--help` with a shortcut is the help of what it runs: start's.
        #expect(try Self.help(["--opencode", "--help"])
            == Darkbloom.helpMessage(for: Start.self, includeHidden: false, columns: 80))
    }

    @Test("a mistyped tool flag gets the usual unknown-option error, from the root command",
          arguments: ["--opencod", "--hermez", "--open-code"])
    func typoIsTheUsualError(flag: String) throws {
        let error = try #require(Self.failure([flag]))
        #expect(Darkbloom.message(for: error) == "Unknown option '\(flag)'")
        #expect(Darkbloom.exitCode(for: error) == .validationFailure)
        #expect(Darkbloom.fullMessage(for: error, columns: 80) == "Error: Unknown option '\(flag)'\n"
            + "Usage: \(Self.cli) <subcommand>\n  See '\(Self.cli) --help' for more information.")
    }

    @Test("`darkbloom --help` lists every subcommand and shows each shortcut in one line")
    func helpShowsTheShortcuts() throws {
        let help = Darkbloom.helpMessage(includeHidden: false, columns: 80)
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The longest command name of any build (darkbloom-staging) still fits each line in 80 columns.
        let longestName = BuildEnvironment.allCases.map(\.cliName.count).max() ?? Self.cli.count
        for (flag, tool) in [("--opencode", "OpenCode"), ("--hermes", "Hermes Agent")] {
            let shortcut = lines.filter { $0.contains("\(Self.cli) \(flag)") }
            #expect(shortcut.count == 1, "one line for \(flag): \(shortcut)")
            #expect(shortcut.first?.hasSuffix("Set up \(tool) (same as `start \(flag)`)") == true, "\(shortcut)")
            #expect(shortcut.allSatisfy { $0.count - Self.cli.count + longestName < 80 }, "\(shortcut)")
        }
        #expect(lines.contains("USAGE: \(Self.cli) <subcommand>"))
        for command in Darkbloom.configuration.subcommands where command.configuration.shouldDisplay {
            #expect(lines.contains { $0.hasPrefix("  \(command._commandName)") }, "\(command._commandName) is listed")
        }
    }

    @Test("`darkbloom local` names the shortcuts")
    func localNamesTheShortcuts() {
        #expect(Local.toolsLine == "  tools:    \(Self.cli) --opencode · --hermes")
    }
}
