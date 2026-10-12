import Foundation
import ArgumentParser
import ProviderCore

extension Cluster.Setup {
    /// Whether bare `darkbloom cluster` opens the setup wizard: only on a
    /// terminal at both ends that can draw a screen, and not with an option
    /// that asks for the unattended line-by-line flow (`--json`, `--yes`,
    /// `--temporary`) or for printed output (`--plain`). As `darkbloom
    /// cluster setup` it is always the line-by-line flow. `--dry-run` opens
    /// the wizard with the link fix limited to its preview.
    static func opensWizard(arguments: [String], json: Bool, yes: Bool, temporary: Bool, plain: Bool,
                            inputIsTerminal: Bool, outputIsTerminal: Bool, terminalType: String?) -> Bool {
        !json && !yes && !temporary && !plain && inputIsTerminal && outputIsTerminal
            && Cluster.Console.drawsScreens(terminalType) && !arguments.dropFirst().contains("setup")
    }

    /// The pair the wizard was given, all four options or none.
    func wizardPair() throws -> ClusterSetupRecord.Pair? {
        let given = [pair, capability, capabilitySHA256, member].compactMap { $0 }
        guard !given.isEmpty else { return nil }
        guard given.count == 4, let pair, let capability, let capabilitySHA256, let member else {
            throw ValidationError("A pair needs --pair, --capability, --capability-sha256 and --member together.")
        }
        return .init(description: pair, capability: capability, capabilitySHA256: capabilitySHA256, memberID: member)
    }

    func validateWizardOptions() throws {
        let pairGiven = try wizardPair() != nil
        // The line-by-line link setup chooses the port and the address itself and serves nothing:
        // the provider configuration and the pair are the wizard's alone.
        if json || yes || temporary, configOptions.config != nil || pairGiven {
            throw ValidationError("--config and the pair options belong to the setup wizard; the link setup (--json, --yes, --temporary) takes neither.")
        }
        if (json || yes || temporary), modelDir != nil || worker != nil {
            throw ValidationError("--model-dir and --worker belong to the setup wizard.")
        }
        for path in [pair, capability, configOptions.config, modelDir, worker].compactMap({ $0 }) {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError("The setup wizard requires absolute local paths.") }
        }
        if let capabilitySHA256 {
            guard capabilitySHA256.utf8.count == 64, capabilitySHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ValidationError("Expected a lowercase SHA-256 capability pin.")
            }
        }
        if let member {
            guard !member.isEmpty, member.utf8.count <= 64, !member.hasPrefix("-"), member.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }) else { throw ValidationError("Expected a member ID of letters, digits, '-', '.' and '_'.") }
        }
        guard !(plain && json) else { throw ValidationError("Choose at most one of --json and --plain.") }
    }

    /// The pair description reaches the other Mac over SSH: the developer harness's route only
    /// (`DARKBLOOM_CLUSTER_DEVELOPER_SSH=1`). The user path pairs over the link (step 3) and plans
    /// over the paired link (step 4).
    static func requireDeveloperForPair(_ pair: ClusterSetupRecord.Pair?, environment: [String: String]) throws {
        guard pair != nil, !DistributedInstalledDeveloperSSH.enabled(environment) else { return }
        throw ValidationError("darkbloom cluster needs no pair description: open it on both Macs, pair over the cable in step 3, and plan in step 4.")
    }

    func wizardOperations(pair: ClusterSetupRecord.Pair?) throws -> (operations: ClusterSetupOperations, providerPath: URL) {
        try Self.requireDeveloperForPair(pair, environment: ProcessInfo.processInfo.environment)
        let providerPath = URL(fileURLWithPath: try configOptions.config ?? ConfigManager.defaultConfigPath().path)
        var settings = ClusterSetupOperations.LiveSettings(providerConfiguration: providerPath,
            darkbloomExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
            sessionArguments: ["start", "--local", "--distributed"] + (configOptions.config.map { ["--config", $0] } ?? []),
            pair: pair, dryRun: dryRun, version: ProviderCore.version)
        settings.followerSessionArguments = ["cluster", "link-follower"] + (configOptions.config.map { ["--config", $0] } ?? [])
        settings.modelsDirectory = modelDir
        settings.workerExecutable = worker
        let operations = try ClusterSetupOperations.live(settings)
        return (operations, providerPath)
    }

    /// `darkbloom cluster --plain`: the six steps as text, and nothing started or asked.
    func printWizardPlain() async throws {
        Darkbloom.ensureLogging()
        let operations = try wizardOperations(pair: try wizardPair()).operations
        let snapshot = await Task.detached { operations.snapshot() }.value
        for line in snapshot.plainLines(dryRun: dryRun) { print(line) }
    }

    /// The interactive wizard. The pair given on the command line is
    /// remembered in the wizard's record, so the next run needs no options.
    func runWizard() async throws {
        Darkbloom.ensureLogging()
        let pair = try wizardPair()
        if let pair {
            let paths = try ClusterUserPaths()
            try ClusterSetupStore(paths: .init(paths: paths)).updateRecord { $0.pair = pair }
        }
        let operations = try wizardOperations(pair: pair).operations
        let instance: ClusterConsoleInstanceLock
        do { instance = try ClusterConsoleInstanceLock.acquire() } catch let held as ClusterConsoleInstanceLock.Held {
            fputs(held.description + "\n", stderr)
            throw ExitCode.failure
        }
        let environment = ProcessInfo.processInfo.environment
        let configuration = ClusterSetupRunLoop.Configuration(options: .init(dryRun: dryRun),
            color: environment["NO_COLOR"] == nil, glyphs: ClusterSetupGlyphs.forEnvironment(environment))
        let exit: ClusterConsoleExit
        do {
            exit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClusterConsoleExit, Error>) in
                Thread.detachNewThread {
                    continuation.resume(with: Result { try ClusterSetupRunLoop.run(input: STDIN_FILENO, output: STDOUT_FILENO,
                        configuration: configuration, operations: operations) })
                }
            }
        } catch let failure as ClusterConsoleRunLoop.Failure {
            fputs(failure.description + "\n", stderr)
            throw ExitCode.failure
        }
        withExtendedLifetime(instance) {}
        for line in exit.farewell { print(line) }
        if exit.code != 0 { throw ExitCode(exit.code) }
    }
}

