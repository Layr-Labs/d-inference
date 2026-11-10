import ArgumentParser
import Darwin
import Foundation
import ProviderCore

/// `darkbloom uninstall`: remove everything, or everything but the models. `ProviderUninstall` owns the steps, their
/// order and every path rule; this command asks, and wires the commands it reuses: `stop`'s drain, `cluster stop --service`,
/// `stop --uninstall`'s agents, `logout`'s token revocation, `cluster pair --forget` and `cluster link --remove`.
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take Darkbloom off this Mac: remove everything, or keep the models.",
        discussion: """
            In a terminal without options, it shows both choices with this Mac's sizes and asks. Both stop serving, \
            remove every Darkbloom background service, revoke this Mac's account token, unpair, undo the cable port \
            setup (macOS asks for an administrator's password) and delete Darkbloom's settings, logs, caches, the \
            app and the command link. --everything also deletes the models Darkbloom downloaded; --keep-models keeps \
            them, so a reinstall finds them. Choosing 1 on the screen asks once more before deleting the models. A \
            models folder you chose, and the cluster model store beside it, are never deleted, even inside \
            Darkbloom's own folder; nor are Keychain keys. Run it as yourself, not with sudo. With both the \
            production and the DevNet app on this Mac, each removes only its own pairing, cluster setup and cluster \
            service; the cable port setup stays for the other one.
            """)

    @Flag(help: "Remove everything: the app, settings, pairing, logs and all models.")
    var everything = false
    @Flag(name: .customLong("keep-models"), help: "Remove everything but the models, so a reinstall reuses them.")
    var keepModels = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false
    @Flag(name: .customLong("dry-run"), help: "List every action and path with sizes, and change nothing.")
    var dryRun = false
    @Flag(help: "With --dry-run: print the plan as JSON.")
    var json = false
    @OptionGroup var drain: DrainOptions

    func validate() throws {
        guard !(keepModels && everything) else { throw ValidationError("Choose one of --everything and --keep-models.") }
        guard !json || dryRun else { throw ValidationError("--json goes with --dry-run.") }
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let invocation = ProviderUninstall.invocation(everything: everything, keepModels: keepModels, yes: yes,
                                                      dryRun: dryRun, interactive: interactive, userID: geteuid())
        if case .refuse(let line) = invocation {
            printError(line)
            throw ExitCode.validationFailure
        }
        let plan = Self.plan()
        if case .dryRun = invocation {} else if plan.cableKeptFor == nil, Self.cableNeedsPromptNoOneCanSee() {
            // Before anything is stopped or deleted: the cable step's prompt cannot show over SSH, and the uninstall
            // would otherwise stop part way, after the services and the pairing.
            ClusterLinkApprovalSession.lines(command: "darkbloom uninstall").forEach { print($0) }
            print("\(ClusterOnboardingDriver.failed) Nothing changed.")
            throw ExitCode.failure
        }
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
            guard let chosen = Self.choose() else { print("Nothing changed."); return }
            if chosen == .everything {
                print(ProviderUninstall.everythingQuestion(plan), terminator: "")
                fflush(stdout)
                guard ProviderUninstall.confirmed(readLine()) else { print("Nothing changed."); return }
            }
            mode = chosen
        case .run(let given, let confirm):
            mode = given
            if confirm {
                ProviderUninstall.dryRun(plan, mode: mode).forEach { print($0) }
                guard Self.confirm() else { print("Nothing changed."); return }
            }
        }
        let report = await ProviderUninstall.run(mode, items: plan.items, pairing: plan.pairing, cableKeptFor: plan.cableKeptFor,
                                                 operations: Self.operations(drain: drain)) { print("→ \($0)") }
        print("")
        ProviderUninstall.summary(report, plan: plan).forEach { print($0) }
        if report.failed || report.incomplete { throw ExitCode.failure }
    }

    /// Over SSH with no desktop, a cable port setup to undo needs a macOS prompt that cannot show (a dry run tells,
    /// changing nothing).
    static func cableNeedsPromptNoOneCanSee() -> Bool {
        ClusterLinkApprovalSession.cannotPrompt() && ClusterLinkRepair.remove(device: nil, dryRun: true).outcome == .dryRun
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
        let paths = ProviderUninstallPaths.live(config: config, configPath: configPath)
        return .init(clusterService: ClusterServiceAgent.installedLabels().map { ClusterServiceAgent.plistPath(label: $0).path },
                     runningClusterService: ProviderUninstall.liveRunningClusterService(paths: paths),
                     services: agents.map { .init(name: $0.0, path: FileManager.default.fileExists(atPath: $0.1.path) ? $0.1.path : nil) },
                     items: ProviderUninstall.inventory(paths),
                     pairing: ProviderUninstallPairing.read(),
                     elsewhere: elsewhere, cableKeptFor: paths.otherEnvironment)
    }

    /// The live steps, each through the command or function that does it today.
    static func operations(drain: DrainOptions) -> ProviderUninstall.Operations {
        let lifecycle = LifecycleHold()
        let executable = URL(fileURLWithPath: Start.currentExecutablePath())
        return .init(
            stopServing: {
                let wasLoaded = LaunchAgent.isLoaded()
                // Single-Mac serving only: a daemon state the cluster's part wrote is the cluster step's.
                lifecycle.session = try await ServiceDrain.prepare(options: drain, state: ServiceDrain.soloProviderState())
                try await ServiceDrain.stopDrainedProvider(daemonState: ServiceDrain.soloProviderState())
                return wasLoaded ? .done() : .skipped("the provider service was not running")
            },
            // As `darkbloom cluster leave` stops it: the summary's last line says what to do on the other Mac.
            stopClusterPart: { try await Cluster.Stop.beforeUnpairing(executable: executable, say: { print($0) }).outcome },
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
            revokeToken: {
                // `darkbloom logout`'s revocation. The token file goes with ~/.darkbloom.
                guard let token = AuthTokenStore.load() else { return .skipped("no saved account token") }
                return await Logout.revokeSavedToken(token) ? .done()
                    : .skipped("the coordinator did not confirm it (offline, or the token's issuer is unknown)")
            },
            forget: Cluster.Pair.forget(pin:),
            removeCableSetup: {
                let result = ClusterLinkRepair.remove(device: nil)
                if result.outcome == .approvalUnavailable, ClusterLinkApprovalSession.cannotPrompt() {
                    // No prompt was tried over SSH: where to run the uninstall so that it can show.
                    ClusterLinkApprovalSession.lines(command: "darkbloom uninstall").forEach { print($0) }
                }
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
            },
            runningClusterService: {
                ProviderUninstall.liveRunningClusterService(paths: ProviderUninstallPaths(home: FileManager.default.homeDirectoryForCurrentUser))
            })
    }

    /// The drain's lease, held until the services are removed, so an update cannot start the provider in between.
    private final class LifecycleHold: @unchecked Sendable {
        var session: SelfUpdater.UpdateSession?
        func release() { session?.release(); session = nil }
    }

    /// Reads keys without Enter until one decides (`ProviderUninstall.key`); nil to cancel.
    static func choose() -> ProviderUninstall.Mode? {
        print(ProviderUninstall.choicePrompt, terminator: "")
        fflush(stdout)
        var saved = termios()
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved) }
        while true {
            var buffer = [UInt8](repeating: 0, count: 8)
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            switch ProviderUninstall.key(Array(buffer.prefix(max(0, count)))) {
            case .choose(let mode)?: print(mode == .everything ? "1" : "2"); return mode
            case .cancel?: print("Esc"); return nil
            case nil: continue
            }
        }
    }

    /// A mode given as a flag, in a terminal without --yes: y or yes goes on.
    static func confirm(readInput: () -> String? = { readLine() }) -> Bool {
        print("Continue? [y/N]: ", terminator: "")
        fflush(stdout)
        return ProviderUninstall.confirmed(readInput())
    }
}
