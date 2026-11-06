import ArgumentParser
import Foundation
import ProviderCore

private func updateConfigReadFailureIsMissing(_ error: Error) -> Bool {
    let nsError = error as NSError
    return (nsError.domain == NSCocoaErrorDomain
        && nsError.code == CocoaError.Code.fileNoSuchFile.rawValue)
        || (nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.ENOENT.rawValue))
}

func loadUpdateConfig(configPath: String?) throws -> ProviderConfig {
    do {
        return try loadRuntimeSnapshot(configPath: configPath).config
    } catch ConfigError.readFailed(_, let underlying)
        where updateConfigReadFailureIsMissing(underlying)
    {
        return ConfigManager.loadDefault()
    }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for updates and self-update the provider binary, or roll back to the previous release."
    )

    @OptionGroup var configOptions: ConfigOptions
    @OptionGroup var drain: DrainOptions

    @Option(help: "Override coordinator URL.")
    var coordinator: String?

    @Flag(help: "Only check for updates without installing.")
    var checkOnly = false

    @Flag(
        name: .long,
        help: "Explicitly reinstall a locally quarantined version (failed starts or --rollback)."
    )
    var overrideQuarantine = false

    @Flag(help: "Restore the release this Mac ran before its last update and quarantine the installed one.")
    var rollback = false

    @Flag(name: .shortAndLong, help: "With --rollback: don't ask for confirmation.")
    var yes = false

    /// Tests run `update` as root without being root.
    @TaskLocal static var runsAsRootForTesting: Bool?

    /// Whether this process runs as root: `--rollback` refuses it.
    static var runsAsRoot: Bool { runsAsRootForTesting ?? (geteuid() == 0) }

    func validate() throws {
        if rollback, checkOnly || overrideQuarantine || coordinator != nil {
            throw ValidationError("--rollback cannot be combined with --check-only, --override-quarantine or --coordinator.")
        }
        if yes, !rollback {
            throw ValidationError("--yes applies only to --rollback.")
        }
    }

    mutating func run() async throws {
        // Run as root, the locks `--rollback` creates in this home would be root's, and the user's provider and cluster
        // service could no longer take them: it is refused before any work, so it draws no mark.
        let refusesRollbackAsRoot = rollback && Self.runsAsRoot
        let look = DarkbloomCommandLook.forCommand()
        if !refusesRollbackAsRoot { look.open("Darkbloom update") }
        let config = try loadUpdateConfig(configPath: configOptions.config)

        print("\(BuildEnvironment.current.cliName) update")
        print("Current version: \(ProviderCore.version)")
        print("")

        let coordinatorURL = coordinator ?? config.coordinator.url
        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)

        if rollback {
            guard !refusesRollbackAsRoot else {
                throw ValidationError("Run `\(BuildEnvironment.current.cliName) update --rollback` as the user the provider runs as, not as root.")
            }
            try await UpdateRollback(
                updater: updater,
                host: .live(drain: drain, configPath: configOptions.config),
                say: { print($0) }
            ).run(skipConfirmation: yes)
            return
        }

        if checkOnly {
            let manualOverride = overrideQuarantine
            let result = await look.working("Checking for updates") {
                await updater.checkForUpdate(manualOverride: manualOverride)
            }
            switch result {
            case .upToDate(let version):
                print("Up to date (v\(version)).")

            case .updateAvailable(let current, let latest):
                print("Update available: v\(current) -> v\(latest.version)")
                print("Download URL: \(latest.url)")
                print("Bundle SHA-256: \(latest.bundleHash)")
                if let binaryHash = latest.binaryHash {
                    print("Binary SHA-256: \(binaryHash)")
                }
                if let metallibHash = latest.metallibHash {
                    print("mlx.metallib SHA-256: \(metallibHash)")
                }
                print("")
                print("Run '\(BuildEnvironment.current.cliName) update' to install.")

            case .restartRequired(let current, let installed):
                print("v\(installed) is already installed on disk but this process is v\(current).")
                print("Restart the provider to activate the installed version.")

            case .quarantined(let version, let reason):
                print("Latest release v\(version) is quarantined on this machine.")
                print("Reason: \(reason)")
                print("A strictly newer release remains eligible automatically.")
                print("Use --override-quarantine only for an explicit operator retry.")

            case .checkFailed(let reason):
                printError("update check failed: \(reason)")
                throw ExitCode.failure
            }
            return
        }

        if overrideQuarantine {
            printError("WARNING: overriding the local release quarantine by explicit request.")
            printError("The quarantined release failed its starts or was rolled back; it may fail or regress again.")
        }
        print("Checking for updates...")
        let manualOverride = overrideQuarantine
        let result = await look.working("Checking, downloading and staging the update") {
            await updater.update(manualOverride: manualOverride)
        }

        switch result {
        case .alreadyUpToDate(let version):
            print("Already up to date (v\(version)).")

        case .updated(let from, let to):
            print("Updated: v\(from) -> v\(to)")
            switch Self.restartChoice() {
            case .pair:
                for line in Self.soloJobLeftLines { print(line) }
                try await restartClusterService(into: to, look: look)
            case .singleMac(let releaseLeftover):
                try await releaseLeftoverPart(releaseLeftover)
                try await restartInstalledProvider(updater, operation: "manual-update-restart", look: look)
            case .clusterService:
                try await restartClusterService(into: to, look: look)
            case .nothing:
                print("Restart the provider for the new version to take effect.")
            }

        case .restartRequired(let from, let to):
            print("v\(to) is already installed (current process: v\(from)).")
            switch Self.restartChoice() {
            case .pair:
                for line in Self.soloJobLeftLines { print(line) }
                try await restartClusterService(into: to, look: look)
            case .singleMac(let releaseLeftover):
                try await releaseLeftoverPart(releaseLeftover)
                try await restartInstalledProvider(updater, operation: "manual-candidate-restart", look: look)
            case .clusterService:
                try await restartClusterService(into: to, look: look)
            case .nothing:
                print("Restart the provider for v\(to) to take effect.")
            }

        case .quarantined(let version, let reason):
            printError("v\(version) is quarantined on this Mac: \(reason)")
            printError("A strictly newer release will install automatically.")
            printError("Use --override-quarantine for an explicit operator retry.")
            throw ExitCode.failure

        case .busy(let reason):
            printError("another update/recovery operation is active: \(reason)")
            throw ExitCode.failure

        case .cancelled(let reason):
            printError("update cancelled: \(reason)")
            throw ExitCode.failure

        case .downloadFailed(let reason):
            printError("download failed: \(reason)")
            throw ExitCode.failure

        case .hashMismatch(let expected, let got):
            printError("SHA-256 hash mismatch!")
            printError("  Expected: \(expected)")
            printError("  Got:      \(got)")
            printError("The downloaded binary may be corrupted or tampered with.")
            throw ExitCode.failure

        case .replaceFailed(let reason):
            printError("failed to replace binary: \(reason)")
            throw ExitCode.failure
        }
    }

    /// A single-Mac provider job is loaded on a Mac whose pair is started: the update restarts the pair, never that job
    /// (0.10.7 restarted it first, and it took the serving lock the pair's parts need: the pair could not start again).
    static func soloJobBesidePair(soloJobLoaded: Bool = LaunchAgent.isLoaded() && !LaunchAgent.installedJobIsClusterMember(),
                                  pairServes: Bool = ClusterService.pairServesHere()) -> Bool {
        soloJobLoaded && pairServes
    }

    /// What an update restarts.
    enum RestartChoice: Equatable {
        /// The pair, which runs here; a single-Mac job beside it is left as it is (`soloJobLeftLines`).
        case pair
        /// Single-Mac serving, which this Mac has; `releaseLeftover`: a pair that doesn't run here first gives back the
        /// serving lock its leftover part holds (`Start.releaseLeftoverPart`).
        case singleMac(releaseLeftover: Bool)
        case clusterService
        case nothing
    }

    /// The pair decides only while it runs here (`ClusterService.pairServesHere`), not by its saved start: a Mac whose
    /// other Mac stopped taking part gets its single-Mac serving back from an update.
    static func restartChoice(soloJobLoaded: Bool = LaunchAgent.isLoaded(),
                              soloJobIsMember: Bool = LaunchAgent.installedJobIsClusterMember(),
                              pairServes: Bool = ClusterService.pairServesHere(),
                              leftoverPart: Bool = leftoverPartHere(ClusterPairSummary.local()),
                              clusterServiceRunning: Bool = ClusterService.running()) -> RestartChoice {
        if soloJobBesidePair(soloJobLoaded: soloJobLoaded && !soloJobIsMember, pairServes: pairServes) { return .pair }
        if soloJobLoaded { return .singleMac(releaseLeftover: leftoverPart && !soloJobIsMember) }
        return clusterServiceRunning ? .clusterService : .nothing
    }

    /// A pair that doesn't run here while its saved start and cluster service are left on this Mac.
    static func leftoverPartHere(_ pair: ClusterPairSummary) -> Bool { pair.pairIdle && pair.started && pair.serviceRunning }

    private func releaseLeftoverPart(_ release: Bool) async throws {
        guard release else { return }
        let pair = ClusterPairSummary.local()
        print(pair.servingAloneLine)
        guard await Start.releaseLeftoverPart() else {
            for line in pair.releaseFailedLines { print(line) }
            throw ExitCode.failure
        }
    }

    static var soloJobLeftLines: [String] {
        let cli = BuildEnvironment.current.cliName
        return ["Single-Mac serving is also set up on this Mac, which serves in a two-Mac pair: the update leaves it as it is and "
                + "restarts the pair.",
                "It can't run beside the pair (both need this Mac's one serving lock). Run `\(cli) stop --solo` to remove it."]
    }

    private func restartInstalledProvider(_ updater: SelfUpdater, operation: String, look: DarkbloomCommandLook) async throws {
        let previous = LaunchAgent.launchSnapshot()?.process
        let session = try await look.working("Draining accepted requests") { try await ServiceDrain.prepare(options: drain) }
        defer { session.release() }
        // A stop that won the update lease while download/install completed
        // must not be resurrected by a late updater restart.
        guard LaunchAgent.isLoaded() else {
            print("Provider is stopped; the installed update will be used on the next start.")
            return
        }
        print("Accepted requests drained. Restarting the installed provider...")
        do {
            try await look.working("Restarting the provider") {
                try updater.prepareCandidateLaunch(session: session, baseline: LaunchAgent.launchSnapshot())
                try await ServiceDrain.stopDrainedProvider(unloadService: false)
                try LaunchAgent.restartAfterDrain()
            }
            ServiceDrain.rearmWatchdog(explicitConfig: configOptions.config)
        } catch {
            session.release()
            try? updater.cancelPendingCandidateAttempt(operation: operation + "-failure")
            throw error
        }
        session.release()
        try await look.working("Waiting for the restarted provider's fresh authorization") {
            try await ServiceDrain.waitForRestart(previous: previous, timeout: 180)
        }
    }

    /// A `darkbloom cluster` Mac: its cluster service supervisor restarts into the installed release together with
    /// the other Mac, after the pair drained, as at the pair's update slot (`ClusterPairUpdateCycle`).
    private func restartClusterService(into version: String, look: DarkbloomCommandLook) async throws {
        let directory = try ClusterService.paths().lock.deletingLastPathComponent()
        let request = ClusterPairUpdate.Request(createdAt: Date().timeIntervalSince1970)
        let outcome = try await look.working("Waiting for the cluster service") {
            try await ClusterServiceUpdateRequest.restart(into: version, request: request, serviceDirectory: directory,
                timeoutSeconds: drain.timeout, say: look.saying { print($0) })
        }
        guard outcome != .failed else { throw ExitCode.failure }
    }

}

