import ArgumentParser
import Testing
@testable import darkbloom
import ProviderCore

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
        #expect(try Darkbloom.parseAsRoot(["cluster", "reap", "--json", "--no-wait"]) is Cluster.Reap)
        #expect(try Darkbloom.parseAsRoot(["cluster", "verify-teardown", "--json", "--samples", "3"]) is Cluster.VerifyTeardown)
        #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["cluster", "verify-teardown", "--samples", "0"]) }
        #expect(try Darkbloom.parseAsRoot(["cluster", "cancel-all", "--json"]) is Cluster.CancelAll)
        #expect(try Darkbloom.parseAsRoot(["cluster", "configure"] + setup) is Cluster.Configure)
        #expect(try Darkbloom.parseAsRoot(["cluster", "worker-owner", "--stdio"]) is Cluster.WorkerOwner)
        // The guided setup keeps its own flags, and the console's do not leak onto it.
        let planned = try #require(try Darkbloom.parseAsRoot(["cluster", "--dry-run", "--temporary"]) as? Cluster.Setup)
        #expect(planned.dryRun && planned.temporary && !planned.json && !planned.yes)
        // `--plain` is the setup wizard's printed form now; the console's setup input is not taken.
        #expect(try (Darkbloom.parseAsRoot(["cluster", "--plain"]) as? Cluster.Setup)?.plain == true)
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

    @Test("`darkbloom cluster` and `darkbloom cluster setup` run the onboarding on any terminal; the link setup only when asked for")
    func entry() {
        func entry(json: Bool = false, yes: Bool = false, temporary: Bool = false, dryRun: Bool = false, linkOnly: Bool = false,
                   wizard: Bool = false, input: Bool = true, output: Bool = true, type: String? = "xterm-256color") -> Cluster.Setup.Entry {
            Cluster.Setup.entry(json: json, yes: yes, temporary: temporary, dryRun: dryRun, linkOnly: linkOnly, wizard: wizard,
                inputIsTerminal: input, outputIsTerminal: output, terminalType: type)
        }
        #expect(entry() == .onboarding)
        // A terminal that only prints lines still runs the onboarding: it prints plain lines and reads keys through termios.
        for type in [nil, "", "dumb", "unknown"] as [String?] { #expect(entry(type: type) == .onboarding) }
        // No terminal: one line that says where to run it, never the link-only flow that ends without pairing.
        #expect(entry(input: false) == .needsTerminal)
        #expect(entry(output: false) == .needsTerminal)
        #expect(entry(input: false, output: false) == .needsTerminal)
        // The link setup only with the options that ask for it.
        #expect(entry(json: true) == .linkSetup)
        #expect(entry(yes: true) == .linkSetup)
        #expect(entry(temporary: true) == .linkSetup)
        #expect(entry(dryRun: true) == .linkSetup)
        #expect(entry(linkOnly: true) == .linkSetup)
        #expect(entry(json: true, input: false, output: false) == .linkSetup)
        // The earlier wizard only behind its developer flag, on a terminal that can draw it.
        #expect(entry(wizard: true) == .wizard)
        #expect(entry(dryRun: true, wizard: true) == .wizard)
        #expect(entry(wizard: true, type: "dumb") == .onboarding)
        #expect(Cluster.Setup.needsTerminalLine == "Run `darkbloom cluster` in a Terminal window on this Mac.")
    }

    @Test("`cluster setup` parses to the same command as bare `cluster`")
    func setupIsTheOnboarding() throws {
        #expect(try Darkbloom.parseAsRoot(["cluster"]) is Cluster.Setup)
        #expect(try Darkbloom.parseAsRoot(["cluster", "setup"]) is Cluster.Setup)
        #expect(try Darkbloom.parseAsRoot(["cluster", "setup", "--link-only"]) is Cluster.Setup)
    }

    @Test("the cluster help reads as one command: developer subcommands and options are hidden")
    func helpIsPlain() {
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(flat(Cluster.helpMessage()).contains("Set up two or more Macs to serve one model together. Run it on each Mac and follow the screen."))
        let shown = Set(Cluster.configuration.subcommands.filter { $0.configuration.shouldDisplay }.compactMap { $0.configuration.commandName })
        for hidden in ["plan", "configure", "console", "worker-owner", "link-follower", "recover", "reap", "verify-teardown", "cancel-all",
                       "pair", "incidents", "report", "inbox", "link-channel", "member-identity", "service"] {
            #expect(!shown.contains(hidden), "\(hidden) is hidden from `darkbloom cluster --help`")
        }
        for visible in ["setup", "link", "status", "doctor", "stop"] { #expect(shown.contains(visible), "\(visible) stays visible") }
        let setup = flat(Cluster.Setup.helpMessage())
        for option in ["--pair", "--capability", "--member", "--model-dir", "--worker", "--wizard", "--plain", "--link-only"] {
            #expect(!setup.contains(option), "\(option) is hidden")
        }
        for words in ["rank 0", "bridge", "fixed address", "RDMA GID", "six-step", "plan's"] { #expect(!setup.contains(words), "no \(words) in the help") }
    }

    @Test("the wizard takes a pair as all four options or none, absolute, with a lowercase pin and a member label")
    func wizardPair() throws {
        let pair = ["--pair", "/Users/fixture/pair.json", "--capability", "/Users/fixture/capability.json",
                    "--capability-sha256", pin, "--member", "mac-a"]
        let given = try #require(try Darkbloom.parseAsRoot(["cluster"] + pair) as? Cluster.Setup)
        #expect(try given.wizardPair() == .init(description: "/Users/fixture/pair.json", capability: "/Users/fixture/capability.json",
            capabilitySHA256: pin, memberID: "mac-a"))
        #expect(try (Darkbloom.parseAsRoot(["cluster"]) as? Cluster.Setup)?.wizardPair() == nil)
        for values in [Array(pair.dropLast(2)), ["--pair", "relative.json"] + Array(pair.dropFirst(2)),
                       Array(pair.prefix(4)) + ["--capability-sha256", "ABC", "--member", "mac-a"],
                       Array(pair.prefix(6)) + ["--member", "-flag"], Array(pair.prefix(6)) + ["--member", "mac a"],
                       ["--plain", "--json"]] {
            #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["cluster"] + values) }
        }
    }

    @Test("a pair description reaches the other Mac over SSH: the developer harness's only")
    func wizardPairNeedsTheDeveloperFlag() throws {
        let pair = ClusterSetupRecord.Pair(description: "/Users/fixture/pair.json", capability: "/Users/fixture/capability.json",
            capabilitySHA256: pin, memberID: "mac-a")
        #expect(throws: (any Error).self) { try Cluster.Setup.requireDeveloperForPair(pair, environment: [:]) }
        #expect(throws: (any Error).self) { try Cluster.Setup.requireDeveloperForPair(pair, environment: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH": "yes"]) }
        try Cluster.Setup.requireDeveloperForPair(pair, environment: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH": "1"])
        try Cluster.Setup.requireDeveloperForPair(nil, environment: [:])
    }

    @Test("the other Mac's two questions are hidden subcommands with fixed, absolute arguments")
    func peerCommands() throws {
        let report = try #require(try Darkbloom.parseAsRoot(["cluster", "report", "--json", "--worker", "/Users/fixture/worker",
            "--model-dir", "/Users/fixture/models/m"]) as? Cluster.Report)
        #expect(report.json && report.worker == "/Users/fixture/worker" && report.modelDir == "/Users/fixture/models/m")
        #expect(try Darkbloom.parseAsRoot(["cluster", "inbox", "--receive"]) is Cluster.Inbox)
        for values in [["report"], ["report", "--json", "--worker", "relative"], ["inbox"], ["inbox", "--receive", "--approve"]] {
            #expect(throws: (any Error).self) { _ = try Darkbloom.parseAsRoot(["cluster"] + values) }
        }
        #expect(!Cluster.Report.configuration.shouldDisplay && !Cluster.Inbox.configuration.shouldDisplay)
    }
}
