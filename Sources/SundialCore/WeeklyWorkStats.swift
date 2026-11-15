import Foundation

/// Work in completed calendar weeks with recorded history. Partial weeks at
/// either edge of a statistics period and entirely untracked weeks are omitted.
public struct WeeklyWorkStats: Sendable, Equatable {
    public let completedWeeks: Int
    public let totalWork: TimeInterval
    /// Complete weeks less the weekdays taken off in them: a week with two
    /// days off counts as 0.6 of a week. What the average divides by.
    public let weeksWorked: Double
    /// Weekdays off inside the complete weeks counted.
    public let timeOffDays: Int

    public init(completedWeeks: Int, totalWork: TimeInterval,
                weeksWorked: Double? = nil, timeOffDays: Int = 0) {
        self.completedWeeks = completedWeeks
        self.totalWork = totalWork
        self.weeksWorked = weeksWorked ?? Double(completedWeeks)
        self.timeOffDays = timeOffDays
    }

    /// Work on days off stays in the total while those days come out of the
    /// weeks, so it can only lift the average. Nil when every complete week was
    /// taken off entirely, as there is no ordinary week to compare against.
    public var averageWork: TimeInterval? {
        weeksWorked > 0 ? totalWork / weeksWorked : nil
    }
}

public extension RangeStats {
    func weeklyWorkStats(period: StatsPeriod, now: Date,
                         calendar: Calendar = StatsPeriod.calendar) -> WeeklyWorkStats {
        let bounds = period.interval(containing: now, calendar: calendar)
        var workByWeek: [Date: TimeInterval] = [:]

        for day in days {
            guard day.date >= bounds.start, day.date < min(bounds.end, now),
                  let week = calendar.dateInterval(of: .weekOfYear, for: day.date),
                  week.start >= bounds.start, week.end <= bounds.end, week.end <= now
            else { continue }

            // Even a recorded week with no work belongs in the denominator.
            workByWeek[week.start, default: 0] += day.work
        }

        var weeksWorked = 0.0
        var daysOff = 0
        for weekStart in workByWeek.keys {
            let off = timeOffWeekdays(inWeekStarting: weekStart, calendar: calendar)
            daysOff += off
            weeksWorked += Double(max(0, 5 - off)) / 5
        }

        return WeeklyWorkStats(completedWeeks: workByWeek.count,
                               totalWork: workByWeek.values.reduce(0, +),
                               weeksWorked: weeksWorked, timeOffDays: daysOff)
    }

    private func timeOffWeekdays(inWeekStarting start: Date, calendar: Calendar) -> Int {
        guard !timeOff.isEmpty else { return 0 }
        return (0..<7).filter { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return false }
            return !TimeOff.isWeekend(date, calendar: calendar)
                && timeOff.contains(Format.day(date, calendar: calendar))
        }.count
    }
}
