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
        Darkbloom.ensureLogging()
        switch action.lowercased() {
        case "status":
            let snapshot = try loadRuntimeSnapshot(configPath: configOptions.config, migrateOnDisk: false)
            print("Auto-update is \(snapshot.config.provider.autoUpdate ? "ENABLED" : "DISABLED")")
            print("Config: \(describeConfigPath(snapshot))")

        case "enable", "on", "true":
            try setAutoUpdate(true, configPath: configOptions.config)
            print("Auto-update ENABLED.")
            print("The provider will check for new signed releases at startup.")

        case "disable", "off", "false":
            try setAutoUpdate(false, configPath: configOptions.config)
            print("Auto-update DISABLED.")
            print("Run 'darkbloom update' manually to install new releases.")

        default:
            printError("Unknown action: '\(action)'. Use 'enable', 'disable', or 'status'.")
            throw ExitCode.failure
        }
    }
}

/// Reload under the same sidecar lock as live model selection and the other
/// config commands. A snapshot read before a switch cannot write old models
/// over the switch's durable selection.
func setAutoUpdate(_ value: Bool, configPath: String?) throws {
    // Avoid a migration write before the sidecar lock. The selected path is
    // reloaded by withMutableConfig after acquiring the switch's lock.
    try withMutableConfig(configPath: configPath, migrateOnDisk: false) { path, config in
        if config.provider.autoUpdate == value,
           FileManager.default.fileExists(atPath: path.path) {
            return
        }
        config.provider.autoUpdate = value
        try ConfigManager.save(config, to: path)
    }
}
