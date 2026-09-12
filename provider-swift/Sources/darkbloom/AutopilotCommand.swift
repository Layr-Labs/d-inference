import ArgumentParser
import Foundation
import ProviderCore

/// Provider consent is local configuration and takes effect on restart. Default
/// off; `--all` is deliberately unrelated to this explicit enrollment.
struct Autopilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot",
        abstract: "Opt in to network-managed loading and unloading of cached models.",
        discussion: "Autopilot preserves active requests and pinned models, uses only cached advertised builds, and keeps model files on disk. While enabled, autopilot replaces the automatic idle-unload timer; the stored idle policy resumes when disabled. Changes apply after darkbloom restart. The coordinator must also enable its autopilot controller.",
        subcommands: [Status.self, Enable.self, Disable.self], defaultSubcommand: Status.self)

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show configured autopilot consent and limits.")
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Emit JSON.") var json = false
        mutating func run() async throws {
            let runtime = try loadRuntimeSnapshot(configOptions: configOptions)
            let settings = runtime.config.backend.modelAutopilot
            if json { try printJSON(settings); return }
            print("Model autopilot: \(settings.enabled ? "enabled" : "disabled") (configured; applies after restart)")
            print("  Scope: advertised models already cached on this Mac; no new base-model downloads")
            if settings.enabled { print("  Idle memory: controlled by autopilot; the configured idle timer is paused") }
            print("  Minimum residence and idle time before replacement: \(settings.effectiveMinDwellSeconds) seconds")
            print("  Pinned models: \(settings.pinnedModels.isEmpty ? "none" : settings.pinnedModels.joined(separator: ", "))")
            if runtime.config.coordinator.privateOnly { print("  Private-only mode prevents network autopilot.") }
            print("  Config: \(runtime.configPath.path)")
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Allow the coordinator to manage cached model residency.",
            discussion: "Pauses the configured idle-unload timer while enabled. Active requests and pinned models remain protected. Requires a coordinator with autopilot enabled; otherwise only already-warm models serve network requests. Applies after darkbloom restart.")
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Minimum residence and idle time before replacement, 60–86400 seconds.")
        var minDwellSeconds: UInt64?
        @Option(parsing: .upToNextOption, help: "Model IDs to protect from autopilot unloading; replaces the configured pin list.")
        var pin: [String] = []
        mutating func run() async throws {
            if let seconds = minDwellSeconds, !(60...86_400).contains(seconds) {
                throw ValidationError("min-dwell-seconds must be between 60 and 86400")
            }
            let path = try setModelAutopilot(enabled: true, dwell: minDwellSeconds,
                pins: pin.isEmpty ? nil : pin, configPath: configOptions.config)
            print("Model autopilot enabled for cached models; automatic idle unloading is now controller-managed. Apply with `darkbloom restart`.\nSaved to \(path.path)")
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke coordinator control of model residency after restart.")
        @OptionGroup var configOptions: ConfigOptions
        mutating func run() async throws {
            let path = try setModelAutopilot(enabled: false, configPath: configOptions.config)
            print("Model autopilot disabled. Apply with `darkbloom restart`.\nSaved to \(path.path)")
        }
    }
}

@discardableResult
func setModelAutopilot(enabled: Bool, dwell: UInt64? = nil, pins: [String]? = nil,
                       configPath: String?) throws -> URL {
    if let dwell, !(60...86_400).contains(dwell) {
        throw ValidationError("min-dwell-seconds must be between 60 and 86400")
    }
    let snapshot = try loadRuntimeSnapshot(configPath: configPath)
    let path = try configPath == nil ? ConfigManager.defaultConfigPath() : snapshot.configPath
    return try withExclusiveConfigLock(at: path) {
        var config = FileManager.default.fileExists(atPath: path.path)
            ? try ConfigManager.load(from: path) : snapshot.config
        config.backend.modelAutopilot.enabled = enabled
        if let dwell { config.backend.modelAutopilot.minDwellSeconds = dwell }
        if let pins { config.backend.modelAutopilot.pinnedModels = Array(Set(pins)).sorted() }
        try ConfigManager.save(config, to: path)
        return path
    }
}
