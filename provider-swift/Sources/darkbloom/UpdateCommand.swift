import ArgumentParser
import ProviderCore

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for updates and self-update the provider binary."
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator URL.")
    var coordinator: String?

    @Flag(help: "Only check for updates without installing.")
    var checkOnly = false

    @Flag(
        name: .long,
        help: "Explicitly reinstall a locally quarantined failed version."
    )
    var overrideQuarantine = false

    mutating func run() async throws {
        let config: ProviderConfig
        do {
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            config = snapshot.config
        } catch {
            config = ConfigManager.loadDefault()
        }

        print("darkbloom update")
        print("Current version: \(ProviderCore.version)")
        print("")

        let coordinatorURL = coordinator ?? config.coordinator.url
        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)

        if checkOnly {
            let result = await updater.checkForUpdate(
                manualOverride: overrideQuarantine
            )
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
                print("Run 'darkbloom update' to install.")

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
            printError("WARNING: overriding local failed-version quarantine by explicit request.")
            printError("The failed release may crash this provider again.")
        }
        print("Checking for updates...")
        let result = await updater.update(manualOverride: overrideQuarantine)

        switch result {
        case .alreadyUpToDate(let version):
            print("Already up to date (v\(version)).")

        case .updated(let from, let to):
            print("Updated: v\(from) -> v\(to)")
            if LaunchAgent.isLoaded() {
                print("Restarting provider via launchd...")
                do {
                    try updater.prepareCandidateLaunch(
                        operation: "manual-update-restart"
                    )
                    try ProcessLifecycle.restartAfterUpdate()
                } catch {
                    try? updater.cancelPendingCandidateAttempt(
                        operation: "manual-restart-failure")
                    throw error
                }
            } else {
                print("Restart the provider for the new version to take effect.")
            }

        case .restartRequired(let from, let to):
            print("v\(to) is already installed (current process: v\(from)).")
            if LaunchAgent.isLoaded() {
                print("Restarting provider via launchd...")
                do {
                    try updater.prepareCandidateLaunch(
                        operation: "manual-candidate-restart"
                    )
                    try ProcessLifecycle.restartAfterUpdate()
                } catch {
                    try? updater.cancelPendingCandidateAttempt(
                        operation: "manual-restart-failure")
                    throw error
                }
            } else {
                print("Restart the provider for v\(to) to take effect.")
            }

        case .quarantined(let version, let reason):
            printError("v\(version) is quarantined after failed starts: \(reason)")
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
}
