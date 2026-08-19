// Config command: `darkbloom config get|set`, scoped to the availability
// schedule (the `[schedule]` section plus its sibling availability knob,
// `[backend] idle_timeout_mins`) — and only that for now. Writes go through
// the CLI's existing config load/save machinery (`ConfigManager`) under the
// same exclusive flock `darkbloom beta` uses (`withExclusiveConfigLock`), so
// concurrent config-editing commands interleave safely.
//
// Grammar (mirrors the TOML `[schedule]` shape):
//   darkbloom config get [schedule] [--json]
//   darkbloom config set schedule always
//   darkbloom config set schedule <days> <HH:MM-HH:MM> [<days> <HH:MM-HH:MM>...]
//   darkbloom config set schedule idle-timeout-minutes <n>
//
// <days> aliases: weekdays | weekend | daily (also everyday/all), or a
// comma-separated day list (mon..sun, full names accepted).
//
// Changes land in provider.toml; the running daemon does NOT notice them
// live (the schedule is parsed once at launch), so a successful `set`
// advises `darkbloom restart` — it never restarts anything itself.
import Foundation
import ArgumentParser
import ProviderCore

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View and edit provider configuration (availability schedule for now).",
        discussion: """
        Grammar mirrors the [schedule] section of provider.toml:

          darkbloom config get schedule [--json]
          darkbloom config set schedule always
          darkbloom config set schedule weekdays 20:00-07:00
          darkbloom config set schedule weekdays 20:00-07:00 weekend 09:00-18:00
          darkbloom config set schedule idle-timeout-minutes 90

        Days accept aliases (weekdays, weekend, daily/everyday/all) or a
        comma-separated list (mon,tue,...,sunday). Window times are local
        HH:MM 24h; an end at or before the start wraps overnight.

        The running daemon parses its config at launch: `set` never notifies
        or restarts it. Apply changes with `darkbloom restart`.
        """,
        subcommands: [Get.self, Set.self],
        defaultSubcommand: Get.self
    )
}

// MARK: - Serialized payload (`config get schedule --json` contract, app-consumed)

/// One schedule window as the TOML `[schedule].windows` entry stores it.
struct ScheduleWindowOutput: Codable, Equatable, Sendable {
    var days: [String]
    var start: String
    var end: String
}

/// The complete availability payload `config get schedule --json` emits and
/// the Darkbloom app decodes: the `[schedule]` section plus
/// `[backend] idle_timeout_mins`, the one availability knob that lives
/// outside the section. Both are schedule-scoped on purpose — this command
/// is not a generic config editor.
struct ScheduleAvailabilityOutput: Codable, Equatable, Sendable {
    var enabled: Bool
    var windows: [ScheduleWindowOutput]
    var idleTimeoutMinutes: UInt64

    enum CodingKeys: String, CodingKey {
        case enabled
        case windows
        case idleTimeoutMinutes = "idle_timeout_minutes"
    }

    init(config: ProviderConfig) {
        let schedule = config.schedule
        enabled = schedule?.enabled ?? false
        windows = (schedule?.windows ?? []).map {
            ScheduleWindowOutput(days: $0.days, start: $0.start, end: $0.end)
        }
        idleTimeoutMinutes = config.backend.idleTimeoutMins
    }

    init(enabled: Bool, windows: [ScheduleWindowOutput], idleTimeoutMinutes: UInt64) {
        self.enabled = enabled
        self.windows = windows
        self.idleTimeoutMinutes = idleTimeoutMinutes
    }
}

// MARK: - Set plan (grammar parsing, pure)

/// What a `config set schedule ...` argument vector asks for. Parsing is
/// pure and file-free so `DarkbloomCLITests` can pin the grammar exactly.
enum ScheduleSetPlan: Equatable, Sendable {
    /// Disable scheduling; existing windows stay on disk so re-enabling
    /// restores them ("always" / "off").
    case always
    /// Enable scheduling with EXACTLY these windows (replaces the list).
    case windows([ScheduleWindow])
    /// Set `[backend] idle_timeout_mins` (minutes; 0 disables idle unload).
    case idleTimeoutMinutes(UInt64)

