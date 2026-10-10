import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// Registered by adding `Console.self` to `Cluster.configuration.subcommands`.
    /// Bare `darkbloom cluster` in a terminal opens it too; see `replacesGuidedSetup`.
    struct Console: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "console",
            abstract: "Show this Mac's cluster readiness, pairing, model and session on one screen, and run the cluster commands from it.",
            discussion: """
                Everything on the screen is read from this Mac when the screen opens and again when you press r. \
                Each action runs an existing command: f is `cluster link --fix`, which gives the port its \
                address and installs the system job that keeps it, a is `cluster configure` on the \
                setup passed with --input, s is `start --local --distributed`, x interrupts the session this screen \
                started, c is `cluster recover`, and e writes a redacted diagnostics file into the current \
                directory. Nothing is trusted, started or cleared without a key. The one exception is the link: \
                when the port only lacks an address, or nothing keeps the one it has, opening the screen asks \
                macOS for approval once, as the guided setup does. With --json or --plain, or when not run in a \
                terminal, the same state is printed and the command exits.
                """)
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Print the state as one JSON object and exit.") var json = false
        @Flag(help: "Print the state as text and exit.") var plain = false
        @Flag(name: .customLong("dry-run"),
              help: "The link fix lists the commands an approval would run: nothing is asked, recorded or changed.")
        var dryRun = false
        @Flag(help: "The link fix adds the address alone, without the system job that keeps it.")
        var temporary = false
        @Option(help: "Absolute path to a cluster configuration JSON to review on the screen and approve with a key.")
        var input: String?
        @Option(help: "Absolute path to that setup's installed-runtime capability JSON.")
        var capability: String?
        @Option(name: .customLong("capability-sha256"), help: "Expected SHA-256 of the exact capability bytes.")
        var capabilitySHA256: String?

        func validate() throws {
            guard !(json && plain) else { throw ValidationError("Choose at most one of --json and --plain.") }
            let given = [input, capability, capabilitySHA256].compactMap { $0 }
            guard given.isEmpty || given.count == 3 else {
                throw ValidationError("A setup to approve needs --input, --capability and --capability-sha256 together.")
            }
            for path in [input, capability, configOptions.config].compactMap({ $0 }) { _ = try Self.absolute(path) }
            if let capabilitySHA256 {
                guard capabilitySHA256.utf8.count == 64, capabilitySHA256.utf8.allSatisfy({
                    (48...57).contains($0) || (97...102).contains($0)
                }) else { throw ValidationError("Expected a lowercase SHA-256 capability pin.") }
            }
        }

        mutating func run() async throws { try await run(asGuidedSetup: false) }

        /// Bare `darkbloom cluster` in a terminal: the same screen, ending as
        /// the guided setup ends, with a failure status unless the link is ready.
        static func runAsGuidedSetup() async throws {
            let console = try Console.parse([])
            try await console.run(asGuidedSetup: true)
        }

        private func run(asGuidedSetup: Bool) async throws {
            Darkbloom.ensureLogging()
            let providerPath = try configOptions.config ?? ConfigManager.defaultConfigPath().path
            var candidate: ClusterConsoleCandidate?
            if let input, let capability, let capabilitySHA256 {
                candidate = .init(configurationInput: try Self.absolute(input), capabilityInput: try Self.absolute(capability),
                    capabilitySHA256: capabilitySHA256)
            }
            let options = ClusterConsoleState.Options(dryRun: dryRun, temporary: temporary)
            let operations = try ClusterConsoleOperations.live(.init(
                providerConfiguration: try Self.absolute(providerPath), candidate: candidate,
                darkbloomExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                sessionArguments: ["start", "--local", "--distributed"] + (configOptions.config.map { ["--config", $0] } ?? []),
                exportDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), options: options))

            guard Self.opensScreen(json: json, plain: plain, inputIsTerminal: isatty(STDIN_FILENO) == 1,
                                   outputIsTerminal: isatty(STDOUT_FILENO) == 1,
                                   terminalType: ProcessInfo.processInfo.environment["TERM"]) else {
                let snapshot = try await Self.onOwnThread { operations.snapshot() }
                if json { try printJSON(snapshot) } else { for line in snapshot.plainLines { print(line) } }
                return
            }
            let instance: ClusterConsoleInstanceLock
            do { instance = try ClusterConsoleInstanceLock.acquire() } catch let held as ClusterConsoleInstanceLock.Held {
                Self.report(held.description)
                throw ExitCode.failure
            }
            let configuration = ClusterConsoleRunLoop.Configuration(options: options, candidate: candidate,
                color: ProcessInfo.processInfo.environment["NO_COLOR"] == nil, darkbloomVersion: ProviderCore.version)
            let exit: ClusterConsoleExit
            do {
                exit = try await Self.onOwnThread {
                    try ClusterConsoleRunLoop.run(input: STDIN_FILENO, output: STDOUT_FILENO,
                        configuration: configuration, operations: operations)
                }
            } catch let failure as ClusterConsoleRunLoop.Failure {
                Self.report(failure.description)
                throw ExitCode.failure
            }
            withExtendedLifetime(instance) {}
            for line in exit.farewell { print(line) }
            if exit.code != 0 { throw ExitCode(exit.code) }
            // The guided setup's status says whether the link is ready, so a
            // command chained after `darkbloom cluster` does not run on a
            // link that is not. It is read once more, now, not remembered.
            if asGuidedSetup {
                let link = try await Self.onOwnThread { operations.inspectLink() }
                if link.state != .ready {
                    print("This Mac's link is not ready (\(link.state.rawValue)); `darkbloom cluster link` shows it.")
                    throw ExitCode.failure
                }
            }
        }

        /// A line on standard error that cannot raise when the terminal has
        /// gone away, as a file handle's write does.
        private static func report(_ text: String) {
            fputs(text + "\n", stderr)
        }

        /// The probes and the screen block: on tools, on files, on the
        /// terminal. Each runs on a thread of its own, never on one the
        /// concurrency runtime needs back.
        private static func onOwnThread<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
            }
        }

        /// The screen needs a terminal on both ends that can address its
        /// cursor; anything else gets the printed state.
        static func opensScreen(json: Bool, plain: Bool, inputIsTerminal: Bool, outputIsTerminal: Bool,
                                terminalType: String?) -> Bool {
            !json && !plain && inputIsTerminal && outputIsTerminal && drawsScreens(terminalType)
        }

        /// A terminal that says it is one, and not one that only prints lines.
        static func drawsScreens(_ terminalType: String?) -> Bool {
            guard let terminalType, !terminalType.isEmpty else { return false }
            return terminalType != "dumb" && terminalType != "unknown"
        }

        /// Whether bare `darkbloom cluster` opens the console instead of the
        /// line-by-line guided setup. Only in a terminal, and only when none
        /// of the setup's own flags was given: with any of them, and as
        /// `darkbloom cluster setup`, it is always the line-by-line flow; so it
        /// is on a terminal that cannot draw a screen.
        /// `setup` takes no values, so the word can only be the subcommand's name.
        static func replacesGuidedSetup(arguments: [String], json: Bool, yes: Bool, temporary: Bool, dryRun: Bool,
                                        inputIsTerminal: Bool, outputIsTerminal: Bool, terminalType: String?) -> Bool {
            !json && !yes && !temporary && !dryRun && inputIsTerminal && outputIsTerminal && drawsScreens(terminalType)
                && !arguments.dropFirst().contains("setup")
        }

        private static func absolute(_ path: String) throws -> URL {
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw ValidationError("The cluster console requires absolute local paths.")
            }
            return URL(fileURLWithPath: path)
        }
    }
}
