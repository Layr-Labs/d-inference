import Foundation
import Testing
@testable import ProviderCore

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
        let now = Date()
        let day = currentDayAbbreviation(for: now)
        let schedule = try #require(Schedule.from(config: ScheduleConfig(
            enabled: true,
            windows: [ScheduleWindow(days: [day], start: "00:00", end: "23:59")]
        )))

        #expect(schedule.isActive(at: now))
        let remaining = try #require(schedule.durationUntilInactive(from: now))
        #expect(remaining > 0)
        #expect(remaining <= 24 * 60 * 60)
    }

    @Test("overnight availability and timer share inclusive start and exclusive end")
    func overnightBoundaries() throws {
        let calendar = Calendar.current
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 4, hour: 22, minute: 0, second: 0)))
        let end = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 5, hour: 8, minute: 0, second: 0)))
        let schedule = try #require(Schedule.from(config: ScheduleConfig(
            enabled: true,
            windows: [ScheduleWindow(days: [currentDayAbbreviation(for: start)], start: "22:00", end: "08:00")]
        )))
        let cases: [(Date, TimeInterval?)] = [
            (start.addingTimeInterval(-1), nil), (start, 36000),
            (end.addingTimeInterval(-1), 1), (end, nil),
        ]
        for (date, remaining) in cases {
            #expect(schedule.isActive(at: date) == (remaining != nil))
            #expect(schedule.durationUntilInactive(from: date) == remaining)
        }
    }

    @Test("overlapping windows retain the first configured close timer")
    func overlappingWindowOrder() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 5, day: 4, hour: 12, minute: 0, second: 30)))
        let day = currentDayAbbreviation(for: now)
        let schedule = try #require(Schedule.from(config: ScheduleConfig(
            enabled: true,
            windows: [ScheduleWindow(days: [day], start: "09:00", end: "17:00"),
                      ScheduleWindow(days: [day], start: "10:00", end: "13:00")]
        )))
        #expect(schedule.isActive(at: now))
        #expect(schedule.durationUntilInactive(from: now) == 5 * 3600 - 30)
    }

    @Test("outside window reports time until next active")
    func inactiveWindowDurationUntilActive() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 2,
            hour: 12,
            minute: 0,
            second: 0
        )))
        let day = currentDayAbbreviation(for: now)
        let schedule = try #require(Schedule.from(config: ScheduleConfig(
            enabled: true,
            windows: [ScheduleWindow(days: [day], start: "13:00", end: "14:00")]
        )))

        #expect(!schedule.isActive(at: now))
        #expect(schedule.durationUntilNextActive(from: now) == 3600)
    }
}

private func currentDayAbbreviation(for date: Date) -> String {
    let weekday = Calendar.current.component(.weekday, from: date)
    switch weekday {
    case 1: return "sun"
    case 2: return "mon"
    case 3: return "tue"
    case 4: return "wed"
    case 5: return "thu"
    case 6: return "fri"
    default: return "sat"
    }
}
