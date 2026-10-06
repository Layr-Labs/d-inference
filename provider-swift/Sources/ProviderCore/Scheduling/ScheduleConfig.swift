import Foundation

/// A single availability window as stored in config.
public struct ScheduleWindow: Codable, Sendable, Equatable {
    /// Days this window applies to (e.g. ["mon", "tue", "wed"]).
    public var days: [String]
    /// Start time in HH:MM 24h local time.
    public var start: String
    /// End time in HH:MM. End <= start wraps into the following day.
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

    /// Disabled schedules may retain malformed windows so disabling is always safe.
    public func validate() throws {
        guard enabled else { return }
        guard !windows.isEmpty else { throw ScheduleValidationError.noWindows }
        for (index, window) in windows.enumerated() {
            guard !window.days.isEmpty, window.days.allSatisfy({ DayOfWeek.parse($0) != nil }) else {
                throw ScheduleValidationError.invalidDays(window: index + 1)
            }
            guard TimeOfDay.parse(window.start) != nil else {
                throw ScheduleValidationError.invalidStart(window: index + 1, value: window.start)
            }
            guard TimeOfDay.parse(window.end) != nil else {
                throw ScheduleValidationError.invalidEnd(window: index + 1, value: window.end)
            }
        }
    }
}

public enum ScheduleValidationError: LocalizedError, Sendable, Equatable {
    case noWindows
    case invalidDays(window: Int)
    case invalidStart(window: Int, value: String)
    case invalidEnd(window: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .noWindows:
            return "An enabled schedule must contain at least one availability window."
        case .invalidDays(let window):
            return "Schedule window \(window) must contain valid days of the week."
        case .invalidStart(let window, let value):
            return "Schedule window \(window) has invalid start time '\(value)'; use HH:MM (00:00-23:59)."
        case .invalidEnd(let window, let value):
            return "Schedule window \(window) has invalid end time '\(value)'; use HH:MM (00:00-23:59)."
        }
    }
}
