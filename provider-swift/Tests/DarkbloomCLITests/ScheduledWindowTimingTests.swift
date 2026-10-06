import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("Scheduled serving deadline capture")
struct ScheduledWindowTimingTests {
    @Test("a window closing between the initial check and capture never means continuous availability")
    func closedAtCapture() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let close = try #require(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day))
        let schedule = try #require(Schedule.from(config: ScheduleConfig(enabled: true, windows: [
            ScheduleWindow(days: DayOfWeek.allCases.map { $0.abbreviation }, start: "09:00", end: "10:00"),
            ScheduleWindow(days: DayOfWeek.allCases.map { $0.abbreviation }, start: "10:01", end: "11:00"),
        ])))
        #expect(schedule.isActive(at: close.addingTimeInterval(-1)))
        #expect(ScheduledWindowTiming(schedule: schedule, at: close) == nil)
        let next = try #require(ScheduledWindowTiming(schedule: schedule, at: close.addingTimeInterval(60)))
        #expect(next.end == close.addingTimeInterval(3600))
    }

    @Test("finite deadlines stay pinned before expensive model selection")
    func finiteDeadline() throws {
        let start = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        let schedule = try #require(Schedule.from(config: ScheduleConfig(enabled: true, windows: [
            ScheduleWindow(days: DayOfWeek.allCases.map { $0.abbreviation }, start: "09:00", end: "10:00"),
        ])))
        let timing = try #require(ScheduledWindowTiming(schedule: schedule, at: start))
        #expect(timing.end == start.addingTimeInterval(3600))
    }

    @Test("only an active full-week union omits the close timer")
    func continuousDeadline() throws {
        let schedule = try #require(Schedule.from(config: ScheduleConfig(enabled: true, windows: [
            ScheduleWindow(days: DayOfWeek.allCases.map { $0.abbreviation }, start: "00:00", end: "00:00"),
        ])))
        let timing = try #require(ScheduledWindowTiming(schedule: schedule, at: Date()))
        #expect(timing.end == nil)
    }
}
