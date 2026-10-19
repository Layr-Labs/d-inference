import Foundation
import ArgumentParser
import ProviderCore

extension Cluster.Setup {
    /// What `darkbloom cluster` (and `darkbloom cluster setup`) runs. On a terminal it is the onboarding, whatever
    /// the terminal type: the onboarding prints plain lines and reads keys through termios, so it needs no screen
    /// drawing. The line-by-line link setup is kept only for the options that ask for it (`--json`, `--yes`,
    /// `--temporary`, `--dry-run`, the hidden `--link-only`) and for `darkbloom cluster link`. With no terminal and
    /// none of those, one line says where to run it. `--wizard` (hidden, developer) opens the earlier six-step
    /// wizard where the terminal can draw it.
    enum Entry: Equatable { case onboarding, wizard, linkSetup, needsTerminal }

    static func entry(json: Bool, yes: Bool, temporary: Bool, dryRun: Bool, linkOnly: Bool, wizard: Bool,
                      inputIsTerminal: Bool, outputIsTerminal: Bool, terminalType: String?) -> Entry {
        if wizard, inputIsTerminal, outputIsTerminal, Cluster.Console.drawsScreens(terminalType), !json, !yes, !temporary { return .wizard }
        if json || yes || temporary || dryRun || linkOnly { return .linkSetup }
        guard inputIsTerminal && outputIsTerminal else { return .needsTerminal }
        return .onboarding
    }

    /// The one line `darkbloom cluster` prints when it is not run in a terminal.
    static let needsTerminalLine = "Run `darkbloom cluster` in a Terminal window on this Mac."

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
        let settings = try Self.liveSettings(config: configOptions.config, pair: pair, dryRun: dryRun, modelDir: modelDir, worker: worker)
        let operations = try ClusterSetupOperations.live(settings)
        return (operations, settings.providerConfiguration)
    }

    static func liveSettings(config: String?, pair: ClusterSetupRecord.Pair?, dryRun: Bool, modelDir: String?, worker: String?) throws
        -> ClusterSetupOperations.LiveSettings {
        let providerPath = URL(fileURLWithPath: try config ?? ConfigManager.defaultConfigPath().path)
        var settings = ClusterSetupOperations.LiveSettings(providerConfiguration: providerPath,
            darkbloomExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
            sessionArguments: ["start", "--local", "--distributed"] + (config.map { ["--config", $0] } ?? []),
            pair: pair, dryRun: dryRun, version: ProviderCore.version)
        settings.followerSessionArguments = ["cluster", "link-follower"] + (config.map { ["--config", $0] } ?? [])
        settings.modelsDirectory = modelDir
        settings.workerExecutable = worker
        return settings
    }

    /// The service settings both the onboarding and `darkbloom cluster service` use.
    static func serviceSettings(config: String?, modelDir: String?, worker: String?) throws -> ClusterService.Settings {
        let wizard = try liveSettings(config: config, pair: nil, dryRun: false, modelDir: modelDir, worker: worker)
        // Degraded serving on this Mac alone (failover): the ordinary single-Mac local server with this Mac's own
        // configuration and identity; the cluster service adds the model and the port.
        return ClusterService.Settings(wizard: wizard, leaderArguments: wizard.sessionArguments, followerArguments: wizard.followerSessionArguments,
            soloArguments: ["start", "--local"] + (config.map { ["--config", $0] } ?? []))
    }

    /// Pure CLI-to-live-settings binding, before creating stores, services or children.
    static func onboardingSettings(config: String?, modelDir: String?, worker: String?, request: ClusterOnboardingRequest)
        throws -> ClusterOnboardingOperations.LiveSettings {
        if let refusal = request.privateQualificationInputRefusal { throw ValidationError(refusal) }
        var service = try Self.serviceSettings(config: config, modelDir: modelDir, worker: worker)
        service.wizard.privateMiMoImageQualification = request.privateMiMoImageQualification
        service.wizard.privateGLMImageQualification = request.privateGLMImageQualification
        let arguments = ["cluster", "service"] + (config.map { ["--config", $0] } ?? [])
            + (worker.map { ["--worker", $0] } ?? [])
        return .init(service: service, serviceArguments: arguments)
    }

    /// Bare `darkbloom cluster` on a terminal: the leader-first onboarding (`darkbloom cluster local` asks it for
    /// local-only serving). Run again, it shows where this Mac stands and the next step.
    static func runOnboarding(config: String?, modelDir: String?, worker: String?, request: ClusterOnboardingRequest) async throws {
        Darkbloom.ensureLogging()
        let settings = try onboardingSettings(config: config, modelDir: modelDir, worker: worker, request: request)
        let operations = try ClusterOnboardingOperations.live(settings)
        let instance: ClusterConsoleInstanceLock
        do { instance = try ClusterConsoleInstanceLock.acquire() } catch let held as ClusterConsoleInstanceLock.Held {
            fputs(held.description + "\n", stderr)
            throw ExitCode.failure
        }
        let code = await Task.detached {
            let console = ClusterOnboardingTerminal(input: STDIN_FILENO, output: STDOUT_FILENO)
            defer { console.restore() }
            return ClusterOnboardingDriver.run(operations, console: console, request: request)
        }.value
        withExtendedLifetime(instance) {}
        if code != 0 { throw ExitCode(code) }
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
