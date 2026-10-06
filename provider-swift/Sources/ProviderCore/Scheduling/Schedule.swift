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

// MARK: - Day of week

/// Days of the week.
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
        let bytes = Array(s.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              [bytes[0], bytes[1], bytes[3], bytes[4]].allSatisfy({ (48...57).contains($0) })
        else { return nil }
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
/// Create via `Schedule.from(config:)`. Disabled schedules return nil (always
/// available); invalid enabled schedules contain no windows (unavailable).
public struct Schedule: Sendable {
    let windows: [ParsedWindow]

    /// Parse a `ScheduleConfig` into a `Schedule`.
    ///
    /// Returns nil only when disabled. Invalid enabled configurations fail closed.
    public static func from(config: ScheduleConfig) -> Schedule? {
        guard config.enabled else { return nil }
        do {
            try config.validate()
        } catch {
            return Schedule(windows: [])
        }

        var parsed: [ParsedWindow] = []
        for window in config.windows {
            let days = window.days.compactMap { DayOfWeek.parse($0) }
            guard !days.isEmpty else { continue }
            guard let start = TimeOfDay.parse(window.start) else { continue }
            guard let end = TimeOfDay.parse(window.end) else { continue }

            let overnight = end <= start
            parsed.append(ParsedWindow(days: days, start: start, end: end, overnight: overnight))
        }

        return Schedule(windows: parsed)
    }

    /// Check whether the current local time falls within any scheduled window.
    public func isActiveNow() -> Bool {
        isActive(at: Date())
    }

    /// Check whether a specific date falls within any scheduled window.
    /// Exposed for testing with deterministic times.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        intervals(around: date, calendar: calendar).contains { $0.start <= date && date < $0.end }
    }

    /// How long until the union of active windows ends.
    /// Returns nil when inactive or continuously available all week.
    public func durationUntilInactive(from date: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
        guard let active = intervals(around: date, calendar: calendar).first(where: {
            $0.start <= date && date < $0.end
        }), !coversEntireWeek else { return nil }
        return active.end.timeIntervalSince(date)
    }

    /// How long until the next window opens.
    /// Returns zero if already active.
    public func durationUntilNextActive(from date: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        for interval in intervals(around: date, calendar: calendar) where interval.end > date {
            return max(0, interval.start.timeIntervalSince(date))
        }
        return 3600 // Invalid enabled schedule: remain unavailable and recheck later.
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
    DurationFormatting.compact(interval)
}
