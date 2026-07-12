import Foundation
import ArgumentParser
import ProviderCore

struct Beta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta",
        abstract: "Join the beta release cohort or manage beta features.",
        discussion: """
        The beta release cohort receives signed prereleases through the same
        automatic update, rollback, and traffic-serving path as stable providers.
        Cohort membership is persisted in provider.toml and reported to the
        coordinator at registration. Individual beta feature toggles remain
        available separately.

        Subcommands:
          list                 Show release cohort and feature states (default).
          enable               Join the beta release cohort.
          disable              Return to stable release discovery.
          enable <feature>     Turn an individual beta feature on.
          disable <feature>    Turn an individual beta feature off.
          status [feature]     Show details for all features, or one.

        Cohort changes require a restart to update registration and background checks:
          darkbloom beta enable
          darkbloom restart

        Individual features use the existing form:
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
                let features = BetaFeatures.all.map { feature in
                    BetaFeatureReport(
                        id: feature.id,
                        title: feature.title,
                        enabled: feature.isEnabled(in: config),
                        requiresRestart: feature.requiresRestart,
                        summary: feature.summary
                    )
                }
                let releaseCohort = BetaFeatureReport(
                    id: "release-channel",
                    title: "Beta releases",
                    enabled: config.provider.releaseChannel == .beta,
                    requiresRestart: true,
                    summary: "Use `darkbloom beta enable` without a feature id to opt in."
                )
                try printJSON([releaseCohort] + features)
                return
            }

            print("Beta releases: \(config.provider.releaseChannel == .beta ? "ENABLED" : "disabled")")
            print("Release channel: \(config.provider.releaseChannel.rawValue)")
            print("Config: \(describeConfigPath(snapshot))")
            print("Beta providers continue serving normal network traffic.")
            print("Change with: darkbloom beta \(config.provider.releaseChannel == .beta ? "disable" : "enable")  (then: darkbloom restart)")
            print("")
            print("Individual beta features:")
            if BetaFeatures.all.isEmpty {
                print("  (none available in this build)")
            } else {
                for feature in BetaFeatures.all {
                    let mark = feature.isEnabled(in: config) ? "on " : "off"
                    print("  [\(mark)] \(feature.id)  —  \(feature.summary)")
                }
            }
            print("")
            print("Enable a feature with: darkbloom beta enable <feature>  (then: darkbloom restart)")
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
                print("Beta releases: \(config.provider.releaseChannel == .beta ? "ENABLED" : "disabled")")
                print("  Release channel: \(config.provider.releaseChannel.rawValue)")
                print("  Prereleases use the normal signed update, rollback, and traffic-serving path.")
                print("  Requires `darkbloom restart` after a cohort change.")
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

        @Argument(help: "Optional beta feature id. Omit it to join the beta release cohort.")
        var feature: String?

        mutating func run() async throws {
            if let feature {
                try setBetaFeature(feature, enabled: true, configOptions: configOptions)
            } else {
                try setBetaReleaseChannel(.beta, configOptions: configOptions)
            }
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Disable a beta feature."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Optional beta feature id. Omit it to leave the beta release cohort.")
        var feature: String?

        mutating func run() async throws {
            if let feature {
                try setBetaFeature(feature, enabled: false, configOptions: configOptions)
            } else {
                try setBetaReleaseChannel(.stable, configOptions: configOptions)
            }
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
    let savePath = try betaConfigSavePath(snapshot: snapshot, configOptions: configOptions)

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

private func setBetaReleaseChannel(
    _ channel: ProviderReleaseChannel,
    configOptions: ConfigOptions
) throws {
    let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
    var config = snapshot.config
    let savePath = try betaConfigSavePath(snapshot: snapshot, configOptions: configOptions)

    if config.provider.releaseChannel == channel
        && (channel != .beta || config.provider.autoUpdate)
        && FileManager.default.fileExists(atPath: savePath.path) {
        print("Release channel is already \(channel.rawValue).")
        return
    }

    config.provider.releaseChannel = channel
    if channel == .beta {
        config.provider.autoUpdate = true
    }
    try ConfigManager.save(config, to: savePath)

    if channel == .beta {
        print("Beta release cohort ENABLED.")
        print("  This provider will receive signed beta releases and continue serving normal traffic.")
        print("  Automatic updates are enabled so the provider stays on the beta track.")
    } else {
        print("Beta release cohort disabled; release channel is stable.")
        print("  An installed beta is not downgraded; the provider stays on it until a newer stable release exists.")
    }
    print("  Restart to apply: darkbloom restart")
    print("  Config: \(savePath.path)")
}

private func betaConfigSavePath(
    snapshot: RuntimeSnapshot,
    configOptions: ConfigOptions
) throws -> URL {
    if configOptions.config != nil {
        return snapshot.configPath
    }
    return try ConfigManager.defaultConfigPath()
}