    static func parse(_ arguments: [String]) throws -> ScheduleSetPlan {
        guard let first = arguments.first else {
            throw ValidationError(
                "Usage: darkbloom config set schedule always | <days> <HH:MM-HH:MM> [...] | idle-timeout-minutes <n>")
        }

        switch first.lowercased() {
        case "always", "off":
            guard arguments.count == 1 else {
                throw ValidationError("'always' takes no further arguments.")
            }
            return .always
        case "idle-timeout-minutes":
            guard arguments.count == 2, let minutes = UInt64(arguments[1]) else {
                throw ValidationError("idle-timeout-minutes expects a single non-negative integer (minutes).")
            }
            return .idleTimeoutMinutes(minutes)
        default:
            break
        }

        // Window form: flat <days> <HH:MM-HH:MM> pairs.
        guard arguments.count.isMultiple(of: 2) else {
            throw ValidationError(
                "Windows come in <days> <HH:MM-HH:MM> pairs, e.g. `weekdays 20:00-07:00`.")
        }

        var windows: [ScheduleWindow] = []
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let days = try parseDays(arguments[index])
            let (start, end) = try parseWindowRange(arguments[index + 1])
            guard start != end else {
                throw ValidationError(
                    "Window \(index / 2 + 1) begins and ends at \(start.description); "
                        + "a full-day window serves the same as `always` and is rejected.")
            }
            windows.append(ScheduleWindow(days: days, start: start.description, end: end.description))
        }
        return .windows(windows)
    }

    /// Day tokens → canonical lowercase three-letter day list, in week order
    /// (matching `DayOfWeek` raw order) so the written TOML is stable.
    private static func parseDays(_ token: String) throws -> [String] {
        switch token.lowercased() {
        case "weekdays", "weekday", "mon-fri":
            return DayOfWeek.allCases.prefix(5).map(dayToken(_:))
        case "weekend", "sat-sun":
            return DayOfWeek.allCases.suffix(2).map(dayToken(_:))
        case "daily", "everyday", "all":
            return DayOfWeek.allCases.map(dayToken(_:))
        default:
            break
        }

        var parsed: Set<DayOfWeek> = []
        for part in token.split(separator: ",") {
            guard let day = DayOfWeek.parse(String(part)) else {
                throw ValidationError(
                    "Unknown day '\(part)' — use mon..sun, weekdays, weekend, or daily.")
            }
            parsed.insert(day)
        }
        return DayOfWeek.allCases.filter { parsed.contains($0) }.map(dayToken(_:))
    }

    /// `<DayOfWeek>` → the lowercase token `[schedule].windows.days` stores.
    private static func dayToken(_ day: DayOfWeek) -> String {
        day.abbreviation.lowercased()
    }

    private static func parseWindowRange(_ token: String) throws -> (start: TimeOfDay, end: TimeOfDay) {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = TimeOfDay.parse(String(parts[0])),
              let end = TimeOfDay.parse(String(parts[1]))
        else {
            throw ValidationError("Invalid time range '\(token)' — expected HH:MM-HH:MM (24h).")
        }
        return (start, end)
    }
}

// MARK: - Read / write helpers (internal for DarkbloomCLITests)

/// Read the availability payload (`[schedule]` + `[backend] idle_timeout_mins`).
/// Read-only: no on-disk migration, no hardware or model scan.
func loadScheduleAvailability(configPath: String?) throws -> ScheduleAvailabilityOutput {
    let path: URL
    if let configPath {
        path = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
    } else {
        path = try ConfigManager.defaultConfigPath()
    }
    let config: ProviderConfig
    if FileManager.default.fileExists(atPath: path.path) {
        config = try ConfigManager.load(from: path)
    } else {
        config = ProviderConfig(
            provider: ProviderSettings(name: "darkbloom"),
            backend: BackendSettings(),
            coordinator: CoordinatorSettings()
        )
    }
    return ScheduleAvailabilityOutput(config: config)
}

