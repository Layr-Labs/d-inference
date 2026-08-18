import Foundation

enum AvailabilityPolicyMode: String, Codable, CaseIterable, Sendable {
    /// The provider may connect whenever the process is running.
    case wheneverRunning = "whenever-running"
    /// The provider connects only during one or more local wall-clock windows.
    case scheduled
}

enum AvailabilityWeekday: String, Codable, CaseIterable, Hashable, Sendable {
    case monday = "mon"
    case tuesday = "tue"
    case wednesday = "wed"
    case thursday = "thu"
    case friday = "fri"
    case saturday = "sat"
    case sunday = "sun"

    var sortIndex: Int {
        switch self {
        case .monday: 0
        case .tuesday: 1
        case .wednesday: 2
        case .thursday: 3
        case .friday: 4
        case .saturday: 5
        case .sunday: 6
        }
    }

    var abbreviation: String {
        rawValue.capitalized
    }

    static func parse(_ value: String) -> AvailabilityWeekday? {
        switch value.lowercased() {
        case "mon", "monday": .monday
        case "tue", "tuesday": .tuesday
        case "wed", "wednesday": .wednesday
        case "thu", "thursday": .thursday
        case "fri", "friday": .friday
        case "sat", "saturday": .saturday
        case "sun", "sunday": .sunday
        default: nil
        }
    }
}

struct AvailabilityTimeOfDay: Codable, Comparable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    init?(hour: Int, minute: Int) {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
            return nil
        }
        self.hour = hour
        self.minute = minute
    }

    var minutesSinceMidnight: Int {
        hour * 60 + minute
    }

    var configurationValue: String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func parseConfigurationValue(_ value: String) -> AvailabilityTimeOfDay? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else {
            return nil
        }
        return AvailabilityTimeOfDay(hour: hour, minute: minute)
    }

    static func < (lhs: AvailabilityTimeOfDay, rhs: AvailabilityTimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

/// A schedule is interpreted in the Mac's current local timezone. The identifier
/// is an observation for display and review, not a fixed timezone persisted by
/// the provider config. If the system timezone changes, provider evaluation
/// follows the new local timezone.
struct AvailabilityLocalTimeZone: Codable, Equatable, Sendable {
    var identifier: String
    var abbreviation: String?
    var observesSystemChanges: Bool

    init(
        identifier: String,
        abbreviation: String? = nil,
        observesSystemChanges: Bool = true
    ) {
        self.identifier = identifier
        self.abbreviation = abbreviation
        self.observesSystemChanges = observesSystemChanges
    }

    init(timeZone: TimeZone) {
        self.init(
            identifier: timeZone.identifier,
            abbreviation: timeZone.abbreviation(),
            observesSystemChanges: true
        )
    }

    static var current: AvailabilityLocalTimeZone {
        AvailabilityLocalTimeZone(timeZone: .autoupdatingCurrent)
    }
}

struct AvailabilityWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var days: Set<AvailabilityWeekday>
    var start: AvailabilityTimeOfDay
    var end: AvailabilityTimeOfDay

    init(
        id: String,
        days: Set<AvailabilityWeekday>,
        start: AvailabilityTimeOfDay,
        end: AvailabilityTimeOfDay
    ) {
        self.id = id
        self.days = days
        self.start = start
        self.end = end
    }

    /// Mirrors provider scheduling: an end at or before the start wraps into
    /// the following day. Equal endpoints are still rejected by UI validation
    /// because a 24-hour window is too easy to create accidentally.
    var isOvernight: Bool {
        end <= start
    }
}

struct AvailabilityPolicy: Codable, Equatable, Sendable {
    static let defaultIdleUnloadMinutes = 60

    var mode: AvailabilityPolicyMode
    var windows: [AvailabilityWindow]
    var localTimeZone: AvailabilityLocalTimeZone
    /// Minutes after the last inference before an idle model may be unloaded.
    /// Zero disables idle unloading and keeps resident models loaded.
    var idleUnloadMinutes: Int

