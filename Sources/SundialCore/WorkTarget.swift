import Foundation

/// Today's target is based on completed days, so it stays steady as today's
/// work accumulates. Weekend work always contributes to the weekly total.
///
/// Days marked out of office are not planned days: the weekly goal shrinks in
/// proportion to the planned days lost, and an out-of-office day has no target.
/// Work done on one still counts toward the week.
public struct WorkTarget: Sendable, Equatable {
    public let dailyTarget: TimeInterval
    public let remainingToday: TimeInterval
    public let weeklyWorked: TimeInterval
    /// The weekly goal after planned days out of office are taken off.
    public let weeklyTarget: TimeInterval
    public let weeklyRemaining: TimeInterval
    public let requiredDailyPace: TimeInterval
    public let isRestDay: Bool
    public let isOutOfOffice: Bool
    /// Planned days this week marked out of office.
    public let plannedDaysAway: Int
    public let isCapped: Bool

    public static func isPlannedDay(_ date: Date, includeWeekends: Bool,
                                    calendar: Calendar = StatsPeriod.calendar) -> Bool {
        includeWeekends || ![1, 7].contains(calendar.component(.weekday, from: date))
    }

    public static func compute(settings: Settings, previousDays: [DailySummary],
                               workedToday: TimeInterval, now: Date,
                               outOfOffice: OutOfOffice = OutOfOffice(),
                               calendar: Calendar = StatsPeriod.calendar) -> WorkTarget {
        let week = StatsPeriod.week.interval(containing: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let todayKey = Format.day(today, calendar: calendar)
        let weekStartKey = Format.day(week.start, calendar: calendar)
        let priorWork = previousDays
            .filter { $0.date >= weekStartKey && $0.date < todayKey }
            .reduce(0) { $0 + max(0, $1.work) }
        let worked = max(0, workedToday)
        let weeklyWorked = priorWork + worked

        let attendance = outOfOffice.attendance(of: week, includeWeekends: settings.includeWeekendsInWorkTarget,
                                                calendar: calendar)
        let weeklyTarget = settings.weeklyWorkTarget * attendance.fraction
        let workAtStartOfDay = max(0, weeklyTarget - priorWork)

        func isPlanned(_ date: Date) -> Bool {
            WorkTarget.isPlannedDay(date, includeWeekends: settings.includeWeekendsInWorkTarget,
                                    calendar: calendar)
        }
        var plannedDays = 0
        var date = today
        while date < week.end {
            if isPlanned(date), !outOfOffice.contains(date, calendar: calendar) { plannedDays += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        let pace = plannedDays > 0 ? workAtStartOfDay / Double(plannedDays) : 0
        let upperTarget = min(24 * 3600, settings.dailyWorkTarget * 1.25)
        let isAway = outOfOffice.contains(todayKey)
        let isRestDay = settings.smartWorkTargetEnabled && !isPlanned(today)
        let target: TimeInterval
        if isAway {
            target = 0
        } else if !settings.smartWorkTargetEnabled {
            target = settings.dailyWorkTarget
        } else if isRestDay {
            target = 0
        } else {
            target = min(workAtStartOfDay,
                         min(max(pace, settings.dailyWorkTarget * 0.75), upperTarget))
        }
        return WorkTarget(dailyTarget: target,
                          remainingToday: max(0, target - worked),
                          weeklyWorked: weeklyWorked,
                          weeklyTarget: weeklyTarget,
                          weeklyRemaining: max(0, weeklyTarget - weeklyWorked),
                          requiredDailyPace: pace,
                          isRestDay: isRestDay,
                          isOutOfOffice: isAway,
                          plannedDaysAway: attendance.away,
                          isCapped: settings.smartWorkTargetEnabled && !isRestDay && !isAway
                              && pace > upperTarget)
    }
}
