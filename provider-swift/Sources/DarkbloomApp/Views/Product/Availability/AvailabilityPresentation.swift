import Foundation

struct AvailabilityHorizonSegment: Equatable, Identifiable, Sendable {
    let id: String
    let startMinute: Int
    let endMinute: Int
    let continuesFromPreviousDay: Bool
    let continuesIntoNextDay: Bool

    var startFraction: Double {
        Double(startMinute) / 1_440
    }

    var endFraction: Double {
        Double(endMinute) / 1_440
    }
}

enum AvailabilityPresentation {
    static func planTitle(_ mode: AvailabilityPolicyMode) -> String {
        switch mode {
        case .wheneverRunning: "Whenever Darkbloom is running"
        case .scheduled: "On a schedule"
        }
    }

    static func planDetail(_ mode: AvailabilityPolicyMode) -> String {
        switch mode {
        case .wheneverRunning:
            "The network provider may connect whenever its process is running."
        case .scheduled:
            "The network provider connects only inside your local schedule windows."
        }
    }

    static func runtimeTitle(_ state: AvailabilityRuntimeState?) -> String {
        switch state {
        case .available: "Available now"
        case .serving: "Serving now"
        case .paused: "Paused"
        case .scheduledOff: "Outside scheduled hours"
        case .attention: "Needs attention"
        case .stale: "Status needs a refresh"
        case .starting: "Starting"
        case .stopping: "Pausing"
        case .restarting: "Restarting"
        case nil: "Runtime not reported"
        }
    }

    static func runtimeDetail(
        _ state: AvailabilityRuntimeState?,
        policy: AvailabilityPolicy
    ) -> String {
        switch state {
        case .available:
            policy.mode == .scheduled
                ? "This Mac is inside a scheduled availability window."
                : "Darkbloom is ready to accept network work while the provider runs."
        case .serving:
            "This Mac is currently processing private inference."
        case .paused:
            "The provider was paused manually. Your availability plan is still saved."
        case .scheduledOff:
            "The provider remains under schedule control and will return at the next window."
        case .attention:
            "Review the provider before relying on its current availability."
        case .stale:
            "The last runtime observation is too old to describe the provider now."
        case .starting:
            "The provider is applying its current availability plan."
        case .stopping:
            "The provider is finishing its pause transition."
        case .restarting:
            "The provider is restarting to apply its configuration."
        case nil:
            "Darkbloom has not reported a current provider runtime observation."
        }
    }

    static func scheduleSummary(_ policy: AvailabilityPolicy) -> String {
        guard policy.mode == .scheduled else {
            return planTitle(.wheneverRunning)
        }
        guard let first = policy.windows.first else {
            return "No schedule windows"
        }

        let firstSummary = windowSummary(first, timeZone: policy.localTimeZone)
        let remaining = policy.windows.count - 1
        return remaining > 0 ? "\(firstSummary) · +\(remaining) more" : firstSummary
    }

    static func windowSummary(
        _ window: AvailabilityWindow,
        timeZone: AvailabilityLocalTimeZone
    ) -> String {
        let days = daySummary(window.days)
        let start = timeString(window.start, timeZone: timeZone)
        let end = timeString(window.end, timeZone: timeZone)
        let overnight = window.isOvernight && window.start != window.end ? " · Overnight" : ""
        return "\(days) · \(start)–\(end)\(overnight)"
    }

