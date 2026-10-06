import Foundation
import ProviderCore

/// Line-based prompts keep normal terminal editing and Ctrl-C behavior intact.
/// Every answer stays in memory until the final confirmation; EOF/q cancels.
struct ScheduleWizard {
    var readInput: () -> String? = { readLine() }
    var emit: (String) -> Void = { print($0, terminator: ""); fflush(stdout) }

    func run(current: ScheduleSettings, idleMinutes: UInt64, preloadModels: [String], starting: Bool) -> ScheduleSettings? {
        emit("\n  DARKBLOOM / PROVIDER AVAILABILITY\n  ---------------------------------\n")
        emit(current.summary() + "\n\n")
        emit("  Enter keeps the bracketed default. Type q at any prompt to cancel.\n")
        var draft = current
        let hasWindows = !(current.schedule?.windows.isEmpty ?? true)
        let defaultMode = current.schedule?.enabled == true && hasWindows ? 1 : 2
        emit("\n  When should this Mac serve?\n")
        emit("    1. Use saved windows\n    2. Always available / disable scheduling\n    3. Overnight (Mon-Fri, 22:00-08:00)\n    4. Weekends (Sat-Sun, all day)\n    5. Custom weekly windows\n")
        guard let mode: Int = ask("Choice", fallback: "\(defaultMode)", parse: { value in
            guard let n = Int(value), (1...5).contains(n), n != 1 || hasWindows else { return nil }
            return n
        }, problem: "Choose 1-5; saved windows must exist for option 1.") else { return nil }
        switch mode {
        case 1:
            draft.schedule?.enabled = true
        case 2:
            if draft.schedule != nil { draft.schedule?.enabled = false }
        case 3:
            draft.schedule = ScheduleConfig(enabled: true, windows: [ScheduleWindow(
                days: ["mon", "tue", "wed", "thu", "fri"], start: "22:00", end: "08:00")])
        case 4:
            draft.schedule = ScheduleConfig(enabled: true, windows: [ScheduleWindow(
                days: ["sat", "sun"], start: "00:00", end: "00:00")])
        default:
            draft.schedule = ScheduleConfig(enabled: true, windows: current.schedule?.windows ?? [])
        }

        if draft.schedule?.enabled == true {
            guard let windows = editWindows(draft.schedule?.windows ?? []) else { return nil }
            draft.schedule?.windows = windows
        }

        emit("\n  How should models enter memory?\n")
        emit("    1. Preload at the window opening (recommended for lower first-request latency)\n    2. Load on demand (skip startup preload; the network may still request loads)\n")
        guard let loading: Int = ask("Loading", fallback: current.preload ? "1" : "2", parse: {
            guard let n = Int($0), (1...2).contains(n) else { return nil }; return n
        }, problem: "Choose 1 or 2.") else { return nil }
        draft.preload = loading == 1
        emit("\n" + draft.summary() + "\n")
        if draft.preload, !preloadModels.isEmpty {
            emit("  Existing preload list: \(preloadModels.joined(separator: ", "))\n  Only selected serving models in that list preload; other models load on demand.\n")
        }
        emit("  Memory when idle: \(IdleUnloadPolicy.describe(minutes: idleMinutes)) (unchanged)\n")
        emit("  Outside windows: drain accepted requests, disconnect, and unload models.\n")
        emit("  Loading begins when a window opens, not before. Your Mac must remain awake.\n")
        emit("  These settings also control an attached --local-endpoint, not standalone --local.\n")
        guard let confirmed: Bool = ask(starting ? "Save these settings and continue starting?" : "Save these settings?",
            fallback: "n", parse: Self.yesNo, problem: "Enter y or n.") else { return nil }
        return confirmed ? draft : nil
    }