/// Apply a schedule set plan to provider.toml and return the resulting
/// payload. Read-modify-write under the shared config flock, reloading inside
/// the lock (same race discipline as `setBetaFeature`); all non-schedule
/// sections round-trip untouched.
@discardableResult
func applyScheduleAvailabilitySet(
    _ plan: ScheduleSetPlan,
    configPath: String?
) throws -> ScheduleAvailabilityOutput {
    let snapshot = try loadRuntimeSnapshot(configPath: configPath)

    // Persist to the path the daemon will actually read. With no explicit
    // --config the snapshot load may have migrated a legacy config into the
    // canonical ~/.config/darkbloom/provider.toml; re-resolving the default
    // returns that post-migration canonical path (mirrors setBetaFeature).
    let savePath = configPath != nil ? snapshot.configPath : try ConfigManager.defaultConfigPath()

    return try withExclusiveConfigLock(at: savePath) {
        var config: ProviderConfig
        if FileManager.default.fileExists(atPath: savePath.path) {
            config = try ConfigManager.load(from: savePath)
        } else {
            config = snapshot.config
        }

        switch plan {
        case .always:
            var schedule = config.schedule ?? ScheduleConfig()
            schedule.enabled = false
            config.schedule = schedule
        case .windows(let windows):
            config.schedule = ScheduleConfig(enabled: true, windows: windows)
        case .idleTimeoutMinutes(let minutes):
            config.backend.idleTimeoutMins = minutes
        }

        try ConfigManager.save(config, to: savePath)
        return ScheduleAvailabilityOutput(config: config)
    }
}

// MARK: - Subcommands

extension Config {
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Show a configuration section (only \"schedule\" for now)."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Configuration section to read. Only \"schedule\" is supported for now.")
        var key: String = "schedule"

        @Flag(name: .long, help: "Emit JSON.")
        var json = false

        mutating func run() async throws {
            guard key == "schedule" else {
                throw ValidationError("Unknown config key '\(key)'. Only \"schedule\" is supported for now.")
            }
            let output = try loadScheduleAvailability(configPath: configOptions.config)
            if json {
                try printJSON(output)
                return
            }
            print(scheduleSummary(output))
            print("Idle model unload: \(output.idleTimeoutMinutes == 0 ? "disabled" : "\(output.idleTimeoutMinutes) minutes")")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Edit a configuration section (only \"schedule\" for now)."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Configuration section to edit. Only \"schedule\" is supported for now.")
        var key: String

        @Argument(parsing: .remaining, help: "The schedule payload (see `darkbloom config --help`).")
        var values: [String] = []

        @Flag(name: .long, help: "Emit the resulting schedule as JSON (advice still goes to stderr).")
        var json = false

        mutating func run() async throws {
            guard key == "schedule" else {
                throw ValidationError("Unknown config key '\(key)'. Only \"schedule\" is supported for now.")
            }
            let plan = try ScheduleSetPlan.parse(values)
            let output = try applyScheduleAvailabilitySet(plan, configPath: configOptions.config)

            if json {
                try printJSON(output)
                printError("Provider configuration updated; restart applies it: darkbloom restart")
                return
            }
            print(scheduleSummary(output))
            print("Provider configuration updated.")
            print("Restart the provider to apply the change: darkbloom restart")
        }
    }
}

/// One human summary line for both `get` and `set`.
private func scheduleSummary(_ output: ScheduleAvailabilityOutput) -> String {
    guard output.enabled, !output.windows.isEmpty else {
        return "Schedule: always available (scheduling disabled)"
    }
    let windows = output.windows
        .map { "\($0.days.joined(separator: ",")) \($0.start)-\($0.end)" }
        .joined(separator: " | ")
    return "Schedule: \(windows)"
}