extension Cluster {
    /// `darkbloom cluster report --json`: this Mac's own report for the setup
    /// wizard, which the other Mac's wizard asks for over the pinned SSH
    /// route. Read-only: nothing is started, asked or written.
    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "report",
            abstract: "Print this Mac's setup report (hardware, cable, saved setup, models, memory) as JSON.",
            shouldDisplay: false)
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Print the report as one JSON object.") var json = false
        @Option(help: "Absolute path of this Mac's worker, for a Mac with no setup yet.") var worker: String?
        @Option(name: .customLong("model-dir"), help: "Absolute path of this Mac's model directory, for a Mac with no setup yet.")
        var modelDir: String?

        func validate() throws {
            guard json else { throw ValidationError("The setup report is printed as JSON: pass --json.") }
            for path in [worker, modelDir, configOptions.config].compactMap({ $0 }) {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError("The setup report takes absolute paths.") }
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let providerPath = URL(fileURLWithPath: try configOptions.config ?? ConfigManager.defaultConfigPath().path)
            let worker = worker, modelDir = modelDir
            let report = try await Task.detached {
                try ClusterSetupReporting.report(providerConfiguration: providerPath, version: ProviderCore.version,
                    workerExecutable: worker, modelDirectory: modelDir)
            }.value
            FileHandle.standardOutput.write(try report.encoded())
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// `darkbloom cluster inbox --receive`: takes the setup the leader's
    /// wizard sends over the pinned route, checks it with the strict codecs,
    /// and keeps it for this Mac's person to approve. It approves nothing.
    struct Inbox: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "inbox",
            abstract: "Receive a setup from the leader for this Mac to approve; nothing is saved or trusted until then.",
            shouldDisplay: false)
        @Flag(help: "Read one setup delivery from standard input.") var receive = false

        func validate() throws {
            guard receive else { throw ValidationError("Pass --receive.") }
        }

        mutating func run() async throws {
            let data = FileHandle.standardInput.readData(ofLength: ClusterSetupStore.Delivery.maximumBytes + 1)
            let paths = try ClusterUserPaths()
            let digest = try ClusterSetupStore(paths: .init(paths: paths)).receive(data)
            print(digest)
        }
    }
}
