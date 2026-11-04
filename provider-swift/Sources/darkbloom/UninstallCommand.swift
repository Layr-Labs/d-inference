import ArgumentParser
import Darwin
import Foundation
import ProviderCore

/// `darkbloom uninstall`: keep models and settings (you might come back), or remove everything (not coming back).
/// `ProviderUninstall` owns the steps, their order and every path rule; this command asks, and wires the commands it
/// reuses: `stop`'s drain, `cluster stop`, `stop --uninstall`'s agents, `cluster pair --forget` and `cluster link --remove`.
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take Darkbloom off this Mac: keep models and settings, or remove everything.",
        discussion: """
            In a terminal without options, it shows what each choice removes, with sizes, and asks. \
            --keep-data stops serving and removes Darkbloom's background services (the provider, its watchdog, the \
            desktop API and this Mac's cluster service) and keeps every file: install again, then run \
            `\(BuildEnvironment.current.cliName) start` or `\(BuildEnvironment.current.cliName) cluster` to come back. \
            --everything also forgets this Mac's pairing, undoes the cable port setup (macOS asks for an \
            administrator's password) and deletes Darkbloom's folders: settings, the models it downloaded, caches, \
            logs and the app. Models in a folder you chose are kept, and Keychain keys are never deleted.
            """)

    @Flag(name: .customLong("keep-data"), help: "Keep models and settings (you might come back).")
    var keepData = false
    @Flag(help: "Remove everything (not coming back): unpair, undo the cable port setup, delete Darkbloom's folders.")
    var everything = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false
    @Flag(name: .customLong("dry-run"), help: "List every action and path with sizes, and change nothing.")
    var dryRun = false
    @Flag(help: "With --dry-run: print the plan as JSON.")
    var json = false
    @OptionGroup var drain: DrainOptions

    func validate() throws {
        guard !(keepData && everything) else { throw ValidationError("Choose one of --keep-data and --everything.") }
        guard !json || dryRun else { throw ValidationError("--json goes with --dry-run.") }
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let invocation = ProviderUninstall.invocation(keepData: keepData, everything: everything, yes: yes,
                                                      dryRun: dryRun, interactive: interactive)
        if case .refuse(let line) = invocation {
            printError(line)
            throw ExitCode.validationFailure
        }
        let plan = Self.plan()
        let mode: ProviderUninstall.Mode
        switch invocation {
        case .refuse: return
        case .dryRun(let modes):
            if json { try printJSON(ProviderUninstall.dryRunDocument(plan, modes: modes)); return }
            for (index, mode) in modes.enumerated() {
                if index > 0 { print("") }
                ProviderUninstall.dryRun(plan, mode: mode).forEach { print($0) }
            }
            return
        case .ask:
            ProviderUninstall.screen(plan).forEach { print($0) }
            guard let chosen = Self.choose(), chosen == .keepData || Self.confirm(chosen) else {
                print("Nothing changed.")
                return
            }
            mode = chosen
        case .run(let given, let confirm):
            mode = given
            if confirm {
                ProviderUninstall.dryRun(plan, mode: mode).forEach { print($0) }
                guard Self.confirm(mode) else { print("Nothing changed."); return }
            }
        }
        let report = await ProviderUninstall.run(mode, items: plan.items, pairing: plan.pairing,
                                                 operations: Self.operations(drain: drain)) { print("→ \($0)") }
        print("")
        ProviderUninstall.summary(report, plan: plan).forEach { print($0) }
        if report.failed { throw ExitCode.failure }
    }

    /// What this Mac has, read before anything changes.
    static func plan() -> ProviderUninstall.Plan {
        let configPath = ConfigManager.defaultConfigPath(home: FileManager.default.homeDirectoryForCurrentUser)
        let config = FileManager.default.fileExists(atPath: configPath.path) ? try? ConfigManager.load(from: configPath) : nil
        let agents: [(String, URL)] = [("provider service", LaunchAgent.plistPath()), ("watchdog service", WatchdogAgent.plistPath()),
                                       ("desktop API service", DesktopService.plistPath())]
        var elsewhere: [String] = []
        let cli = BuildEnvironment.current.cliName
        if FanServiceManager().isInstalled() {
            elsewhere.append("The fan helper stays (a system service every Darkbloom install shares); "
                + "to remove it, run `sudo \(cli) fan uninstall` before removing everything.")
        }
        let sandbox = SandboxAddon.live()
        if sandbox.isInstalled {
            elsewhere.append("Darkbloom Sandbox stays (\(sandbox.root.path)); to remove it, run `\(cli) sandbox uninstall` "
                + "before removing everything.")
        }
        return .init(clusterService: ClusterServiceAgent.installedLabels().map { ClusterServiceAgent.plistPath(label: $0).path },
                     services: agents.map { .init(name: $0.0, path: FileManager.default.fileExists(atPath: $0.1.path) ? $0.1.path : nil) },
                     items: ProviderUninstall.inventory(.live(config: config, configPath: configPath)),
                     pairing: ProviderUninstallPairing.read(),
                     elsewhere: elsewhere)
    }

    /// The live steps, each through the command or function that does it today.
    static func operations(drain: DrainOptions) -> ProviderUninstall.Operations {
        let lifecycle = LifecycleHold()
        let executable = URL(fileURLWithPath: Start.currentExecutablePath())
        return .init(
            stopServing: {
                let wasLoaded = LaunchAgent.isLoaded()
                lifecycle.session = try await ServiceDrain.prepare(options: drain)
                try await ServiceDrain.stopDrainedProvider()
                return wasLoaded ? .done() : .skipped("the provider service was not running")
            },
            stopClusterPart: {
                let current = ClusterServiceAgentPlan.label(executablePath: ClusterService.resolvedExecutable(executable))
                guard !ClusterServiceAgent.installedLabels().isEmpty || ClusterServiceAgent.isLoaded(label: current)
                        || ClusterService.running() else { return .skipped("no cluster service on this Mac") }
                do {
                    var stop = try Cluster.Stop.parse([])
                    try await stop.run()
                    return .done()
                } catch {
                    // The pair could not stop together (the other Mac did not answer): this Mac is leaving, so stop
                    // only its own part, as `cluster stop --local-only` does when the other Mac is gone.
                    var stop = try Cluster.Stop.parse(["--local-only"])
                    try await stop.run()
                    return .done("the other Mac was not asked to stop (\(error))")
                }
            },
            removeServices: [
                ("Remove the provider service", {
                    try ProviderUninstall.removeAgent(plist: LaunchAgent.plistPath(), loaded: LaunchAgent.isLoaded(),
                                                      uninstall: LaunchAgent.uninstall)
                }),
                ("Remove the watchdog service", {
                    try ProviderUninstall.removeAgent(plist: WatchdogAgent.plistPath(), loaded: WatchdogAgent.isLoaded(),
                                                      uninstall: WatchdogAgent.uninstall)
                }),
                ("Remove the desktop API service", {
                    try ProviderUninstall.removeAgent(plist: DesktopService.plistPath(),
                                                      loaded: LaunchAgent.isLoaded(agentLabel: DesktopService.label),
                                                      uninstall: { try DesktopService.uninstall() })
                }),
            ],
            servicesHandled: { lifecycle.release() },
            forget: { pin in try Cluster.Pair.parse(["--forget", pin]).run() },
            removeCableSetup: {
                let result = ClusterLinkRepair.remove(device: nil)
                result.summaryLines.forEach { print($0) }
                // As `cluster link --remove` prints them: where no prompt could be, the commands go to standard error.
                if let script = result.manualScript {
                    fflush(stdout); printError("sudo sh \(script)")
                } else if !result.manualCommands.isEmpty {
                    fflush(stdout); result.manualCommands.forEach { printError($0) }
                }
                guard result.outcome.exitCode == 0 else { throw ProviderUninstall.StepFailure(result.message) }
                return result.outcome == .removed ? .done() : .skipped("nothing to undo")
            },
            availableBytes: {
                let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                return values?.volumeAvailableCapacity.map(Int64.init)
            })
    }

    /// The drain's lease, held until the services are removed, so an update cannot start the provider in between.
    private final class LifecycleHold: @unchecked Sendable {
        var session: SelfUpdater.UpdateSession?
        func release() { session?.release(); session = nil }
    }

    /// 1, 2 or 3 from the screen; nil to cancel.
    static func choose(readInput: () -> String? = { readLine() }) -> ProviderUninstall.Mode? {
        print("Choose 1-3: ", terminator: "")
        fflush(stdout)
        switch readInput()?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .keepData
        case "2": return .everything
        default: return nil
        }
    }

    /// Removing everything takes the word yes; keeping data takes y or yes.
    static func confirm(_ mode: ProviderUninstall.Mode, readInput: () -> String? = { readLine() }) -> Bool {
        print(mode == .everything ? "Delete these files and unpair this Mac? Type yes to continue: " : "Continue? [y/N]: ",
              terminator: "")
        fflush(stdout)
        let answer = readInput()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return mode == .everything ? answer == "yes" : ["y", "yes"].contains(answer)
    }
}
