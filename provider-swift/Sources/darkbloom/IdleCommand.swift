// `darkbloom idle` — the operator's idle-memory policy: what the daemon does
// with a loaded model when no requests arrive. One TOML key
// (`[backend] idle_timeout_mins`) is the single authority; this command, the
// `darkbloom start` prompt and `--idle-timeout` are three writers of it.
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

/// Pure helpers behind the idle-policy prompt and `darkbloom idle`. No I/O so
/// the menu, parsing and wording are unit-testable.
enum IdleUnloadPolicy {
    /// The shipped default and the "Free when idle" menu option.
    static let defaultMinutes: UInt64 = 60
    /// One week. Bounds the daemon's timer arithmetic and catches typos.
    static let maxMinutes: UInt64 = 7 * 24 * 60
    /// The `--idle-timeout` value that means "keep loaded".
    static let alwaysReadyMinutes: UInt64 = 0

    enum MenuChoice: Equatable {
        case alwaysReady
        case freeWhenIdle
        case custom
    }

    /// Menu item pre-selected for Enter: the operator's CURRENT policy, so a
    /// repeat `darkbloom start` never silently moves it (0 → 1, 60 → 2,
    /// anything else → 3).
    static func defaultChoice(currentMinutes: UInt64) -> MenuChoice {
        switch currentMinutes {
        case alwaysReadyMinutes: return .alwaysReady
        case defaultMinutes: return .freeWhenIdle
        default: return .custom
        }
    }

    static func menuNumber(_ choice: MenuChoice) -> Int {
        switch choice {
        case .alwaysReady: return 1
        case .freeWhenIdle: return 2
        case .custom: return 3
        }
    }

    /// "1"/"2"/"3" → choice; blank → `fallback`; anything else → nil.
    static func parseChoice(_ input: String, fallback: MenuChoice) -> MenuChoice? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        switch trimmed {
        case "1": return .alwaysReady
        case "2": return .freeWhenIdle
        case "3": return .custom
        default: return nil
        }
    }

    /// Minutes for the custom prompt / `unload-after`: blank → `fallback`;
    /// an integer in 1...maxMinutes → itself; anything else → nil.
    static func parseMinutes(_ input: String, fallback: UInt64) -> UInt64? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        guard let value = UInt64(trimmed), (1...maxMinutes).contains(value) else { return nil }
        return value
    }

    /// Rejects an out-of-range CLI value (`--idle-timeout`, `unload-after`).
    /// 0 is valid (always ready). Returns the message to print, or nil.
    static func validate(minutes: UInt64) -> String? {
        guard minutes <= maxMinutes else {
            return "idle window must be between 1 and \(maxMinutes) minutes (7 days), or 0 to keep models loaded."
        }
        return nil
    }

    /// "60 min" / "2 h" / "1 h 30 min".
    static func formatWindow(minutes: UInt64) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// One-line policy summary for `status`, `idle status` and `start`.
    static func describe(minutes: UInt64) -> String {
        if minutes == alwaysReadyMinutes {
            return "always ready (models stay loaded)"
        }
        return "free after \(formatWindow(minutes: minutes)) idle (models reload on demand)"
    }

    /// The `darkbloom start` menu. `holdsGb` is the resident footprint of the
    /// selected models (nil when unknown) so the "Always ready" cost is
    /// concrete.
    static func menu(holdsGb: Double?, currentMinutes: UInt64) -> String {
        let holds = holdsGb.map { String(format: " Holds up to ~%.0f GB while idle.", $0) } ?? ""
        let customNote: String
        if defaultChoice(currentMinutes: currentMinutes) == .custom {
            customNote = " (currently \(formatWindow(minutes: currentMinutes)))"
        } else {
            customNote = ""
        }
        return """

              When there are no requests, how should Darkbloom use your memory?

                1) Always ready     Models stay loaded. Instant responses, first in
                                    line for routing, base rewards accrue around
                                    the clock.\(holds)
                2) Free when idle   Unload after \(defaultMinutes) min without requests; reloaded
                                    on demand (10–30 s cold start). Your Mac gets
                                    its memory back between bursts. Base rewards
                                    pause while unloaded.
                3) Custom           Same as 2, with your own idle window.\(customNote)

            """
    }
}

// MARK: - Persistence (shared by `idle`, `start` prompt and `--idle-timeout`)

