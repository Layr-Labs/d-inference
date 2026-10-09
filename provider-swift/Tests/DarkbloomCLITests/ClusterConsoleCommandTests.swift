import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Cluster console CLI")
struct ClusterConsoleCommandTests {
    private let pin = String(repeating: "a", count: 64)
    private var setup: [String] {
        ["--input", "/Users/fixture/setup.json", "--capability", "/Users/fixture/capability.json", "--capability-sha256", pin]
    }

    @Test("console parses its output modes, the dry run and an optional setup to approve, without IO")
    func accepted() throws {
        let bare = try Cluster.Console.parse([])
        #expect(!bare.json && !bare.plain && !bare.dryRun && !bare.temporary)
        #expect(try Cluster.Console.parse(["--temporary"]).temporary)
        #expect(bare.input == nil && bare.capability == nil && bare.capabilitySHA256 == nil && bare.configOptions.config == nil)
        let plain = try Cluster.Console.parse(["--plain", "--dry-run", "--config", "/Users/fixture/provider.toml"])
        #expect(plain.plain && plain.dryRun && plain.configOptions.config == "/Users/fixture/provider.toml")
        #expect(try Cluster.Console.parse(["--json"]).json)
        let approving = try Cluster.Console.parse(setup)
        #expect(approving.input == "/Users/fixture/setup.json" && approving.capability == "/Users/fixture/capability.json")
        #expect(approving.capabilitySHA256 == pin)
    }

    @Test("two output modes, half a setup, relative paths, a malformed pin and anything privileged refuse")
    func rejected() {
        for values in [["--json", "--plain"], ["--input", "/Users/fixture/setup.json"], Array(setup.dropLast(2)),
                       ["--input", "relative.json", "--capability", "/capability.json", "--capability-sha256", pin],
                       ["--input", "/input.json", "--capability", "/capability.json", "--capability-sha256", String(repeating: "A", count: 64)],
                       ["--input", "/input.json", "--capability", "/capability.json", "--capability-sha256", "abc"],
                       ["--config", "relative.toml"], ["--yes"], ["--fix"], ["--sudo"], ["--device", "rdma_en6"],
                       ["--address", "192.0.2.10"], ["--host", "remote.example"], ["--start"], ["--approve"]] {
            #expect(throws: (any Error).self) { _ = try Cluster.Console.parse(values) }
        }
    }

    @Test("console is registered and every existing cluster command is reached exactly as before")
    func dispatch() throws {
        let console = try #require(try Darkbloom.parseAsRoot(["cluster", "console", "--plain"]) as? Cluster.Console)
        #expect(console.plain)
        // Bare `darkbloom cluster` still parses as the guided setup, with its own flags.
        #expect(try Darkbloom.parseAsRoot(["cluster"]) is Cluster.Setup)
        let unattended = try #require(try Darkbloom.parseAsRoot(["cluster", "--json", "--yes"]) as? Cluster.Setup)
        #expect(unattended.json && unattended.yes)
        #expect(try Darkbloom.parseAsRoot(["cluster", "setup"]) is Cluster.Setup)
        #expect(try Darkbloom.parseAsRoot(["cluster", "link", "--watch"]) is Cluster.Link)
        #expect(try Darkbloom.parseAsRoot(["cluster", "status", "--json"]) is Cluster.Status)
        #expect(try Darkbloom.parseAsRoot(["cluster", "doctor"]) is Cluster.Doctor)
        #expect(try Darkbloom.parseAsRoot(["cluster", "recover", "--json"]) is Cluster.Recover)
        #expect(try Darkbloom.parseAsRoot(["cluster", "configure"] + setup) is Cluster.Configure)
        #expect(try Darkbloom.parseAsRoot(["cluster", "worker-owner", "--stdio"]) is Cluster.WorkerOwner)
        // The guided setup keeps its own flags, and the console's do not leak onto it.
        let planned = try #require(try Darkbloom.parseAsRoot(["cluster", "--dry-run", "--temporary"]) as? Cluster.Setup)
        #expect(planned.dryRun && planned.temporary && !planned.json && !planned.yes)
        #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["cluster", "--plain"]) }
        #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["cluster", "--input", "/Users/fixture/setup.json"]) }
        #expect(Cluster.configuration.defaultSubcommand == Cluster.Setup.self)
    }

    @Test("the screen opens only on a terminal at both ends that can draw one, and never with an output flag")
    func opensScreen() {
        #expect(Cluster.Console.opensScreen(json: false, plain: false, inputIsTerminal: true, outputIsTerminal: true, terminalType: "xterm-256color"))
        for (json, plain, input, output) in [(true, false, true, true), (false, true, true, true), (false, false, false, true),
                                             (false, false, true, false), (false, false, false, false)] {
            #expect(!Cluster.Console.opensScreen(json: json, plain: plain, inputIsTerminal: input, outputIsTerminal: output,
                terminalType: "xterm-256color"))
        }
        for type in [nil, "", "dumb", "unknown"] as [String?] {
            #expect(!Cluster.Console.opensScreen(json: false, plain: false, inputIsTerminal: true, outputIsTerminal: true, terminalType: type))
        }
    }

    @Test("bare `darkbloom cluster` opens the console only in a terminal with none of the setup's flags; `cluster setup` never does")
    func replacesGuidedSetup() {
        func replaces(_ arguments: [String], json: Bool = false, yes: Bool = false, temporary: Bool = false, dryRun: Bool = false,
                      input: Bool = true, output: Bool = true, type: String? = "xterm-256color") -> Bool {
            Cluster.Console.replacesGuidedSetup(arguments: arguments, json: json, yes: yes, temporary: temporary, dryRun: dryRun,
                inputIsTerminal: input, outputIsTerminal: output, terminalType: type)
        }
        #expect(replaces(["darkbloom", "cluster"]))
        #expect(replaces(["/usr/local/bin/darkbloom", "cluster"]))
        // The program's own path is not an argument, whatever it is called.
        #expect(replaces(["setup", "cluster"]))
        #expect(!replaces(["darkbloom", "cluster", "setup"]))
        #expect(!replaces(["darkbloom", "cluster"], json: true))
        #expect(!replaces(["darkbloom", "cluster"], yes: true))
        // A dry run and a temporary address are the line-by-line flow's, exactly as before:
        // the console that would open in their place would not carry them.
        #expect(!replaces(["darkbloom", "cluster", "--dry-run"], dryRun: true))
        #expect(!replaces(["darkbloom", "cluster", "--temporary"], temporary: true))
        #expect(!replaces(["darkbloom", "cluster"], input: false))
        #expect(!replaces(["darkbloom", "cluster"], output: false))
        // A terminal that only prints lines gets the line-by-line flow.
        #expect(!replaces(["darkbloom", "cluster"], type: "dumb"))
        #expect(!replaces(["darkbloom", "cluster"], type: nil))
    }
}