    static func daySummary(_ days: Set<AvailabilityWeekday>) -> String {
        if days == Set(AvailabilityWeekday.allCases) {
            return "Every day"
        }

        let weekdays: Set<AvailabilityWeekday> = [
            .monday, .tuesday, .wednesday, .thursday, .friday,
        ]
        if days == weekdays {
            return "Mon–Fri"
        }
        if days == [.saturday, .sunday] {
            return "Sat–Sun"
        }

        return days
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.abbreviation)
            .joined(separator: ", ")
    }

    static func idleUnloadTitle(_ minutes: Int) -> String {
        if minutes == 0 {
            return "Keep models loaded"
        }
        if minutes == 60 {
            return "After 1 hour"
        }
        if minutes.isMultiple(of: 60) {
            return "After \(minutes / 60) hours"
        }
        return "After \(minutes) minutes"
    }

    static func idleUnloadDetail(_ minutes: Int) -> String {
        if minutes == 0 {
            return "Idle unloading is disabled. Resident models stay loaded until another provider action releases them."
        }
        return "A model may unload \(idleUnloadTitle(minutes).lowercased()) without inference. This measures model activity, not whether you are using your Mac."
    }

    static func timeZoneTitle(_ timeZone: AvailabilityLocalTimeZone) -> String {
        if let abbreviation = timeZone.abbreviation, !abbreviation.isEmpty {
            return "\(timeZone.identifier) (\(abbreviation))"
        }
        return timeZone.identifier
    }

    static func timeString(
        _ time: AvailabilityTimeOfDay,
        timeZone: AvailabilityLocalTimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone.identifier) ?? .autoupdatingCurrent
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2001,
            month: 1,
            day: 1,
            hour: time.hour,
            minute: time.minute
        )
        guard let date = calendar.date(from: components) else {
            return time.configurationValue
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func transitionDetail(
        _ date: Date?,
        timeZone: AvailabilityLocalTimeZone
    ) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZone.identifier) ?? .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Next observed change at \(formatter.string(from: date))"
    }

    static func nextPlannedBoundaryDetail(
        for policy: AvailabilityPolicy,
        after date: Date
    ) -> String? {
        guard let boundary = nextPlannedBoundary(for: policy, after: date) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: policy.localTimeZone.identifier)
            ?? .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Next planned boundary at \(formatter.string(from: boundary))"
    }

    /// Derives the next local schedule edge from the saved policy instead of
    /// relying on a coordinator heartbeat. This keeps the horizon useful while
    /// the provider is intentionally disconnected outside a window.
    static func nextPlannedBoundary(
        for policy: AvailabilityPolicy,
        after date: Date
    ) -> Date? {
        guard policy.mode == .scheduled, !policy.windows.isEmpty else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: policy.localTimeZone.identifier)
            ?? .autoupdatingCurrent
        let localDay = calendar.startOfDay(for: date)
        var candidates: [Date] = []

        for dayOffset in -1 ... 8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: localDay) else {
                continue
            }
            let dayOfWeek = weekday(for: day, calendar: calendar)

            for window in policy.windows where window.days.contains(dayOfWeek) {
                guard let start = calendar.date(
                    byAdding: .minute,
                    value: window.start.minutesSinceMidnight,
                    to: day
                ) else { continue }

                let endDay = window.isOvernight
                    ? (calendar.date(byAdding: .day, value: 1, to: day) ?? day)
                    : day
                guard let end = calendar.date(
                    byAdding: .minute,
                    value: window.end.minutesSinceMidnight,
                    to: endDay
                ) else { continue }

                if start > date { candidates.append(start) }
                if end > date { candidates.append(end) }
            }
        }

        return candidates.min()
    }

    static func validationMessage(
        _ issue: AvailabilityPolicyValidationIssue,
        policy: AvailabilityPolicy
    ) -> String {
        switch issue {
        case .scheduleHasNoWindows:
            "Add at least one availability window."
        case .windowHasNoDays(let windowID):
            "\(windowName(windowID, policy: policy)) needs at least one day."
        case .windowHasEqualStartAndEnd(let windowID):
            "\(windowName(windowID, policy: policy)) cannot begin and end at the same time."
        case .windowsOverlapOrTouch(let firstWindowID, let secondWindowID):
            "\(windowName(firstWindowID, policy: policy)) overlaps or touches \(windowName(secondWindowID, policy: policy)). Leave a gap or combine them."
        case .invalidIdleUnloadMinutes:
            "Idle model unloading cannot use a negative duration."
        }
    }

    static func sourceIssueMessage(_ issue: AvailabilityPolicySourceIssue) -> String {
        switch issue {
        case .scheduleHasNoWindows:
            "The enabled schedule has no availability windows."
        case .invalidDay(let index, let value):
            "Window \(index + 1) contains an unknown day, “\(value)”."
        case .invalidStartTime(let index, let value):
            "Window \(index + 1) has an invalid start time, “\(value)”."
        case .invalidEndTime(let index, let value):
            "Window \(index + 1) has an invalid end time, “\(value)”."
        case .invalidPolicy(let issue):
            sourcePolicyIssueMessage(issue)
        }
    }

    static func horizonSegments(
        for policy: AvailabilityPolicy,
        at date: Date
    ) -> [AvailabilityHorizonSegment] {
        guard policy.mode == .scheduled else {
            return [AvailabilityHorizonSegment(
                id: "whenever-running",
                startMinute: 0,
                endMinute: 1_440,
                continuesFromPreviousDay: true,
                continuesIntoNextDay: true
            )]
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: policy.localTimeZone.identifier) ?? .autoupdatingCurrent
        let currentDay = weekday(for: date, calendar: calendar)
        let previousDay = AvailabilityWeekday.allCases.first {
            $0.sortIndex == (currentDay.sortIndex + 6) % 7
        } ?? .sunday

        var segments: [AvailabilityHorizonSegment] = []
        for window in policy.windows where window.start != window.end {
            if window.isOvernight, window.days.contains(previousDay) {
                segments.append(AvailabilityHorizonSegment(
                    id: "\(window.id)-previous",
                    startMinute: 0,
                    endMinute: window.end.minutesSinceMidnight,
                    continuesFromPreviousDay: true,
                    continuesIntoNextDay: false
                ))
            }

            guard window.days.contains(currentDay) else { continue }
            segments.append(AvailabilityHorizonSegment(
                id: "\(window.id)-current",
                startMinute: window.start.minutesSinceMidnight,
                endMinute: window.isOvernight ? 1_440 : window.end.minutesSinceMidnight,
                continuesFromPreviousDay: false,
                continuesIntoNextDay: window.isOvernight
            ))
        }

        return segments.sorted {
            if $0.startMinute == $1.startMinute {
                return $0.endMinute < $1.endMinute
            }
            return $0.startMinute < $1.startMinute
        }
    }

    static func minuteOfDay(
        at date: Date,
        timeZone: AvailabilityLocalTimeZone
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone.identifier) ?? .autoupdatingCurrent
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return min(1_439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    static func horizonAccessibilityValue(
        policy: AvailabilityPolicy,
        runtime: AvailabilityRuntimeSnapshot?,
        at date: Date
    ) -> String {
        let current = minuteOfDay(at: date, timeZone: policy.localTimeZone)
        let currentTime = AvailabilityTimeOfDay(
            hour: current / 60,
            minute: current % 60
        ).map { timeString($0, timeZone: policy.localTimeZone) } ?? "current time"
        let windows = policy.mode == .scheduled
            ? policy.windows.map { windowSummary($0, timeZone: policy.localTimeZone) }.joined(separator: "; ")
            : "all 24 hours while Darkbloom is running"
        let transition = nextPlannedBoundaryDetail(for: policy, after: date)
            ?? transitionDetail(
                runtime?.nextObservedTransitionAt,
                timeZone: policy.localTimeZone
            )
            ?? "No next runtime transition reported"

        return [
            runtimeTitle(runtime?.state),
            "Current local time \(currentTime)",
            "Plan: \(planTitle(policy.mode))",
            windows,
            transition,
            "Timezone \(timeZoneTitle(policy.localTimeZone))",
        ].joined(separator: ". ")
    }

    private static func weekday(for date: Date, calendar: Calendar) -> AvailabilityWeekday {
        switch calendar.component(.weekday, from: date) {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: .monday
        }
    }

    private static func windowName(_ id: String, policy: AvailabilityPolicy) -> String {
        guard let index = policy.windows.firstIndex(where: { $0.id == id }) else {
            return "A schedule window"
        }
        return "Window \(index + 1)"
    }

    private static func sourcePolicyIssueMessage(_ issue: AvailabilityPolicyValidationIssue) -> String {
        switch issue {
        case .scheduleHasNoWindows:
            "The enabled schedule has no availability windows."
        case .windowHasNoDays:
            "A saved schedule window has no days."
        case .windowHasEqualStartAndEnd:
            "A saved schedule window begins and ends at the same time."
        case .windowsOverlapOrTouch:
            "Saved schedule windows overlap or touch."
        case .invalidIdleUnloadMinutes:
            "The saved idle model unload duration is invalid."
        }
    }
}
