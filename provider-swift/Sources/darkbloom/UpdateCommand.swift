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
            let result = await updater.checkForUpdate()
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

            case .checkFailed(let reason):
                printError("update check failed: \(reason)")
                throw ExitCode.failure
            }
            return
        }

        print("Checking for updates...")
        let result = await updater.update()

        switch result {
        case .alreadyUpToDate(let version):
            print("Already up to date (v\(version)).")

        case .updated(let from, let to):
            print("Updated: v\(from) -> v\(to)")
            if LaunchAgent.isLoaded() {
                print("Restarting provider via launchd...")
                try ProcessLifecycle.restartAfterUpdate()
            } else {
                print("Restart the provider for the new version to take effect.")
            }

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
