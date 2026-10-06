import Foundation

extension Schedule {
    /// Include yesterday's overnight window and two recurrences. A DST jump can
    /// erase one week's gap, so the following week's close must also be visible.
    func intervals(around date: Date, calendar: Calendar) -> [DateInterval] {
        let today = calendar.startOfDay(for: date)
        var intervals: [DateInterval] = []
        for offset in -1...14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let weekday = DayOfWeek.fromFoundationWeekday(calendar.component(.weekday, from: day))
            else { continue }
            for window in windows where window.days.contains(weekday) {
                guard let endDay = calendar.date(byAdding: .day, value: window.overnight ? 1 : 0, to: day),
                      let start = boundary(window.start, on: day, calendar: calendar),
                      let end = boundary(window.end, on: endDay, calendar: calendar), end > start
                else { continue }
                intervals.append(DateInterval(start: start, end: end))
            }
        }
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Missing local times advance to the next valid time; repeated times use
    /// their first occurrence. Availability and both timers use this same policy.
    private func boundary(_ time: TimeOfDay, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// Wall-clock coverage is weekly, independent of a DST week's elapsed length.
    var coversEntireWeek: Bool {
        let daySeconds = 86400
        let weekSeconds = 7 * daySeconds
        let ranges = windows.flatMap { window in
            window.days.flatMap { day in
                [-weekSeconds, 0, weekSeconds].map { shift in
                    let start = day.rawValue * daySeconds + window.start.totalSeconds + shift
                    let end = day.rawValue * daySeconds + window.end.totalSeconds + shift
                        + (window.overnight ? daySeconds : 0)
                    return start..<end
                }
            }
        }.sorted { $0.lowerBound < $1.lowerBound }
        var end = 0
        for range in ranges where range.upperBound > 0 {
            if range.lowerBound > end { return false }
            end = max(end, range.upperBound)
            if end >= weekSeconds { return true }
        }
        return false
    }
}
