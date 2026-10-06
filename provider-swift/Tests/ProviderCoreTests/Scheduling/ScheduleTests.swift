import Foundation
import Testing
@testable import ProviderCore

@Suite("Provider schedule")
struct ScheduleTests {
    private let calendar = scheduleCalendar("UTC")

    @Test("disabled schedule permits retained malformed windows and means always available")
    func disabledScheduleReturnsNil() throws {
        for windows in [[], [ScheduleWindow(days: ["invalid"], start: "bad", end: "25:00")]] {
            let config = ScheduleConfig(enabled: false, windows: windows)
            try config.validate()
            #expect(Schedule.from(config: config) == nil)
        }
    }

    @Test("enabled malformed schedules throw and fail closed without partially accepting windows")
    func invalidEnabledSchedules() throws {
        let valid = ScheduleWindow(days: ["mon"], start: "09:00", end: "17:00")
        let invalidWindows = [
            ScheduleWindow(days: [], start: "09:00", end: "17:00"),
            ScheduleWindow(days: ["mon", "bogus"], start: "09:00", end: "17:00"),
            ScheduleWindow(days: ["mon"], start: "24:00", end: "17:00"),
            ScheduleWindow(days: ["mon"], start: "09:60", end: "17:00"),
            ScheduleWindow(days: ["mon"], start: "9:00", end: "17:00"),
            ScheduleWindow(days: ["mon"], start: "09:00", end: "17:00:00"),
            ScheduleWindow(days: ["mon"], start: "09:00", end: "-1:00"),
            ScheduleWindow(days: ["mon"], start: "09:00", end: ""),
        ]
        let configs = [ScheduleConfig(enabled: true)] + invalidWindows.flatMap {
            [ScheduleConfig(enabled: true, windows: [$0]),
             ScheduleConfig(enabled: true, windows: [valid, $0])]
        }
        let now = scheduleDate(2026, 5, 4, 12, calendar: calendar)
        for config in configs {
            #expect(throws: ScheduleValidationError.self) { try config.validate() }
            let schedule = try #require(Schedule.from(config: config))
            #expect(!schedule.isActive(at: now, calendar: calendar))
            #expect(schedule.durationUntilInactive(from: now, calendar: calendar) == nil)
            #expect(schedule.durationUntilNextActive(from: now, calendar: calendar) > 0)
        }
    }

    @Test("validation retains case-insensitive short and full days and equal-time full days")
    func validScheduleConfig() throws {
        try ScheduleConfig(enabled: true, windows: [
            ScheduleWindow(days: ["MON", "Tuesday"], start: "00:00", end: "00:00"),
        ]).validate()
    }

    @Test("overnight availability and timer share inclusive start and exclusive end")
    func overnightBoundaries() throws {
        let start = scheduleDate(2026, 5, 4, 22, calendar: calendar)
        let end = scheduleDate(2026, 5, 5, 8, calendar: calendar)
        let schedule = try makeSchedule([ScheduleWindow(days: ["mon"], start: "22:00", end: "08:00")])
        let cases: [(Date, TimeInterval?)] = [
            (start.addingTimeInterval(-1), nil), (start, 36000),
            (end.addingTimeInterval(-1), 1), (end, nil),
        ]
        for (date, remaining) in cases {
            #expect(schedule.isActive(at: date, calendar: calendar) == (remaining != nil))
            #expect(schedule.durationUntilInactive(from: date, calendar: calendar) == remaining)
        }
    }

    @Test("overlapping close timer uses the union regardless of configured order")
    func overlappingWindowOrder() throws {
        let now = scheduleDate(2026, 5, 4, 12, second: 30, calendar: calendar)
        let windows = [ScheduleWindow(days: ["mon"], start: "09:00", end: "13:00"),
                       ScheduleWindow(days: ["mon"], start: "10:00", end: "17:00")]
        for ordered in [windows, Array(windows.reversed())] {
            let schedule = try makeSchedule(ordered)
            #expect(schedule.isActive(at: now, calendar: calendar))
            #expect(schedule.durationUntilInactive(from: now, calendar: calendar) == TimeInterval(5 * 3600 - 30))
        }
    }

