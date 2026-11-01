import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Autopilot {
    struct Downloads: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set or turn off Autopilot downloads of catalog models on your behalf.",
            discussion: """
                On by default while Autopilot is enrolled. Downloads keep at least \
                \(AutopilotDiskGuard.defaultReserveGiB) GiB of disk free and stay within your limits. They never \
                load a model by themselves and never delete files. Changing this setting does not change your \
                Autopilot consent.
                """,
            subcommands: [Enable.self, Disable.self])
    }
}

extension Autopilot.Downloads {
    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn Autopilot downloads on, with optional storage and model limits.",
            discussion: """
                Each run replaces both limits: an omitted flag means no limit. On an interactive terminal \
                without flags, you are asked for both; a blank answer means no limit.
                """)
        @OptionGroup var configOptions: ConfigOptions
        @Option(name: .customLong("max-storage-gb"),
                help: "Most GiB the models Autopilot downloads may use together.")
        var maxStorageGb: UInt64?
        @Option(name: .customLong("max-models"), help: "Most models Autopilot may download.")
        var maxModels: UInt64?

        mutating func run() async throws {
            var limits = (storage: maxStorageGb, models: maxModels)
            if maxStorageGb == nil, maxModels == nil, isatty(STDIN_FILENO) != 0 {
                limits = try Self.promptLimits()
            }
            let settings = try Self.enabledSettings(storage: limits.storage, models: limits.models)
            try saveAutopilotDownloads(configPath: configOptions.config) { current in
                current.enabled = settings.enabled
                current.maxStorageGb = settings.maxStorageGb
                current.maxModels = settings.maxModels
            }
            print("Autopilot downloads enabled. \(describeAutopilotDownloadLimits(settings))")
            print("They apply while Autopilot is enrolled; the running provider picks this up at its next policy refresh.")
        }

        static func enabledSettings(storage: UInt64?, models: UInt64?) throws -> AutopilotDownloadSettings {
            guard storage != 0, models != 0 else {
                throw ValidationError("Limits must be at least 1; to stop downloads, run `\(BuildEnvironment.current.cliName) autopilot downloads disable`.")
            }
            return AutopilotDownloadSettings(enabled: true, maxStorageGb: storage, maxModels: models)
        }

        static func promptLimits(
            readInput: () -> String? = { readLine() },
            emit: (String) -> Void = { print($0, terminator: "") }
        ) throws -> (storage: UInt64?, models: UInt64?) {
            emit("Most storage Autopilot downloads may use, in GiB (blank for no limit): ")
            let storage = try parseLimit(readInput())
            emit("Most models Autopilot may download (blank for no limit): ")
            let models = try parseLimit(readInput())
            return (storage, models)
        }

        static func parseLimit(_ input: String?) throws -> UInt64? {
            let answer = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty else { return nil }
            guard let value = UInt64(answer), value > 0 else {
                throw ValidationError("Enter a whole number of at least 1, or leave it blank for no limit.")
            }
            return value
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop Autopilot downloads. Models it already downloaded stay on disk and stay available.")
        @OptionGroup var configOptions: ConfigOptions

        mutating func run() async throws {
            try saveAutopilotDownloads(configPath: configOptions.config) { $0.enabled = false }
            print("Autopilot downloads disabled. Downloaded models stay on disk; an accepted download finishes.")
        }
    }
}

/// Saves `[backend.autopilot_downloads]` under the config lock. Never touches
/// `[backend.model_autopilot]`, so the consent revision is unchanged.
func saveAutopilotDownloads(configPath: String?, change: (inout AutopilotDownloadSettings) -> Void) throws {
    try withMutableConfig(configPath: configPath) { path, config in
        var settings = config.backend.autopilotDownloads ?? .init()
        change(&settings)
        config.backend.autopilotDownloads = settings
        try ConfigManager.save(config, to: path)
    }
}

func describeAutopilotDownloadLimits(_ settings: AutopilotDownloadSettings) -> String {
    let storage = settings.maxStorageGb.map { "\($0) GiB" } ?? "no storage limit"
    let models = settings.maxModels.map { "\($0) model\($0 == 1 ? "" : "s")" } ?? "no model limit"
    let reserve = settings.reserveGb ?? AutopilotDiskGuard.defaultReserveGiB
    return "Limits: \(storage), \(models); keeps \(reserve) GiB free."
}