    init(
        mode: AvailabilityPolicyMode = .wheneverRunning,
        windows: [AvailabilityWindow] = [],
        localTimeZone: AvailabilityLocalTimeZone = .current,
        idleUnloadMinutes: Int = AvailabilityPolicy.defaultIdleUnloadMinutes
    ) {
        self.mode = mode
        self.windows = windows
        self.localTimeZone = localTimeZone
        self.idleUnloadMinutes = idleUnloadMinutes
    }

    var idleUnloadingIsDisabled: Bool {
        idleUnloadMinutes == 0
    }

    var validation: AvailabilityPolicyValidation {
        AvailabilityPolicyValidator.validate(self)
    }
}

enum AvailabilityPolicyValidationIssue: Equatable, Sendable {
    case scheduleHasNoWindows
    case windowHasNoDays(windowID: String)
    case windowHasEqualStartAndEnd(windowID: String)
    case windowsOverlapOrTouch(firstWindowID: String, secondWindowID: String)
    case invalidIdleUnloadMinutes
}

struct AvailabilityPolicyValidation: Equatable, Sendable {
    var issues: [AvailabilityPolicyValidationIssue]

    var isValid: Bool {
        issues.isEmpty
    }
}

private enum AvailabilityPolicyValidator {
    private static let minutesPerDay = 24 * 60
    private static let minutesPerWeek = 7 * minutesPerDay

    private struct WeeklyInterval {
        var occurrenceID: String
        var windowID: String
        var start: Int
        var end: Int
    }

    static func validate(_ policy: AvailabilityPolicy) -> AvailabilityPolicyValidation {
        var issues: [AvailabilityPolicyValidationIssue] = []

        if policy.idleUnloadMinutes < 0 {
            issues.append(.invalidIdleUnloadMinutes)
        }

        guard policy.mode == .scheduled else {
            return AvailabilityPolicyValidation(issues: issues)
        }

        if policy.windows.isEmpty {
            issues.append(.scheduleHasNoWindows)
            return AvailabilityPolicyValidation(issues: issues)
        }

        for window in policy.windows {
            if window.days.isEmpty {
                issues.append(.windowHasNoDays(windowID: window.id))
            }
            if window.start == window.end {
                issues.append(.windowHasEqualStartAndEnd(windowID: window.id))
            }
        }

        let intervals = policy.windows.flatMap(expand)
        for firstIndex in intervals.indices {
            for secondIndex in intervals.indices where secondIndex > firstIndex {
                let first = intervals[firstIndex]
                let second = intervals[secondIndex]
                guard intervalsOverlapOrTouch(first, second) else { continue }

                let firstID = first.windowID
                let secondID = second.windowID
                let issue = AvailabilityPolicyValidationIssue.windowsOverlapOrTouch(
                    firstWindowID: firstID,
                    secondWindowID: secondID
                )
                if !issues.contains(issue) {
                    issues.append(issue)
                }
            }
        }

        return AvailabilityPolicyValidation(issues: issues)
    }

    private static func expand(_ window: AvailabilityWindow) -> [WeeklyInterval] {
        guard window.start != window.end else { return [] }

        return window.days.map { day in
            let start = day.sortIndex * minutesPerDay + window.start.minutesSinceMidnight
            let endDayOffset = window.end <= window.start ? minutesPerDay : 0
            let end = day.sortIndex * minutesPerDay + endDayOffset + window.end.minutesSinceMidnight
            return WeeklyInterval(
                occurrenceID: "\(window.id)-\(day.rawValue)",
                windowID: window.id,
                start: start,
                end: end
            )
        }
    }

    private static func intervalsOverlapOrTouch(
        _ first: WeeklyInterval,
        _ second: WeeklyInterval
    ) -> Bool {
        guard first.occurrenceID != second.occurrenceID else { return false }

        for weekShift in [-minutesPerWeek, 0, minutesPerWeek] {
            let shiftedStart = second.start + weekShift
            let shiftedEnd = second.end + weekShift
            if max(first.start, shiftedStart) <= min(first.end, shiftedEnd) {
                return true
            }
        }
        return false
    }
}