    @Test("close timer follows chained overlap and adjacency, not later disconnected windows")
    func chainedWindows() throws {
        let schedule = try makeSchedule([
            ScheduleWindow(days: ["mon"], start: "09:00", end: "12:00"),
            ScheduleWindow(days: ["mon"], start: "11:00", end: "14:00"),
            ScheduleWindow(days: ["mon"], start: "14:00", end: "17:00"),
            ScheduleWindow(days: ["mon"], start: "18:00", end: "19:00"),
        ])
        let now = scheduleDate(2026, 5, 4, 10, calendar: calendar)
        #expect(schedule.durationUntilInactive(from: now, calendar: calendar) == TimeInterval(7 * 3600))
        let end = scheduleDate(2026, 5, 4, 17, calendar: calendar)
        #expect(!schedule.isActive(at: end, calendar: calendar))
        #expect(schedule.durationUntilNextActive(from: end, calendar: calendar) == 3600)
    }

    @Test("overnight overlap and adjacency extend across the weekly boundary")
    func overnightUnion() throws {
        let schedule = try makeSchedule([
            ScheduleWindow(days: ["sun"], start: "22:00", end: "08:00"),
            ScheduleWindow(days: ["mon"], start: "07:00", end: "10:00"),
            ScheduleWindow(days: ["mon"], start: "10:00", end: "12:00"),
        ])
        let sunday = scheduleDate(2026, 5, 3, 23, calendar: calendar)
        let monday = scheduleDate(2026, 5, 4, 9, calendar: calendar)
        #expect(schedule.durationUntilInactive(from: sunday, calendar: calendar) == TimeInterval(13 * 3600))
        #expect(schedule.durationUntilInactive(from: monday, calendar: calendar) == TimeInterval(3 * 3600))
    }

    @Test("adjacent full-day windows remain active for the whole weekend")
    func weekendUnion() throws {
        let schedule = try makeSchedule([
            ScheduleWindow(days: ["fri", "sat", "sun"], start: "00:00", end: "00:00"),
        ])
        let now = scheduleDate(2026, 5, 1, 10, calendar: calendar)
        #expect(schedule.durationUntilInactive(from: now, calendar: calendar) == TimeInterval(62 * 3600))
    }

    @Test("all-week continuous availability has no close timer")
    func continuousAvailability() throws {
        let days = DayOfWeek.allCases.map(\.abbreviation)
        let configurations = [
            [ScheduleWindow(days: days, start: "00:00", end: "00:00")],
            [ScheduleWindow(days: days, start: "09:00", end: "09:00")],
            [ScheduleWindow(days: days, start: "00:00", end: "12:00"),
             ScheduleWindow(days: days, start: "12:00", end: "00:00")],
        ]
        let now = scheduleDate(2026, 5, 4, 10, calendar: calendar)
        for windows in configurations {
            let schedule = try makeSchedule(windows)
            #expect(schedule.isActive(at: now, calendar: calendar))
            #expect(schedule.durationUntilInactive(from: now, calendar: calendar) == nil)
            #expect(schedule.durationUntilNextActive(from: now, calendar: calendar) == 0)
            let local = scheduleCalendar("America/New_York")
            for dstDate in [scheduleDate(2026, 3, 8, 3, calendar: local),
                            scheduleDate(2026, 11, 1, 2, calendar: local)] {
                #expect(schedule.isActive(at: dstDate, calendar: local))
                #expect(schedule.durationUntilInactive(from: dstDate, calendar: local) == nil)
            }
        }
    }

    @Test("single weekly window recurs on the same weekday seven calendar days later")
    func weeklyRecurrence() throws {
        let schedule = try makeSchedule([ScheduleWindow(days: ["mon"], start: "09:00", end: "10:00")])
        let before = scheduleDate(2026, 5, 4, 8, calendar: calendar)
        let closed = scheduleDate(2026, 5, 4, 10, calendar: calendar)
        let next = scheduleDate(2026, 5, 11, 9, calendar: calendar)
        #expect(schedule.durationUntilNextActive(from: before, calendar: calendar) == 3600)
        #expect(schedule.durationUntilNextActive(from: closed, calendar: calendar) == next.timeIntervalSince(closed))
        #expect(schedule.durationUntilNextActive(from: closed, calendar: calendar) == 167 * 3600)
    }

    @Test("next active chooses the earliest of multiple windows")
    func nextWindowUnion() throws {
        let schedule = try makeSchedule([
            ScheduleWindow(days: ["tue"], start: "09:00", end: "10:00"),
            ScheduleWindow(days: ["mon"], start: "13:00", end: "14:00"),
        ])
        let now = scheduleDate(2026, 5, 4, 12, calendar: calendar)
        #expect(schedule.durationUntilNextActive(from: now, calendar: calendar) == 3600)
    }

