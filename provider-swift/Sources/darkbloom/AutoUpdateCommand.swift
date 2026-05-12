import ArgumentParser
import Foundation
import ProviderCore

struct AutoUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autoupdate",
        abstract: "Enable or disable automatic provider updates.",
        discussion: """
        Toggles `provider.auto_update` in the TOML config file.
        When enabled, the provider checks for updates at startup and
        installs new signed releases automatically.

        Examples:
          darkbloom autoupdate enable
          darkbloom autoupdate disable
          darkbloom autoupdate status
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Argument(help: "Action: enable | disable | status")
    var action: String

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let path = snapshot.configPath

        switch action.lowercased() {
        case "status":
            print("Auto-update is \(snapshot.config.provider.autoUpdate ? "ENABLED" : "DISABLED")")
            print("Config: \(describeConfigPath(snapshot))")

        case "enable", "on", "true":
            try writeAutoUpdate(true, snapshot: snapshot, path: path)
            print("Auto-update ENABLED.")
            print("The provider will check for new signed releases at startup.")

        case "disable", "off", "false":
            try writeAutoUpdate(false, snapshot: snapshot, path: path)
            print("Auto-update DISABLED.")
            print("Run 'darkbloom update' manually to install new releases.")

        default:
            printError("Unknown action: '\(action)'. Use 'enable', 'disable', or 'status'.")
            throw ExitCode.failure
        }
    }

    private func writeAutoUpdate(
        _ value: Bool,
        snapshot: RuntimeSnapshot,
        path: URL
    ) throws {
        var config = snapshot.config
        if config.provider.autoUpdate == value && snapshot.configFileExists {
            // Already in the desired state — no-op.
            return
        }
        config.provider.autoUpdate = value
        try ConfigManager.save(config, to: path)
    }
}
