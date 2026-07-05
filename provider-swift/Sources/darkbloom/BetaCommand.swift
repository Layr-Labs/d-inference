import Foundation
import ArgumentParser
import ProviderCore

struct Beta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta",
        abstract: "Manage opt-in beta features.",
        discussion: """
        Beta features are experimental and off by default. Toggling one writes a
        field in your provider TOML config, so the change also applies to the
        launchd daemon (unlike environment variables, which the daemon does not
        inherit).

        Subcommands:
          list                 Show all beta features and whether each is on (default).
          enable <feature>     Turn a beta feature on.
          disable <feature>    Turn a beta feature off.
          status [feature]     Show details for all features, or one.

        Most changes require a restart to take effect:
          darkbloom beta enable kv-quant
          darkbloom restart
        """,
        subcommands: [List.self, Enable.self, Disable.self, Status.self],
        defaultSubcommand: List.self
    )
}

// MARK: - JSON payload

private struct BetaFeatureReport: Encodable {
    let id: String
    let title: String
    let enabled: Bool
    let requiresRestart: Bool
    let summary: String
}

// MARK: - list

extension Beta {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List beta features and whether each is enabled."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Flag(help: "Emit JSON instead of a table.")
        var json = false

        mutating func run() async throws {
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let config = snapshot.config

            if json {
                let payload = BetaFeatures.all.map { feature in
                    BetaFeatureReport(
                        id: feature.id,
                        title: feature.title,
                        enabled: feature.isEnabled(in: config),
                        requiresRestart: feature.requiresRestart,
                        summary: feature.summary
                    )
                }
                try printJSON(payload)
                return
            }

            print("Beta features (config: \(describeConfigPath(snapshot)))")
            print("")
            if BetaFeatures.all.isEmpty {
                print("  (none available in this build)")
            } else {
                for feature in BetaFeatures.all {
                    let mark = feature.isEnabled(in: config) ? "on " : "off"
                    print("  [\(mark)] \(feature.id)  —  \(feature.summary)")
                }
            }
            print("")
            print("Enable with:  darkbloom beta enable <feature>   (then: darkbloom restart)")
            print("Details with: darkbloom beta status <feature>")
        }
    }
}

// MARK: - status

extension Beta {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show beta feature details and current state."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Optional feature id; omit to show every feature.")
        var feature: String?

        mutating func run() async throws {
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let config = snapshot.config

            let features: [BetaFeature]
            if let id = feature {
                guard let match = BetaFeatures.feature(id: id) else {
                    throw unknownFeatureError(id)
                }
                features = [match]
            } else {
                features = BetaFeatures.all
            }

            print("Config: \(describeConfigPath(snapshot))")
            for feature in features {
                print("")
                print("\(feature.title) (\(feature.id)): \(feature.isEnabled(in: config) ? "ENABLED" : "disabled")")
                print("  \(feature.details)")
                if feature.requiresRestart {
                    print("  Requires `darkbloom restart` after a change.")
                }
            }
        }
    }
}

// MARK: - enable / disable

extension Beta {
    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Enable a beta feature."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Beta feature id (see `darkbloom beta list`).")
        var feature: String

        mutating func run() async throws {
            try setBetaFeature(feature, enabled: true, configOptions: configOptions)
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Disable a beta feature."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Beta feature id (see `darkbloom beta list`).")
        var feature: String

        mutating func run() async throws {
            try setBetaFeature(feature, enabled: false, configOptions: configOptions)
        }
    }
}

// MARK: - Shared helpers

private func unknownFeatureError(_ id: String) -> ValidationError {
    let known = BetaFeatures.all.map(\.id).joined(separator: ", ")
    let available = known.isEmpty ? "(none available in this build)" : known
    return ValidationError("Unknown beta feature '\(id)'. Available: \(available). Run `darkbloom beta list`.")
}

/// Read-modify-write a single beta feature's config field and persist it.
private func setBetaFeature(
    _ id: String,
    enabled: Bool,
    configOptions: ConfigOptions
) throws {
    guard let feature = BetaFeatures.feature(id: id) else {
        throw unknownFeatureError(id)
    }

    let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
    var config = snapshot.config

    // Persist to the path the daemon will actually read. With no explicit
    // --config, loadRuntimeSnapshot may have just migrated a legacy config to
    // the canonical ~/.config/darkbloom/provider.toml; `darkbloom restart` and
    // the launchd daemon resolve that canonical path first, so writing back to
    // the (legacy) snapshot.configPath would leave the restarted daemon on the
    // stale value. Re-resolving the default returns the post-migration canonical.
    let savePath: URL
    if configOptions.config != nil {
        savePath = snapshot.configPath
    } else {
        savePath = try ConfigManager.defaultConfigPath()
    }

    // Already in the desired state and the target file exists — no-op.
    if feature.isEnabled(in: config) == enabled
        && FileManager.default.fileExists(atPath: savePath.path) {
        print("\(feature.title) (\(feature.id)) is already \(enabled ? "enabled" : "disabled").")
        return
    }

    feature.apply(enabled, to: &config)
    try ConfigManager.save(config, to: savePath)

    print("\(enabled ? "Enabled" : "Disabled") beta feature: \(feature.title) (\(feature.id))")
    print("  \(feature.details)")
    if feature.requiresRestart {
        print("  Restart to apply:  darkbloom restart")
    }
    print("  Config: \(savePath.path)")
}
