/// Provider scheduling -- time-based availability windows.
///
/// Users configure when their machine should serve inference requests.
/// Outside scheduled windows the provider disconnects from the coordinator
/// and shuts down the backend to free GPU memory.
///
/// Schedule windows support:
///   - Day-of-week selection (Mon-Sun)
///   - Start/end times in 24h local time
///   - Overnight windows (e.g. 22:00-08:00 = serve overnight)
///   - Multiple windows (e.g. weekday evenings + all weekend)
///
/// When no schedule is configured or scheduling is disabled the provider
/// is always available (current default behavior).

import Foundation

// MARK: - Config types (serializable)

/// A single availability window as stored in config.
public struct ScheduleWindow: Codable, Sendable, Equatable {
    /// Days this window applies to (e.g. ["mon", "tue", "wed"]).
    public var days: [String]
    /// Start time in HH:MM 24h format.
    public var start: String
    /// End time in HH:MM 24h format. If end < start, wraps overnight.
    public var end: String

    public init(days: [String], start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }
}

/// Schedule configuration as stored in the config file.
public struct ScheduleConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var windows: [ScheduleWindow]

    public init(enabled: Bool = false, windows: [ScheduleWindow] = []) {
        self.enabled = enabled
        self.windows = windows
    }
}

// MARK: - Day of week

/// Days of the week, matching the Rust implementation.
public enum DayOfWeek: Int, Sendable, CaseIterable {
    case monday = 0
    case tuesday = 1
    case wednesday = 2
    case thursday = 3
    case friday = 4
    case saturday = 5
    case sunday = 6

    /// The Foundation weekday index (Calendar component: 1=Sunday, 2=Monday, ..., 7=Saturday).
    var foundationWeekday: Int {
        switch self {
        case .monday:    return 2
        case .tuesday:   return 3
        case .wednesday: return 4
        case .thursday:  return 5
        case .friday:    return 6
        case .saturday:  return 7
        case .sunday:    return 1
        }
    }

    /// Create from Foundation Calendar weekday (1=Sunday .. 7=Saturday).
    static func fromFoundationWeekday(_ weekday: Int) -> DayOfWeek? {
        switch weekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    /// Parse a day name string (case-insensitive). Accepts short and full names.
    public static func parse(_ s: String) -> DayOfWeek? {
        switch s.lowercased() {
        case "mon", "monday":    return .monday
        case "tue", "tuesday":   return .tuesday
        case "wed", "wednesday": return .wednesday
        case "thu", "thursday":  return .thursday
        case "fri", "friday":    return .friday
        case "sat", "saturday":  return .saturday
        case "sun", "sunday":    return .sunday
        default: return nil
        }
    }

    /// Three-letter abbreviation.
    public var abbreviation: String {
        switch self {
        case .monday:    return "Mon"
        case .tuesday:   return "Tue"
        case .wednesday: return "Wed"
        case .thursday:  return "Thu"
        case .friday:    return "Fri"
        case .saturday:  return "Sat"
        case .sunday:    return "Sun"
        }
    }

    /// The previous day of the week.
    public var previous: DayOfWeek {
        DayOfWeek(rawValue: (rawValue + 6) % 7)!
    }

    /// Advance by `n` days (mod 7).
    public func adding(_ n: Int) -> DayOfWeek {
        DayOfWeek(rawValue: (rawValue + (n % 7) + 7) % 7)!
    }
}

// MARK: - Time of day

/// A time within a day, represented as hours and minutes (24h format).
/// Independent of any timezone -- just a wall-clock reading.
public struct TimeOfDay: Sendable, Equatable, Comparable {
    public let hour: Int
    public let minute: Int

    /// Total seconds since midnight.
    public var totalSeconds: Int { hour * 3600 + minute * 60 }

    public init(hour: Int, minute: Int) {
        precondition(hour >= 0 && hour <= 23, "hour must be 0-23")
        precondition(minute >= 0 && minute <= 59, "minute must be 0-59")
        self.hour = hour
        self.minute = minute
    }

    /// Parse from "HH:MM" format. Returns nil on invalid input.
    public static func parse(_ s: String) -> TimeOfDay? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              h >= 0, h <= 23,
              m >= 0, m <= 59
        else { return nil }
        return TimeOfDay(hour: h, minute: m)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.totalSeconds < rhs.totalSeconds
    }

    public var description: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

// MARK: - Parsed schedule

/// A parsed window ready for time evaluation.
struct ParsedWindow: Sendable {
    let days: [DayOfWeek]
    let start: TimeOfDay
    let end: TimeOfDay
    /// True when end <= start (e.g. 22:00-08:00 = serve overnight).
    let overnight: Bool
}

/// A fully-parsed schedule ready for `isActiveNow()` checks.
///
/// Create via `Schedule.from(config:)`. If scheduling is disabled or no
/// valid windows exist, `from(config:)` returns nil -- meaning "always available".
public struct Schedule: Sendable {
    let windows: [ParsedWindow]