/// `darkbloom update` asks the cluster service supervisor for the pair's restart into the installed release
/// (`ClusterPairUpdate.Request`) and follows its progress.
enum ClusterServiceUpdateRequest {
    enum Outcome: Equatable { case restarting, restarted, waiting, failed }

    static func restart(into version: String, request: ClusterPairUpdate.Request, serviceDirectory: URL, timeoutSeconds: Int,
                        pollSeconds: Double = 1, say: (String) -> Void) async throws -> Outcome {
        let progressPath = ClusterServiceAgent.updateProgressPath(serviceDirectory: serviceDirectory)
        // A supervisor of an earlier build neither publishes progress nor reads the request.
        guard ClusterPairUpdate.readProgress(from: progressPath) != nil else {
            say("This Mac's cluster service runs a build that does not restart for an update. Log out and back in on both Macs "
                + "(or restart them) once both have v\(version).")
            return .waiting
        }
        guard ClusterPairUpdate.writeRequest(request, to: ClusterServiceAgent.updateRequestPath(serviceDirectory: serviceDirectory)) else {
            throw ValidationError("Could not ask this Mac's cluster service to restart (\(serviceDirectory.path) is not writable).")
        }
        say("Asked this Mac's cluster service to restart into v\(version) together with the other Mac; the pair finishes its accepted requests first.")
        say("Run `\(ClusterPairSummary.cli) update` on the other Mac too (or wait for the pair's next update slot): both restart once both have v\(version).")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        var said: String?
        while Date() < deadline {
            // The restarted service publishes `idle` for the release it now runs, without the request; it may do so
            // before this command reads `restarting` (R5-3: the command waited out its whole timeout).
            if let progress = ClusterPairUpdate.readProgress(from: progressPath), Self.runs(version, progress.running) {
                say("This Mac's cluster service now runs v\(version); the cluster sets itself up again once both Macs run it.")
                return .restarted
            }
            if let progress = ClusterPairUpdate.readProgress(from: progressPath), progress.request == request.id {
                if progress.line != said {
                    said = progress.line
                    say("  \(progress.line)")
                }
                switch progress.phase {
                case .restarting:
                    say("The cluster service restarts into v\(version); the cluster sets itself up again once both Macs run it.")
                    return .restarting
                case .deferred, .failed:
                    say("Not restarted now. The pair tries again at its next update slot, or run `\(ClusterPairSummary.cli) update` again.")
                    return .failed
                default:
                    break
                }
            }
            try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
        }
        say("Still waiting after \(timeoutSeconds) s; the cluster service goes on by itself. Its log: \(ClusterUserPaths.serviceLogShown)")
        return .waiting
    }

    /// Whether the service's running version is the release asked for (either may carry a leading "v").
    static func runs(_ version: String, _ running: String) -> Bool {
        func bare(_ text: String) -> Substring { text.hasPrefix("v") ? text.dropFirst() : Substring(text) }
        return !version.isEmpty && bare(version) == bare(running)
    }
}