    private func editWindows(_ existing: [ScheduleWindow]) -> [ScheduleWindow]? {
        var windows = existing
        if windows.isEmpty {
            guard let window = editWindow(nil) else { return nil }
            windows.append(window)
        }
        while true {
            emit("\n  Weekly windows\n")
            for (index, window) in windows.enumerated() {
                emit(ScheduleSettings.windowSummary(window, number: index + 1) + "\n")
            }
            emit("    a. Add window    e. Edit window    r. Remove window    d. Done\n")
            guard let action: String = ask("Action", fallback: "d", parse: {
                ["a", "e", "r", "d"].contains($0.lowercased()) ? $0.lowercased() : nil
            }, problem: "Choose a, e, r or d.") else { return nil }
            if action == "d" {
                do {
                    try ScheduleConfig(enabled: true, windows: windows).validate()
                    return windows
                } catch {
                    emit("  \(error.localizedDescription) Edit or add windows before continuing.\n")
                    continue
                }
            }
            if action == "a" {
                guard let window = editWindow(nil) else { return nil }
                windows.append(window)
                continue
            }
            guard !windows.isEmpty else { emit("  No windows to edit or remove.\n"); continue }
            guard let number: Int = ask("Window number", fallback: "1", parse: {
                guard let n = Int($0), (1...windows.count).contains(n) else { return nil }; return n
            }, problem: "Choose an existing window number.") else { return nil }
            if action == "r" {
                windows.remove(at: number - 1)
            } else {
                guard let window = editWindow(windows[number - 1]) else { return nil }
                windows[number - 1] = window
            }
        }
    }

    private func editWindow(_ existing: ScheduleWindow?) -> ScheduleWindow? {
        emit("\n  Days refer to the day the window starts.\n")
        emit("  Use mon,tue,...,sun; weekdays, weekends, daily; or a range like fri-mon.\n")
        guard let days: [String] = ask("Days", fallback: existing?.days.joined(separator: ",") ?? "weekdays",
            parse: Self.parseDays, problem: "Enter valid days, a day range, weekdays, weekends or daily.") else { return nil }
        guard let start: String = ask("Start (24-hour HH:MM)", fallback: existing?.start ?? "22:00",
            parse: Self.parseTime, problem: "Use a time from 00:00 to 23:59.") else { return nil }
        emit("  An earlier end crosses midnight; equal start/end means 24 hours.\n")
        guard let end: String = ask("End (24-hour HH:MM)", fallback: existing?.end ?? "08:00",
            parse: Self.parseTime, problem: "Use a time from 00:00 to 23:59.") else { return nil }
        return ScheduleWindow(days: days, start: start, end: end)
    }

    private func ask<T>(_ label: String, fallback: String, parse: (String) -> T?, problem: String) -> T? {
        while true {
            emit("  \(label) [\(fallback)]: ")
            guard let input = readInput() else { emit("\n"); return nil }
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.lowercased() != "q", value.lowercased() != "cancel" else { return nil }
            if let parsed = parse(value.isEmpty ? fallback : value) { return parsed }
            emit("  \(problem)\n")
        }
    }

    static func yesNo(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "y", "yes": return true
        case "n", "no": return false
        default: return nil
        }
    }

    static func parseTime(_ value: String) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
            let time = TimeOfDay.parse(value) else { return nil }
        return time.description
    }

    static func parseDays(_ value: String) -> [String]? {
        let input = value.lowercased().trimmingCharacters(in: .whitespaces)
        let days: [DayOfWeek]
        switch input {
        case "daily", "all", "everyday": days = DayOfWeek.allCases
        case "weekdays": days = Array(DayOfWeek.allCases.prefix(5))
        case "weekends": days = [.saturday, .sunday]
        default:
            var selected = Set<DayOfWeek>()
            let tokens = input.split(separator: ",", omittingEmptySubsequences: false)
            for token in tokens {
                let range = token.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
                if range.count == 1, let day = DayOfWeek.parse(String(range[0])) {
                    selected.insert(day)
                } else if range.count == 2,
                    let start = DayOfWeek.parse(range[0].trimmingCharacters(in: .whitespaces)),
                    let end = DayOfWeek.parse(range[1].trimmingCharacters(in: .whitespaces)) {
                    for offset in 0...((end.rawValue - start.rawValue + 7) % 7) { selected.insert(start.adding(offset)) }
                } else { return nil }
            }
            days = DayOfWeek.allCases.filter { selected.contains($0) }
        }
        return days.isEmpty ? nil : days.map { $0.abbreviation.lowercased() }
    }
}