    /// Parse a `ScheduleConfig` into a `Schedule`.
    ///
    /// Returns nil when scheduling is disabled or no valid windows can be parsed,
    /// which means "always available" (no scheduling constraint).
    public static func from(config: ScheduleConfig) -> Schedule? {
        guard config.enabled, !config.windows.isEmpty else { return nil }

        var parsed: [ParsedWindow] = []
        for window in config.windows {
            let days = window.days.compactMap { DayOfWeek.parse($0) }
            guard !days.isEmpty else { continue }
            guard let start = TimeOfDay.parse(window.start) else { continue }
            guard let end = TimeOfDay.parse(window.end) else { continue }

            let overnight = end <= start
            parsed.append(ParsedWindow(days: days, start: start, end: end, overnight: overnight))
        }

        guard !parsed.isEmpty else { return nil }
        return Schedule(windows: parsed)
    }

    /// Check whether the current local time falls within any scheduled window.
    public func isActiveNow() -> Bool {
        isActive(at: Date())
    }

    /// Check whether a specific date falls within any scheduled window.
    /// Exposed for testing with deterministic times.
    public func isActive(at date: Date) -> Bool {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              let today = DayOfWeek.fromFoundationWeekday(weekday)
        else { return false }

        let now = TimeOfDay(hour: hour, minute: minute)
        let yesterday = today.previous

        for w in windows {
            if w.overnight {
                // Overnight window (e.g. 22:00-08:00):
                //   Active if: (today in days AND time >= start)
                //           OR (yesterday in days AND time < end)
                if w.days.contains(today) && now >= w.start {
                    return true
                }
                if w.days.contains(yesterday) && now < w.end {
                    return true
                }
            } else {
                // Same-day window (e.g. 09:00-17:00):
                if w.days.contains(today) && now >= w.start && now < w.end {
                    return true
                }
            }
        }

        return false
    }

    /// How long until the current active window ends.
    /// Returns nil if not currently active.
    public func durationUntilInactive(from date: Date = Date()) -> TimeInterval? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second,
              let today = DayOfWeek.fromFoundationWeekday(weekday)
        else { return nil }

        let now = TimeOfDay(hour: hour, minute: minute)
        let nowSeconds = hour * 3600 + minute * 60 + second
        let yesterday = today.previous

        for w in windows {
            if w.overnight {
                if w.days.contains(today) && now >= w.start {
                    // Window ends tomorrow at w.end
                    let remainingToday = 86400 - nowSeconds
                    let intoTomorrow = w.end.totalSeconds
                    return TimeInterval(remainingToday + intoTomorrow)
                }
                if w.days.contains(yesterday) && now < w.end {
                    // Window ends today at w.end
                    let diff = w.end.totalSeconds - nowSeconds
                    return TimeInterval(diff)
                }
            } else if w.days.contains(today) && now >= w.start && now < w.end {
                let diff = w.end.totalSeconds - nowSeconds
                return TimeInterval(diff)
            }
        }

        return nil
    }

    /// How long until the next window opens.
    /// Returns zero if already active.
    public func durationUntilNextActive(from date: Date = Date()) -> TimeInterval {
        if isActive(at: date) { return 0 }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second,
              let today = DayOfWeek.fromFoundationWeekday(weekday)
        else { return 3600 }

        let now = TimeOfDay(hour: hour, minute: minute)
        let nowSeconds = hour * 3600 + minute * 60 + second
        var minWait = Int.max

        // Check each window across the next 7 days
        for w in windows {
            for dayOffset in 0..<7 {
                let checkDay = today.adding(dayOffset)
                guard w.days.contains(checkDay) else { continue }

                let wait: Int
                if dayOffset == 0 && now < w.start {
                    // Today, window hasn't started yet
                    wait = w.start.totalSeconds - nowSeconds
                } else if dayOffset > 0 {
                    // Future day
                    let remainingToday = 86400 - nowSeconds
                    let fullDays = (dayOffset - 1) * 86400
                    let intoTarget = w.start.totalSeconds
                    wait = remainingToday + fullDays + intoTarget
                } else {
                    continue // Today but window already passed (or currently active, handled above)
                }

                if wait < minWait {
                    minWait = wait
                }
            }
        }

        if minWait == Int.max {
            return 3600 // Fallback: check again in 1 hour
        }
        return TimeInterval(minWait)
    }

    /// Human-readable description of the schedule.
    public func describe() -> String {
        windows.map { w in
            let days = w.days.map(\.abbreviation).joined(separator: ",")
            return "\(days) \(w.start.description)-\(w.end.description)"
        }.joined(separator: " | ")
    }
}

// MARK: - Duration formatting

/// Format a TimeInterval as a human-readable string (e.g. "2h 30m").
public func formatDuration(_ interval: TimeInterval) -> String {
    let secs = Int(interval)
    if secs < 60 {
        return "\(secs)s"
    } else if secs < 3600 {
        return "\(secs / 60)m"
    } else {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if m > 0 {
            return "\(h)h \(m)m"
        } else {
            return "\(h)h"
        }
    }
}
