import XCTest
@testable import SundialCore

final class WorkTargetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        return calendar
    }

    private var settings: Settings {
        var settings = Settings.default
        settings.smartWorkTargetEnabled = true
        return settings
    }

    private func date(_ day: Int, month: Int = 9, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func summary(_ day: String, hours: Double) -> DailySummary {
        DailySummary(date: day, work: hours * 3600)
    }

    private func target(_ day: Int, previous: [DailySummary] = [], worked: Double = 0,
                        settings: Settings? = nil, away: [String] = []) -> WorkTarget {
        WorkTarget.compute(settings: settings ?? self.settings, previousDays: previous,
                           workedToday: worked * 3600, now: date(day),
                           outOfOffice: OutOfOffice(days: Set(away)), calendar: calendar)
    }

    func testDisabledKeepsBaselineOnWeekendAfterWeeklyGoal() {
        let target = target(19, previous: [summary("2026-09-14", hours: 40)],
                            worked: 2, settings: .default)
        XCTAssertEqual(target.dailyTarget, 8 * 3600)
        XCTAssertEqual(target.remainingToday, 6 * 3600)
        XCTAssertEqual(target.weeklyWorked, 42 * 3600)
        XCTAssertEqual(target.weeklyRemaining, 0)
        XCTAssertFalse(target.isRestDay)
        XCTAssertFalse(target.isCapped)
    }

    func testShortMondayRaisesTuesdayTargetWithoutMovingAsWorkAccumulates() {
        let history = [summary("2026-09-14", hours: 6)]
        let morning = target(15, previous: history)
        let afternoon = target(15, previous: history, worked: 2)
        XCTAssertEqual(morning.dailyTarget, 8.5 * 3600)
        XCTAssertEqual(afternoon.dailyTarget, morning.dailyTarget)
        XCTAssertEqual(afternoon.remainingToday, 6.5 * 3600)
        XCTAssertEqual(afternoon.weeklyWorked, 8 * 3600)
        XCTAssertEqual(afternoon.weeklyRemaining, 32 * 3600)
        XCTAssertFalse(afternoon.isCapped)
    }

    func testAheadOfScheduleUsesLowerBoundWithoutExceedingWeeklyRemainder() {
        let ahead = target(15, previous: [summary("2026-09-14", hours: 20)])
        XCTAssertEqual(ahead.requiredDailyPace, 5 * 3600)
        XCTAssertEqual(ahead.dailyTarget, 6 * 3600)
        XCTAssertFalse(ahead.isCapped)

        let almostDone = target(15, previous: [summary("2026-09-14", hours: 39)], worked: 0.5)
        XCTAssertEqual(almostDone.dailyTarget, 3600)
        XCTAssertEqual(almostDone.remainingToday, 1800)
    }

    func testAlreadyCompletedWeekAndCompletionDuringToday() {
        let doneBeforeToday = target(15, previous: [summary("2026-09-14", hours: 41)])
        XCTAssertEqual(doneBeforeToday.dailyTarget, 0)
        XCTAssertEqual(doneBeforeToday.remainingToday, 0)
        XCTAssertEqual(doneBeforeToday.weeklyRemaining, 0)

        let doneToday = target(15, previous: [summary("2026-09-14", hours: 39)], worked: 2)
        XCTAssertEqual(doneToday.dailyTarget, 3600)
        XCTAssertEqual(doneToday.remainingToday, 0)
        XCTAssertEqual(doneToday.weeklyRemaining, 0)
    }

    func testCustomDailyBaselineAndSmallerWeeklyGoal() {
        var settings = self.settings
        settings.dailyWorkTarget = 6 * 3600
        settings.weeklyWorkTarget = 30 * 3600
        let adjusted = target(15, previous: [summary("2026-09-14", hours: 4)], settings: settings)
        XCTAssertEqual(adjusted.dailyTarget, 6.5 * 3600)

        settings.weeklyWorkTarget = 2 * 3600
        let smallGoal = target(14, settings: settings)
        XCTAssertEqual(smallGoal.dailyTarget, 2 * 3600)
    }

    func testImpossibleCatchUpUsesUpperBoundAndReportsRequiredPace() {
        let friday = target(18)
        XCTAssertEqual(friday.dailyTarget, 10 * 3600)
        XCTAssertEqual(friday.requiredDailyPace, 40 * 3600)
        XCTAssertTrue(friday.isCapped)

        var settings = self.settings
        settings.dailyWorkTarget = 24 * 3600
        settings.weeklyWorkTarget = 168 * 3600
        let longBaseline = target(18, settings: settings)
        XCTAssertEqual(longBaseline.dailyTarget, 24 * 3600)
        XCTAssertTrue(longBaseline.isCapped)
    }

    func testWeekendRestDaysStillCreditWeekendWork() {
        let saturday = target(19, previous: [summary("2026-09-18", hours: 30)], worked: 5)
        XCTAssertTrue(saturday.isRestDay)
        XCTAssertEqual(saturday.dailyTarget, 0)
        XCTAssertEqual(saturday.weeklyWorked, 35 * 3600)
        XCTAssertEqual(saturday.weeklyRemaining, 5 * 3600)

        let sunday = target(20, previous: [summary("2026-09-18", hours: 30),
                                           summary("2026-09-19", hours: 5)], worked: 2)
        XCTAssertTrue(sunday.isRestDay)
        XCTAssertEqual(sunday.weeklyWorked, 37 * 3600)
        XCTAssertEqual(sunday.weeklyRemaining, 3 * 3600)
        XCTAssertEqual(sunday.requiredDailyPace, 0)
        XCTAssertFalse(sunday.isCapped)
    }

    func testIncludingWeekendsPlansSaturdayAndSunday() {
        var settings = self.settings
        settings.includeWeekendsInWorkTarget = true
        let saturday = target(19, previous: [summary("2026-09-18", hours: 24)], settings: settings)
        XCTAssertFalse(saturday.isRestDay)
        XCTAssertEqual(saturday.requiredDailyPace, 8 * 3600)
        XCTAssertEqual(saturday.dailyTarget, 8 * 3600)

        let sunday = target(20, previous: [summary("2026-09-18", hours: 24),
                                           summary("2026-09-19", hours: 8)], settings: settings)
        XCTAssertEqual(sunday.dailyTarget, 8 * 3600)
    }

    func testOnlyPreviousDatesInCurrentWeekCountAndTodayIsNotDuplicated() {
        let result = target(15, previous: [summary("2026-09-13", hours: 80),
                                           summary("2026-09-14", hours: 8),
                                           summary("2026-09-15", hours: 15),
                                           summary("2026-09-16", hours: 99)], worked: 2)
        XCTAssertEqual(result.weeklyWorked, 10 * 3600)
        XCTAssertEqual(result.dailyTarget, 8 * 3600)
    }

    func testDailyRolloverRecalculatesFromTheNewCompletedDay() {
        let history = [summary("2026-09-14", hours: 8), summary("2026-09-15", hours: 10)]
        let midnight = date(16, hour: 0)
        let before = WorkTarget.compute(settings: settings, previousDays: history,
                                        workedToday: 10 * 3600, now: midnight - 1, calendar: calendar)
        let after = WorkTarget.compute(settings: settings, previousDays: history,
                                       workedToday: 0, now: midnight, calendar: calendar)
        XCTAssertEqual(before.dailyTarget, 8 * 3600)
        XCTAssertEqual(after.dailyTarget, 22 * 3600 / 3, accuracy: 0.001)
        XCTAssertEqual(after.weeklyWorked, 18 * 3600)
    }

    func testMondayRolloverStartsFreshWeek() {
        let result = WorkTarget.compute(settings: settings,
                                        previousDays: [summary("2026-09-20", hours: 12)],
                                        workedToday: 0, now: date(21, hour: 0), calendar: calendar)
        XCTAssertEqual(result.dailyTarget, 8 * 3600)
        XCTAssertEqual(result.weeklyWorked, 0)
    }

    func testDSTWeekendsUseCalendarDays() {
        var settings = self.settings
        settings.includeWeekendsInWorkTarget = true
        for (now, monday) in [(date(8, month: 3, hour: 0), "2026-03-02"),
                              (date(1, month: 11, hour: 0), "2026-10-26")] {
            let result = WorkTarget.compute(settings: settings,
                                            previousDays: [summary(monday, hours: 32)],
                                            workedToday: 0, now: now, calendar: calendar)
            XCTAssertEqual(result.requiredDailyPace, 8 * 3600)
            XCTAssertEqual(result.dailyTarget, 8 * 3600)
        }
    }

    // MARK: out of office

    func testNoDaysOffLeavesTheWeeklyGoalAlone() {
        let result = target(15, previous: [summary("2026-09-14", hours: 6)])
        XCTAssertEqual(result.weeklyTarget, 40 * 3600)
        XCTAssertEqual(result.plannedDaysAway, 0)
        XCTAssertFalse(result.isOutOfOffice)
    }

    func testADayOffLaterInTheWeekShrinksTheGoalAndSharesWorkOverFewerDays() {
        let result = target(15, previous: [summary("2026-09-14", hours: 6)], away: ["2026-09-18"])
        XCTAssertEqual(result.weeklyTarget, 32 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.plannedDaysAway, 1)
        XCTAssertEqual(result.weeklyRemaining, 26 * 3600, accuracy: 0.001)
        // 26h left over Tuesday, Wednesday and Thursday.
        XCTAssertEqual(result.requiredDailyPace, 26.0 / 3 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.dailyTarget, 26.0 / 3 * 3600, accuracy: 0.001)
        XCTAssertFalse(result.isCapped)
    }

    func testADayOffEarlierInTheWeekAlsoShrinksTheGoal() {
        let result = target(17, previous: [summary("2026-09-14", hours: 8), summary("2026-09-15", hours: 8)],
                            away: ["2026-09-16"])
        XCTAssertEqual(result.weeklyTarget, 32 * 3600, accuracy: 0.001)
        // 16h left over Thursday and Friday.
        XCTAssertEqual(result.requiredDailyPace, 8 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.dailyTarget, 8 * 3600, accuracy: 0.001)
    }

    func testWorkOnADayOffStillCountsTowardTheWeek() {
        let result = target(17, previous: [summary("2026-09-14", hours: 8), summary("2026-09-15", hours: 8),
                                           summary("2026-09-16", hours: 3)],
                            away: ["2026-09-16"])
        XCTAssertEqual(result.weeklyWorked, 19 * 3600)
        XCTAssertEqual(result.weeklyRemaining, 13 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.dailyTarget, 6.5 * 3600, accuracy: 0.001)
    }

    func testTodayOutOfOfficeHasNoTargetButItsWorkStillCounts() {
        let result = target(16, previous: [summary("2026-09-14", hours: 8), summary("2026-09-15", hours: 8)],
                            worked: 2, away: ["2026-09-16"])
        XCTAssertTrue(result.isOutOfOffice)
        XCTAssertFalse(result.isRestDay)
        XCTAssertEqual(result.dailyTarget, 0)
        XCTAssertEqual(result.remainingToday, 0)
        XCTAssertEqual(result.weeklyWorked, 18 * 3600)
        XCTAssertEqual(result.weeklyTarget, 32 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.weeklyRemaining, 14 * 3600, accuracy: 0.001)
        XCTAssertFalse(result.isCapped)
    }

    func testTodayOutOfOfficeHasNoTargetEvenWithoutSmartAdjustment() {
        let result = target(16, settings: .default, away: ["2026-09-16"])
        XCTAssertTrue(result.isOutOfOffice)
        XCTAssertEqual(result.dailyTarget, 0)
        XCTAssertEqual(target(16, settings: .default).dailyTarget, 8 * 3600)
    }

    func testOnlyFridayLeftInAShortWeekIsNotCapped() {
        let result = target(18, worked: 3, away: ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17"])
        XCTAssertEqual(result.weeklyTarget, 8 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.dailyTarget, 8 * 3600, accuracy: 0.001)
        XCTAssertEqual(result.weeklyRemaining, 5 * 3600, accuracy: 0.001)
        XCTAssertFalse(result.isCapped)
        XCTAssertTrue(target(18).isCapped, "the same Friday without time off is hopeless")
    }

    func testAWholeWeekOffHasNoWeeklyTarget() {
        let week = ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18"]
        let saturday = target(19, worked: 1, away: week)
        XCTAssertEqual(saturday.weeklyTarget, 0)
        XCTAssertEqual(saturday.weeklyRemaining, 0)
        XCTAssertEqual(saturday.weeklyWorked, 3600)
        XCTAssertEqual(saturday.dailyTarget, 0)

        let monday = target(14, away: week)
        XCTAssertTrue(monday.isOutOfOffice)
        XCTAssertEqual(monday.dailyTarget, 0)
        XCTAssertEqual(monday.requiredDailyPace, 0)
    }

    func testWeekendDaysOffDoNotShrinkAMondayToFridayGoal() {
        let result = target(15, away: ["2026-09-19", "2026-09-20"])
        XCTAssertEqual(result.weeklyTarget, 40 * 3600)
        XCTAssertEqual(result.plannedDaysAway, 0)
    }

    func testSaturdayOffShrinksASevenDayGoalByASeventh() {
        var settings = self.settings
        settings.includeWeekendsInWorkTarget = true
        let result = target(15, settings: settings, away: ["2026-09-19"])
        XCTAssertEqual(result.weeklyTarget, 40 * 3600 * 6 / 7, accuracy: 0.001)
        XCTAssertEqual(result.plannedDaysAway, 1)
    }

    func testDaysOffInOtherWeeksAreIgnored() {
        let baseline = target(15, previous: [summary("2026-09-14", hours: 6)])
        let result = target(15, previous: [summary("2026-09-14", hours: 6)],
                            away: ["2026-09-07", "2026-09-08", "2026-09-21", "2026-09-22"])
        XCTAssertEqual(result, baseline)
    }

    func testMondayRolloverIntoAWeekOffStartsWithNoTarget() {
        let monday = date(21, hour: 0)
        let result = WorkTarget.compute(settings: settings, previousDays: [summary("2026-09-18", hours: 8)],
                                        workedToday: 0, now: monday,
                                        outOfOffice: OutOfOffice(days: ["2026-09-21"]), calendar: calendar)
        XCTAssertTrue(result.isOutOfOffice)
        XCTAssertEqual(result.dailyTarget, 0)
        XCTAssertEqual(result.weeklyWorked, 0, "last week's work is not carried over")
        XCTAssertEqual(result.weeklyTarget, 32 * 3600, accuracy: 0.001)
    }

    func testPlannedDayRule() {
        XCTAssertTrue(WorkTarget.isPlannedDay(date(18), includeWeekends: false, calendar: calendar))
        XCTAssertFalse(WorkTarget.isPlannedDay(date(19), includeWeekends: false, calendar: calendar))
        XCTAssertFalse(WorkTarget.isPlannedDay(date(20), includeWeekends: false, calendar: calendar))
        XCTAssertTrue(WorkTarget.isPlannedDay(date(20), includeWeekends: true, calendar: calendar))
    }
}