/// Read-modify-write `[backend] idle_timeout_mins` and persist it. Returns
/// the config path written and whether anything changed. Mirrors
/// `setBetaFeature`: canonical-path resolution, exclusive lock, reload inside
/// the lock, and key materialization so an absent key that merely decodes to
/// the requested value is still pinned durably.
///
/// Internal (not `private`) so `DarkbloomCLITests` can drive it with temp
/// config fixtures via `configPath`.
@discardableResult
func setIdleUnloadMinutes(
    _ minutes: UInt64,
    configPath: String?
) throws -> (path: URL, changed: Bool) {
    if let problem = IdleUnloadPolicy.validate(minutes: minutes) {
        throw ValidationError(problem)
    }

    let snapshot = try loadRuntimeSnapshot(configPath: configPath)
    let savePath: URL
    if configPath != nil {
        savePath = snapshot.configPath
    } else {
        savePath = try ConfigManager.defaultConfigPath()
    }

    return try withExclusiveConfigLock(at: savePath) {
        var config: ProviderConfig
        if FileManager.default.fileExists(atPath: savePath.path) {
            config = try ConfigManager.load(from: savePath)
        } else {
            config = snapshot.config
        }

        if config.backend.idleTimeoutMins == minutes,
           let content = try? String(contentsOf: savePath, encoding: .utf8),
           tomlKeyPresent(content, section: "backend", key: "idle_timeout_mins") {
            return (savePath, false)
        }

        config.backend.idleTimeoutMins = minutes
        try ConfigManager.save(config, to: savePath)
        return (savePath, true)
    }
}

/// Whether the config file at `path` explicitly sets `idle_timeout_mins`.
/// Used by the launchd `--foreground` child to decide whether a legacy plist's
/// `--idle-timeout` argv may still fill in the value (TOML wins when present).
func idleTimeoutPinned(at path: URL) -> Bool {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else { return false }
    return tomlKeyPresent(content, section: "backend", key: "idle_timeout_mins")
}

// MARK: - Command

/// `darkbloom idle status --json`.
struct IdlePolicyReport: Encodable {
    /// Minutes without requests before a model is unloaded; 0 = always ready.
    let idleTimeoutMins: UInt64
    /// `always_ready` | `free_when_idle`.
    let policy: String
    let summary: String
    /// Whether `[backend] idle_timeout_mins` is written in the TOML (vs. the
    /// decoded default).
    let pinned: Bool
    let configPath: String
}

struct Idle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "idle",
        abstract: "Choose what happens to loaded models when no requests arrive.",
        discussion: """
        With no requests for a while the provider can unload its models and give
        your Mac its memory back; the network reloads them on demand (the first
        request pays a 10–30 s cold start, and base rewards pause while nothing
        is loaded). Or keep them loaded around the clock for instant responses,
        first-in-line routing and uninterrupted base rewards.

        Subcommands:
          status                   Show the current policy (default).
          keep-loaded              Models stay loaded while the provider runs.
          unload-after <minutes>   Unload after N minutes without requests (shipped default: 60).

        The policy is `idle_timeout_mins` under `[backend]` in your provider
        config. Changes apply after `darkbloom restart`.
        """,
        subcommands: [Status.self, KeepLoaded.self, UnloadAfter.self],
        defaultSubcommand: Status.self
    )
}

extension Idle {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the current idle-memory policy."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Flag(help: "Emit JSON instead of text.")
        var json = false

        mutating func run() async throws {
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let minutes = snapshot.config.backend.idleTimeoutMins

            if json {
                try printJSON(IdlePolicyReport(
                    idleTimeoutMins: minutes,
                    policy: minutes == IdleUnloadPolicy.alwaysReadyMinutes ? "always_ready" : "free_when_idle",
                    summary: IdleUnloadPolicy.describe(minutes: minutes),
                    pinned: idleTimeoutPinned(at: snapshot.configPath),
                    configPath: snapshot.configPath.path))
                return
            }

            print("Memory when idle: \(IdleUnloadPolicy.describe(minutes: minutes))")
            print("  Config:  \(snapshot.configPath.path)")
            print("  Change:  darkbloom idle keep-loaded")
            print("           darkbloom idle unload-after <minutes>")
            print("  Applies after:  darkbloom restart")
        }
    }

    struct KeepLoaded: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "keep-loaded",
            abstract: "Keep models loaded while the provider runs (instant responses; memory stays reserved)."
        )

        @OptionGroup var configOptions: ConfigOptions

        mutating func run() async throws {
            let result = try setIdleUnloadMinutes(
                IdleUnloadPolicy.alwaysReadyMinutes, configPath: configOptions.config)
            printIdleOutcome(minutes: IdleUnloadPolicy.alwaysReadyMinutes, result: result)
        }
    }

    struct UnloadAfter: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unload-after",
            abstract: "Unload models after N minutes without requests; they reload on demand."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Minutes without requests before unloading (1–\(IdleUnloadPolicy.maxMinutes)).")
        var minutes: UInt64

        mutating func validate() throws {
            guard minutes > 0 else {
                throw ValidationError("minutes must be at least 1; use `darkbloom idle keep-loaded` to keep models resident.")
            }
            if let problem = IdleUnloadPolicy.validate(minutes: minutes) {
                throw ValidationError(problem)
            }
        }

        mutating func run() async throws {
            let result = try setIdleUnloadMinutes(minutes, configPath: configOptions.config)
            printIdleOutcome(minutes: minutes, result: result)
        }
    }
}

private func printIdleOutcome(minutes: UInt64, result: (path: URL, changed: Bool)) {
    let summary = IdleUnloadPolicy.describe(minutes: minutes)
    if result.changed {
        print("Memory when idle: \(summary)")
        print("  Restart to apply:  darkbloom restart")
    } else {
        print("Memory when idle is already \(summary).")
    }
    print("  Config: \(result.path.path)")
}
