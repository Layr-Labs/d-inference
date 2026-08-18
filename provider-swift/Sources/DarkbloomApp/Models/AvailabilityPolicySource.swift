import Foundation

struct AvailabilityScheduleWindowRecord: Codable, Equatable, Sendable {
    var days: [String]
    var start: String
    var end: String
}

struct AvailabilityScheduleRecord: Codable, Equatable, Sendable {
    var enabled: Bool
    var windows: [AvailabilityScheduleWindowRecord]
}

enum AvailabilityPolicySourceIssue: Equatable, Sendable {
    case scheduleHasNoWindows
    case invalidDay(windowIndex: Int, value: String)
    case invalidStartTime(windowIndex: Int, value: String)
    case invalidEndTime(windowIndex: Int, value: String)
    case invalidPolicy(AvailabilityPolicyValidationIssue)
}

enum AvailabilityPolicyResolution: Equatable, Sendable {
    case policy(AvailabilityPolicy)
    case malformed(issues: [AvailabilityPolicySourceIssue])
}

enum AvailabilityPolicyResolver {
    /// Resolves the persistent provider config without borrowing runtime or
    /// coordinator state. A missing or disabled schedule is the documented
    /// whenever-running default; an enabled malformed schedule remains a hard
    /// malformed state so the UI never presents it as "always available."
    static func resolve(
        schedule: AvailabilityScheduleRecord?,
        localTimeZone: AvailabilityLocalTimeZone = .current,
        idleUnloadMinutes: Int = AvailabilityPolicy.defaultIdleUnloadMinutes
    ) -> AvailabilityPolicyResolution {
        guard let schedule, schedule.enabled else {
            return .policy(AvailabilityPolicy(
                mode: .wheneverRunning,
                localTimeZone: localTimeZone,
                idleUnloadMinutes: idleUnloadMinutes
            ))
        }

        guard !schedule.windows.isEmpty else {
            return .malformed(issues: [.scheduleHasNoWindows])
        }

        var sourceIssues: [AvailabilityPolicySourceIssue] = []
        var windows: [AvailabilityWindow] = []

        for (index, record) in schedule.windows.enumerated() {
            var days = Set<AvailabilityWeekday>()
            for rawDay in record.days {
                guard let day = AvailabilityWeekday.parse(rawDay) else {
                    sourceIssues.append(.invalidDay(windowIndex: index, value: rawDay))
                    continue
                }
                days.insert(day)
            }

            guard let start = AvailabilityTimeOfDay.parseConfigurationValue(record.start) else {
                sourceIssues.append(.invalidStartTime(windowIndex: index, value: record.start))
                continue
            }
            guard let end = AvailabilityTimeOfDay.parseConfigurationValue(record.end) else {
                sourceIssues.append(.invalidEndTime(windowIndex: index, value: record.end))
                continue
            }

            windows.append(AvailabilityWindow(
                id: "window-\(index + 1)",
                days: days,
                start: start,
                end: end
            ))
        }

        guard sourceIssues.isEmpty else {
            return .malformed(issues: sourceIssues)
        }

        let policy = AvailabilityPolicy(
            mode: .scheduled,
            windows: windows,
            localTimeZone: localTimeZone,
            idleUnloadMinutes: idleUnloadMinutes
        )
        let validationIssues = policy.validation.issues.map(AvailabilityPolicySourceIssue.invalidPolicy)
        guard validationIssues.isEmpty else {
            return .malformed(issues: validationIssues)
        }
        return .policy(policy)
    }
}
