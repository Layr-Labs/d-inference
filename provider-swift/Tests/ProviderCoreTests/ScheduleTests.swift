import Foundation
import Testing
@testable import ProviderCore
private var fixedCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private let calendarArithmeticTolerance: TimeInterval = 1e-6

private func matchesCalendarDuration(_ actual: TimeInterval, expected: TimeInterval) -> Bool {
    abs(actual - expected) <= calendarArithmeticTolerance
}

private var mondayAtNoon: Date {
    fixedCalendar.date(from: DateComponents(
        year: 2026, month: 5, day: 4, hour: 12
    ))!
}


@Suite("Provider schedule")
struct ScheduleTests {

    @Test("disabled schedule means always available")
    func disabledScheduleReturnsNil() {
        let schedule = Schedule.from(config: ScheduleConfig(
            enabled: false,
            windows: [ScheduleWindow(days: ["mon"], start: "09:00", end: "17:00")]
        ))
        #expect(schedule == nil)
    }

    @Test("active window reports time until close")
    func activeWindowDurationUntilInactive() throws {
        let schedule = try #require(Schedule.from(
            config: ScheduleConfig(
                enabled: true,
                windows: [ScheduleWindow(days: ["mon"], start: "09:00", end: "17:00")]
            ),
            calendar: fixedCalendar
        ))

        #expect(schedule.isActive(at: mondayAtNoon))
        let duration = try #require(schedule.durationUntilInactive(from: mondayAtNoon))
        #expect(matchesCalendarDuration(duration, expected: 5 * 60 * 60))
    }

    @Test("outside window reports time until next active")
    func inactiveWindowDurationUntilActive() throws {
        let schedule = try #require(Schedule.from(
            config: ScheduleConfig(
                enabled: true,
                windows: [ScheduleWindow(days: ["mon"], start: "13:00", end: "14:00")]
            ),
            calendar: fixedCalendar
        ))

        #expect(!schedule.isActive(at: mondayAtNoon))
        let duration = schedule.durationUntilNextActive(from: mondayAtNoon)
        #expect(matchesCalendarDuration(duration, expected: 60 * 60))
    }
}
