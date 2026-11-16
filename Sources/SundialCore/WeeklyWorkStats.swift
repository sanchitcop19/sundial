import Foundation

/// Work in completed calendar weeks with recorded history. Partial weeks at
/// either edge of a statistics period and entirely untracked weeks are omitted.
///
/// Weeks with time off are included and weighted by the planned days actually
/// worked: a week with one of five days off counts as 0.8 of a week, so four
/// days of work in it is an ordinary week. Counting it whole would under-weight
/// the average, and dropping it would over-weight every other week. Work done
/// on a day marked off is left out, since the day is not in the weighting.
/// A week with every planned day off has no weight to give, so it is counted
/// separately and cannot move the average.
public struct WeeklyWorkStats: Sendable, Equatable {
    /// Weeks that contributed to the average.
    public let completedWeeks: Int
    /// Work in those weeks, excluding days marked off.
    public let totalWork: TimeInterval
    /// Whole weeks' worth of time at work. Equal to `completedWeeks` when
    /// nobody was away.
    public let effectiveWeeks: Double
    /// Planned days off inside the counted weeks.
    public let outOfOfficeDays: Int
    /// Counted weeks with at least one planned day off.
    public let weeksWithTimeOff: Int
    /// Complete weeks in the period with every planned day off.
    public let weeksEntirelyOff: Int

    public init(completedWeeks: Int, totalWork: TimeInterval,
                effectiveWeeks: Double? = nil, outOfOfficeDays: Int = 0,
                weeksWithTimeOff: Int = 0, weeksEntirelyOff: Int = 0) {
        self.completedWeeks = completedWeeks
        self.totalWork = totalWork
        self.effectiveWeeks = effectiveWeeks ?? Double(completedWeeks)
        self.outOfOfficeDays = outOfOfficeDays
        self.weeksWithTimeOff = weeksWithTimeOff
        self.weeksEntirelyOff = weeksEntirelyOff
    }

    public var averageWork: TimeInterval? {
        effectiveWeeks > 0 ? totalWork / effectiveWeeks : nil
    }
}

public extension RangeStats {
    func weeklyWorkStats(period: StatsPeriod, now: Date, includeWeekends: Bool = false,
                         calendar: Calendar = StatsPeriod.calendar) -> WeeklyWorkStats {
        let bounds = period.interval(containing: now, calendar: calendar)

        /// The week containing `date`, if it lies wholly inside the period and is over.
        func completeWeek(containing date: Date) -> DateInterval? {
            guard date >= bounds.start, date < min(bounds.end, now),
                  let week = calendar.dateInterval(of: .weekOfYear, for: date),
                  week.start >= bounds.start, week.end <= bounds.end, week.end <= now
            else { return nil }
            return week
        }

        var weeks: [Date: DateInterval] = [:]
        var workByWeek: [Date: TimeInterval] = [:]
        for day in days {
            guard let week = completeWeek(containing: day.date) else { continue }
            weeks[week.start] = week
            // Even a recorded week with no work belongs in the denominator.
            workByWeek[week.start, default: 0] += outOfOffice.contains(day.day) ? 0 : day.work
        }
        // A week off needs no recording to be one.
        for key in outOfOffice.days {
            guard let date = OutOfOffice.date(of: key, calendar: calendar),
                  let week = completeWeek(containing: date) else { continue }
            weeks[week.start] = week
        }

        var completed = 0, awayDays = 0, withTimeOff = 0, entirelyOff = 0
        var total: TimeInterval = 0
        var effective = 0.0
        for (start, week) in weeks {
            let attendance = outOfOffice.attendance(of: week, includeWeekends: includeWeekends,
                                                    calendar: calendar)
            if attendance.fraction <= 0 { entirelyOff += 1; continue }
            guard let work = workByWeek[start] else { continue }
            completed += 1
            total += work
            effective += attendance.fraction
            awayDays += attendance.away
            if attendance.away > 0 { withTimeOff += 1 }
        }
        return WeeklyWorkStats(completedWeeks: completed, totalWork: total,
                               effectiveWeeks: effective, outOfOfficeDays: awayDays,
                               weeksWithTimeOff: withTimeOff, weeksEntirelyOff: entirelyOff)
    }
}