    @Test("weekly recurrence respects spring-forward and fall-back elapsed time")
    func dstWeeklyRecurrence() throws {
        let local = scheduleCalendar("America/New_York")
        let schedule = try makeSchedule([ScheduleWindow(days: ["sun"], start: "09:00", end: "10:00")])
        for (month, previousDay, nextMonth, nextDay, expectedHours) in [(3, 1, 3, 8, 166), (10, 25, 11, 1, 168)] {
            let now = scheduleDate(2026, month, previousDay, 10, calendar: local)
            let next = scheduleDate(2026, nextMonth, nextDay, 9, calendar: local)
            #expect(schedule.durationUntilNextActive(from: now, calendar: local) == next.timeIntervalSince(now))
            #expect(schedule.durationUntilNextActive(from: now, calendar: local) == Double(expectedHours * 3600))
        }
    }

    @Test("overnight close timers account for DST jumps in either direction")
    func dstOvernightClose() throws {
        let local = scheduleCalendar("America/New_York")
        let schedule = try makeSchedule([ScheduleWindow(days: ["sat"], start: "22:00", end: "08:00")])
        let spring = scheduleDate(2026, 3, 7, 22, calendar: local)
        let fall = scheduleDate(2026, 10, 31, 22, calendar: local)
        #expect(schedule.durationUntilInactive(from: spring, calendar: local) == TimeInterval(9 * 3600))
        #expect(schedule.durationUntilInactive(from: fall, calendar: local) == TimeInterval(11 * 3600))
    }

    @Test("nonexistent opening moves to the next valid time and repeated opening uses the first occurrence")
    func dstBoundaryPolicy() throws {
        let local = scheduleCalendar("America/New_York")
        let springSchedule = try makeSchedule([ScheduleWindow(days: ["sun"], start: "02:30", end: "04:00")])
        let beforeSpring = scheduleDate(2026, 3, 8, 1, minute: 30, calendar: local)
        let springStart = scheduleDate(2026, 3, 8, 3, calendar: local)
        #expect(springSchedule.durationUntilNextActive(from: beforeSpring, calendar: local) == 30 * 60)
        #expect(springSchedule.isActive(at: springStart, calendar: local))
        #expect(springSchedule.durationUntilInactive(from: springStart, calendar: local) == 3600)

        let fallSchedule = try makeSchedule([ScheduleWindow(days: ["sun"], start: "01:30", end: "02:30")])
        let beforeFall = scheduleDate(2026, 11, 1, 0, minute: 30, calendar: local)
        let firstOpening = beforeFall.addingTimeInterval(3600)
        #expect(fallSchedule.durationUntilNextActive(from: beforeFall, calendar: local) == 3600)
        #expect(fallSchedule.durationUntilInactive(from: firstOpening, calendar: local) == TimeInterval(2 * 3600))
        #expect(fallSchedule.isActive(at: firstOpening.addingTimeInterval(3600), calendar: local))
    }

    @Test("a spring-forward erased weekly gap still closes at the following week's gap")
    func dstErasedGap() throws {
        let local = scheduleCalendar("America/New_York")
        let schedule = try makeSchedule([
            ScheduleWindow(days: ["mon", "tue", "wed", "thu", "fri", "sat"], start: "00:00", end: "00:00"),
            ScheduleWindow(days: ["sun"], start: "00:00", end: "02:00"),
            ScheduleWindow(days: ["sun"], start: "03:00", end: "00:00"),
        ])
        let now = scheduleDate(2026, 3, 7, 12, calendar: local)
        let end = scheduleDate(2026, 3, 15, 2, calendar: local)
        #expect(schedule.durationUntilInactive(from: now, calendar: local) == end.timeIntervalSince(now))
    }
}

private func makeSchedule(_ windows: [ScheduleWindow]) throws -> Schedule {
    let config = ScheduleConfig(enabled: true, windows: windows)
    try config.validate()
    return try #require(Schedule.from(config: config))
}

private func scheduleCalendar(_ timeZone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    return calendar
}

private func scheduleDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int,
                          minute: Int = 0, second: Int = 0, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute, second: second))!
}
