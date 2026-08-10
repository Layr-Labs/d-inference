import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

struct Beta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta",
        abstract: "Manage configurable beta features.",
        discussion: """
        Beta features are experimental and have feature-specific defaults.
        Toggling one writes a field in your provider TOML config, which is the
        authority for daemon, `--foreground`, and `--local` processes.

        Subcommands:
          list                 Show all beta features and whether each is on (default).
          enable <feature>     Turn a beta feature on.
          disable <feature>    Turn a beta feature off.
          status [feature]     Show details for all features, or one.

        Changes that affect process-wide optimization state require a restart.
        To roll back a default-on feature:
          darkbloom beta disable gemma-weighted-r1
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
            print("Change with:  darkbloom beta enable|disable <feature>   (then: darkbloom restart)")
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
            try setBetaFeature(feature, enabled: true, configPath: configOptions.config)
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
            try setBetaFeature(feature, enabled: false, configPath: configOptions.config)
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
///
/// Internal (not `private`) so `DarkbloomCLITests` can drive it with temp
/// config fixtures via `configPath`.
func setBetaFeature(
    _ id: String,
    enabled: Bool,
    configPath: String?
) throws {
    guard let feature = BetaFeatures.feature(id: id) else {
        throw unknownFeatureError(id)
    }

    let snapshot = try loadRuntimeSnapshot(configPath: configPath)

    // Persist to the path the daemon will actually read. With no explicit
    // --config, loadRuntimeSnapshot may have just migrated a legacy config to
    // the canonical ~/.config/darkbloom/provider.toml; `darkbloom restart` and
    // the launchd daemon resolve that canonical path first, so writing back to
    // the (legacy) snapshot.configPath would leave the restarted daemon on the
    // stale value. Re-resolving the default returns the post-migration canonical.
    let savePath: URL
    if configPath != nil {
        savePath = snapshot.configPath
    } else {
        savePath = try ConfigManager.defaultConfigPath()
    }

    // Serialize the load → modify → save window with an exclusive flock, and
    // RELOAD inside the lock: the snapshot above and any concurrent `beta`
    // process's write can interleave, and using the pre-lock snapshot would be
    // a classic lost-update RMW race.
    try withExclusiveConfigLock(at: savePath) {
        var config: ProviderConfig
        if FileManager.default.fileExists(atPath: savePath.path) {
            config = try ConfigManager.load(from: savePath)
        } else {
            config = snapshot.config
        }

        // No-op only when the file already PINS the requested value. An absent
        // key (or absent [section]) can decode to the same effective value via
        // the default, but an explicit enable/disable means "make it so,
        // durably" — materialize the key so a future default flip cannot
        // silently move this provider.
        if feature.isEnabled(in: config) == enabled,
           let address = feature.configAddress,
           let content = try? String(contentsOf: savePath, encoding: .utf8),
           tomlKeyPresent(content, section: address.section, key: address.key) {
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
}

/// Guards one config-file mutation window with an exclusive `flock(2)` on a
/// stable `<config-name>.lock` sidecar next to the config file. The lock must
/// NOT be taken out on provider.toml itself: `ConfigManager.save` writes
/// atomically via temp-file + rename, so the config file's inode changes on
/// every save and concurrent writers would be locking DIFFERENT inodes (no
/// mutual exclusion). The sidecar path is never renamed, so every contending
/// process locks the same inode. Closing the fd (the defer) also releases the
/// kernel lock if the explicit LOCK_UN is ever skipped by a throw.
@discardableResult
func withExclusiveConfigLock<T>(at configPath: URL, _ body: () throws -> T) throws -> T {
    let directory = configPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent(configPath.lastPathComponent + ".lock")

    let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else {
        throw ConfigError.writeFailed(
            path: lockURL.path,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        )
    }
    defer { close(fd) }

    guard flock(fd, LOCK_EX) == 0 else {
        throw ConfigError.writeFailed(
            path: lockURL.path,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        )
    }
    defer { _ = flock(fd, LOCK_UN) }

    return try body()
}

/// Whether TOML `content` materially sets `key` inside `[section]`.
///
/// Line-oriented: tracks the current table header and matches `key = ...`
/// assignments. Only needs to be correct for the flat
/// `[section]\nkey = value` shape `ConfigManager.save` serializes (and that
/// operators hand-edit). A miss here is fail-safe for the caller: unsure
/// means WRITE the key, which is idempotent.
func tomlKeyPresent(_ content: String, section: String, key: String) -> Bool {
    var inSection = false
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inSection = line == "[\(section)]"
            continue
        }
        guard inSection, !line.hasPrefix("#"),
              let eqIndex = line.firstIndex(of: "=") else { continue }
        let name = line[..<eqIndex].trimmingCharacters(in: .whitespaces)
        if name == key { return true }
    }
    return false
}
