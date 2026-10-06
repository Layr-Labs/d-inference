import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

struct AvailabilitySchedule: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Configure weekly provider availability and model preloading.",
        discussion: "With no flags, opens an interactive editor. Changes are saved to provider.toml and apply on the next start or restart. The editor never stops or starts the provider. Use --show to inspect or --disable to serve whenever the provider runs.")

    @OptionGroup var configOptions: ConfigOptions
    @Flag(help: "Show saved availability and loading settings without editing.")
    var show = false
    @Flag(help: "Disable availability windows, preserving them for later reuse.")
    var disable = false

    mutating func validate() throws {
        guard !(show && disable) else { throw ValidationError("--show and --disable are mutually exclusive.") }
    }

    mutating func run() async throws {
        if !show && !disable { try Self.requireInteractiveTerminal() }
        let loaded = try loadRuntimeConfiguration(configPath: configOptions.config)
        let current = ScheduleSettings(config: loaded.config)
        if show {
            print(current.summary())
            if let schedule = current.schedule {
                do { try schedule.validate() } catch { throw ValidationError(error.localizedDescription) }
            }
            print("  Config: \(loaded.configPath.path)")
            print("  Saved settings; restart is required to apply edits to a running provider.")
            return
        }
        let draft: ScheduleSettings
        if disable {
            draft = Self.disabled(current)
        } else {
            guard let answer = ScheduleWizard().run(current: current,
                idleMinutes: loaded.config.backend.idleTimeoutMins,
                preloadModels: loaded.config.backend.preloadModels, starting: false) else {
                print("Cancelled. Configuration unchanged; provider not started or stopped.")
                return
            }
            draft = answer
        }
        let changed = try draft.save(configPath: loaded.configPath.path, expected: current)
        print(changed ? "Availability saved to \(loaded.configPath.path)." : "Availability unchanged.")
        print("Apply to a running provider with `darkbloom restart`; otherwise use `darkbloom start`.")
        if configOptions.config != nil { print("Use --config \(loaded.configPath.path) when starting this configuration.") }
    }

    static func disabled(_ current: ScheduleSettings) -> ScheduleSettings {
        var settings = current
        settings.schedule?.enabled = false
        return settings
    }

    static func requireInteractiveTerminal(interactive: Bool = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0) throws {
        guard interactive else {
            throw ValidationError("The schedule wizard requires an interactive terminal. Run `darkbloom schedule` in a terminal, or edit [schedule] / [[schedule.windows]] and [backend] startup_preload in provider.toml. Use `darkbloom schedule --show` to inspect saved settings.")
        }
    }
}
