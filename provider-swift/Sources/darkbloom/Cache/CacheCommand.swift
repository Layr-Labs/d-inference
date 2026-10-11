import ArgumentParser
import Foundation
import ProviderCore

struct Cache: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Configure encrypted inference-cache storage and daily writes.",
        subcommands: [Set.self, Status.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save cache settings; restart the provider to apply them.")

        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Maximum cache-file writes per rolling day in decimal GB (0 = unlimited).")
        var dailyWriteGB: Double?
        @Option(help: "Existing private directory on a local APFS volume. External volumes must be encrypted. No files are moved.")
        var directory: String?
        @Flag(help: "Use the built-in cache directory again, preserving the daily write limit.")
        var resetDirectory = false

        func validate() throws {
            guard dailyWriteGB != nil || directory != nil || resetDirectory else {
                throw ValidationError("Specify --daily-write-gb, --directory or --reset-directory.")
            }
            guard !(directory != nil && resetDirectory) else {
                throw ValidationError("--directory and --reset-directory cannot be combined.")
            }
            try CacheSettings(dailyWriteGB: dailyWriteGB).validate()
        }

        func run() throws {
            let result = try updateCacheSettings(dailyWriteGB: dailyWriteGB, directory: directory,
                resetDirectory: resetDirectory, configPath: configOptions.config)
            print("Saved cache settings to \(result.path.path).")
            print("Cache directory: \(CacheStorage.root(for: result.settings).path)")
            print("Daily write limit: \(describeCacheWriteLimit(result.settings))")
            if configOptions.config != nil {
                print("Restart the provider to apply these settings.")
                print("Use --config with this path when restarting: \(result.path.path)")
            } else {
                print("Restart the provider to apply: darkbloom restart")
            }
            if directory != nil {
                print("Existing cache files stay in their old directory and are not migrated.")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show saved cache settings and check the selected volume.")
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Emit machine-readable settings and storage diagnostics.") var json = false

        func run() throws {
            let loaded = try loadRuntimeConfiguration(configPath: configOptions.config)
            let status = inspectCacheSettings(loaded.config.cache)
            if json {
                try printJSON(status)
            } else {
                print("Cache directory: \(status.directory)")
                print("Daily write limit: \(describeCacheWriteLimit(loaded.config.cache))")
                print("Storage check: \(status.storageCheck)")
                print("Payload encryption: AES-256-GCM; keys stay in the Mac's Keychain/Secure Enclave.")
                print("These are saved settings; a running provider uses its startup settings until restarted.")
            }
        }
    }
}
