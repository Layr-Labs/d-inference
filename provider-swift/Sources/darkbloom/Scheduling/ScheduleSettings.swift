import ArgumentParser
import Foundation
import ProviderCore

/// The wizard edits only availability and startup loading, not model selection
/// or the independent idle-unload policy.
struct ScheduleSettings: Equatable {
    var schedule: ScheduleConfig?
    var preload: Bool

    init(config: ProviderConfig) {
        schedule = config.schedule
        preload = config.backend.startupPreload
    }

    func apply(to config: inout ProviderConfig) {
        config.schedule = schedule
        config.backend.startupPreload = preload
    }

    @discardableResult
    func save(configPath: String, expected: ScheduleSettings) throws -> Bool {
        try schedule?.validate()
        return try withMutableConfig(configPath: configPath) { path, config in
            guard ScheduleSettings(config: config) == expected else {
                throw ValidationError("Availability or preload settings changed while you were editing. Run `darkbloom schedule` again; nothing was overwritten.")
            }
            guard self != expected else { return false }
            apply(to: &config)
            try ConfigManager.save(config, to: path)
            return true
        }
    }

    func summary(timeZone: TimeZone = .current) -> String {
        var lines = ["  Availability", "  Time zone: \(timeZone.identifier) (this Mac's local time)"]
        if let schedule, schedule.enabled {
            if schedule.windows.isEmpty { lines.append("  Invalid schedule: no windows") }
            for (index, window) in schedule.windows.enumerated() {
                lines.append(Self.windowSummary(window, number: index + 1))
            }
        } else {
            lines.append("  Always available while the provider is running")
        }
        lines.append(preload
            ? "  Loading: preload at startup / each window opening (subject to memory and slot limits)"
            : "  Loading: on demand; coordinator load commands or requests can load models")
        return lines.joined(separator: "\n")
    }

    static func windowSummary(_ window: ScheduleWindow, number: Int) -> String {
        let start = TimeOfDay.parse(window.start)
        let end = TimeOfDay.parse(window.end)
        let suffix: String
        if let start, let end, start == end {
            suffix = " (24 hours, ending the following day)"
        } else if let start, let end, end < start {
            suffix = " (ends the following day)"
        } else {
            suffix = ""
        }
        return "  \(number). \(window.days.joined(separator: ", ")): \(window.start) -> \(window.end)\(suffix)"
    }
}
