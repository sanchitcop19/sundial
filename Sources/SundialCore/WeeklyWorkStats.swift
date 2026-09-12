import Foundation

/// Work in completed calendar weeks with recorded history. Partial weeks at
/// either edge of a statistics period and entirely untracked weeks are omitted.
public struct WeeklyWorkStats: Sendable, Equatable {
    public let completedWeeks: Int
    public let totalWork: TimeInterval

    public var averageWork: TimeInterval? {
        completedWeeks > 0 ? totalWork / Double(completedWeeks) : nil
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

        return WeeklyWorkStats(completedWeeks: workByWeek.count,
                               totalWork: workByWeek.values.reduce(0, +))
    }
}
