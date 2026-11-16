import XCTest
@testable import SundialCore

final class WeeklyWorkStatsTests: XCTestCase {
    private func calendar(_ timezone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ year: Int = 2026, _ month: Int, _ day: Int, hours: Double,
                     calendar: Calendar) -> DayStats {
        let start = date(year, month, day, calendar: calendar)
        var totals = Totals()
        totals.byState[.work] = hours * 3600
        return DayStats(day: Format.day(start, calendar: calendar), date: start,
                        totals: totals, workByHour: Array(repeating: 0, count: 24),
                        personalByHour: Array(repeating: 0, count: 24),
                        firstActivity: nil, lastActivity: nil, longestFocus: 0,
                        focusBlocks: 0, contextSwitches: 0, callSeconds: 0)
    }

    private func stats(_ days: [DayStats], period: StatsPeriod = .month,
                       now: Date, outOfOffice: OutOfOffice = OutOfOffice(),
                       includeWeekends: Bool = false, calendar: Calendar) -> WeeklyWorkStats {
        RangeStats(days: days, contexts: [], outOfOffice: outOfOffice)
            .weeklyWorkStats(period: period, now: now, includeWeekends: includeWeekends,
                             calendar: calendar)
    }

    private func away(_ days: String..., calendar: Calendar) -> OutOfOffice {
        OutOfOffice(days: Set(days))
    }

    func testMonthAverageUsesWholeCompletedWeeksAndIncludesWeekendWork() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 8, 31, hours: 80, calendar: cal), // Outside the month.
            day(2026, 9, 1, hours: 80, calendar: cal),  // Partial opening week.
            day(2026, 9, 7, hours: 8, calendar: cal),
            day(2026, 9, 8, hours: 8, calendar: cal),
            day(2026, 9, 13, hours: 4, calendar: cal),  // Sunday belongs to that week.
            day(2026, 9, 14, hours: 10, calendar: cal),
            day(2026, 9, 21, hours: 80, calendar: cal), // Ongoing week.
            day(2026, 9, 28, hours: 80, calendar: cal), // Future week.
        ], now: date(2026, 9, 23, 12, calendar: cal), calendar: cal)

        XCTAssertEqual(result.completedWeeks, 2)
        XCTAssertEqual(result.totalWork, 30 * 3600)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 15 * 3600)
    }

    func testQuarterIncludesEarlierMonthsButExcludesItsPartialOpeningWeek() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 6, 29, hours: 80, calendar: cal),
            day(2026, 7, 1, hours: 80, calendar: cal),
            day(2026, 7, 6, hours: 12, calendar: cal),
            day(2026, 8, 3, hours: 24, calendar: cal),
            day(2026, 9, 7, hours: 18, calendar: cal),
            day(2026, 9, 28, hours: 80, calendar: cal),
        ], period: .quarter, now: date(2026, 9, 30, 23, calendar: cal), calendar: cal)

        XCTAssertEqual(result.completedWeeks, 3)
        XCTAssertEqual(result.totalWork, 54 * 3600)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 18 * 3600)
    }

    func testYearExcludesWeeksCrossingEitherYearBoundary() throws {
        let cal = calendar()
        let result = stats([
            day(2025, 12, 29, hours: 80, calendar: cal),
            day(2026, 1, 1, hours: 80, calendar: cal),
            day(2026, 1, 5, hours: 10, calendar: cal),
            day(2026, 6, 1, hours: 20, calendar: cal),
            day(2026, 12, 21, hours: 30, calendar: cal),
            day(2026, 12, 28, hours: 80, calendar: cal),
            day(2027, 1, 4, hours: 80, calendar: cal),
        ], period: .year, now: date(2026, 12, 31, 23, calendar: cal), calendar: cal)

        XCTAssertEqual(result.completedWeeks, 3)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 20 * 3600)
    }

    func testWeekCountsAtExactMondayRollover() throws {
        let cal = calendar()
        let days = [day(2026, 9, 7, hours: 8, calendar: cal)]
        let monday = date(2026, 9, 14, calendar: cal)
        let before = stats(days, now: monday.addingTimeInterval(-1), calendar: cal)
        let after = stats(days, now: monday, calendar: cal)

        XCTAssertEqual(before.completedWeeks, 0)
        XCTAssertNil(before.averageWork)
        XCTAssertEqual(after.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(after.averageWork), 8 * 3600)
    }

    func testPeriodRolloverStartsANewAverage() {
        let cal = calendar()
        let days = [day(2026, 9, 7, hours: 8, calendar: cal)]
        for period in [StatsPeriod.month, .quarter] {
            let result = stats(days, period: period,
                               now: date(2026, 10, 1, calendar: cal), calendar: cal)
            XCTAssertEqual(result.completedWeeks, 0)
            XCTAssertEqual(result.totalWork, 0)
            XCTAssertNil(result.averageWork)
        }
        let nextYear = stats(days, period: .year,
                             now: date(2027, 1, 1, calendar: cal), calendar: cal)
        XCTAssertNil(nextYear.averageWork)
    }

    func testNoCompletedWeekReturnsNoAverageRatherThanZero() {
        let cal = calendar()
        let now = date(2026, 9, 11, calendar: cal)
        let result = stats([day(2026, 9, 8, hours: 8, calendar: cal)],
                           now: now, calendar: cal)

        XCTAssertEqual(result.completedWeeks, 0)
        XCTAssertEqual(result.totalWork, 0)
        XCTAssertNil(result.averageWork)
        XCTAssertNil(stats([], now: now, calendar: cal).averageWork)
    }

    func testRecordedZeroWorkWeekCountsButEntirelyMissingWeeksDoNot() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 8, 3, hours: 20, calendar: cal),
            day(2026, 8, 17, hours: 0, calendar: cal),
        ], now: date(2026, 8, 31, calendar: cal), calendar: cal)

        XCTAssertEqual(result.completedWeeks, 2)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 10 * 3600)
        let zero = stats([day(2026, 8, 3, hours: 0, calendar: cal)],
                         now: date(2026, 8, 31, calendar: cal), calendar: cal)
        XCTAssertEqual(zero.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(zero.averageWork), 0)
    }

    func testTrackingStartedRecentlyDoesNotCountEarlierUntrackedWeeks() throws {
        let cal = calendar()
        let result = stats([day(2026, 9, 7, hours: 12, calendar: cal)], period: .year,
                           now: date(2026, 9, 14, calendar: cal), calendar: cal)

        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 12 * 3600)
    }

    func testInjectedSundayStartControlsBothCompletionAndGrouping() throws {
        let cal = calendar(firstWeekday: 1)
        let days = [day(2026, 9, 6, hours: 10, calendar: cal),
                    day(2026, 9, 12, hours: 6, calendar: cal),
                    day(2026, 9, 13, hours: 80, calendar: cal)]
        let sunday = date(2026, 9, 13, calendar: cal)
        XCTAssertNil(stats(days, now: sunday.addingTimeInterval(-1), calendar: cal).averageWork)
        let result = stats(days, now: sunday, calendar: cal)

        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 16 * 3600)
    }

    func testSpringDSTWeekFinishesAtLocalMondayMidnight() throws {
        let cal = calendar("America/Los_Angeles")
        let days = [day(2026, 3, 2, hours: 8, calendar: cal),
                    day(2026, 3, 8, hours: 4, calendar: cal)]
        let monday = date(2026, 3, 9, calendar: cal)
        XCTAssertNil(stats(days, now: monday.addingTimeInterval(-1), calendar: cal).averageWork)
        let result = stats(days, now: monday, calendar: cal)

        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 12 * 3600)
    }

    func testAutumnDSTWeekDoesNotFinishAnHourEarly() throws {
        let cal = calendar("America/Los_Angeles")
        let days = [day(2026, 10, 26, hours: 8, calendar: cal),
                    day(2026, 11, 1, hours: 4, calendar: cal)]
        let monday = date(2026, 11, 2, calendar: cal)
        XCTAssertNil(stats(days, period: .quarter,
                           now: monday.addingTimeInterval(-1), calendar: cal).averageWork)
        let result = stats(days, period: .quarter, now: monday, calendar: cal)

        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 12 * 3600)
    }

    func testCurrentWeekCannotContainACompletedWeek() {
        let cal = calendar()
        let result = stats([day(2026, 9, 7, hours: 8, calendar: cal)], period: .week,
                           now: date(2026, 9, 13, 23, calendar: cal), calendar: cal)
        XCTAssertEqual(result.completedWeeks, 0)
        XCTAssertNil(result.averageWork)
    }

    // MARK: out of office

    func testUnrecordedDaysOutOfOfficeShrinkTheWeekRatherThanTheAverage() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 9, 11, hours: 8, calendar: cal),  // The only day worked that week.
            day(2026, 9, 14, hours: 40, calendar: cal),
        ], now: date(2026, 9, 23, 12, calendar: cal),
        outOfOffice: away("2026-09-07", "2026-09-08", "2026-09-09", "2026-09-10", calendar: cal),
        calendar: cal)

        XCTAssertEqual(result.completedWeeks, 2)
        XCTAssertEqual(result.effectiveWeeks, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result.outOfOfficeDays, 4)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600, accuracy: 0.001,
                       "a four-day holiday should not make the week look short")
    }

    func testWorkDoneOnADayOutOfOfficeDoesNotInflateTheAverage() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 9, 7, hours: 8, calendar: cal),
            day(2026, 9, 8, hours: 8, calendar: cal),
            day(2026, 9, 9, hours: 8, calendar: cal),
            day(2026, 9, 10, hours: 8, calendar: cal),
            day(2026, 9, 11, hours: 3, calendar: cal),   // Some email on the day off.
        ], now: date(2026, 9, 16, 12, calendar: cal),
        outOfOffice: away("2026-09-11", calendar: cal), calendar: cal)

        XCTAssertEqual(result.totalWork, 32 * 3600)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600, accuracy: 0.001)
    }

    func testAWeekEntirelyOutOfOfficeIsLeftOut() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 9, 9, hours: 5, calendar: cal),
            day(2026, 9, 14, hours: 40, calendar: cal),
        ], now: date(2026, 9, 23, 12, calendar: cal),
        outOfOffice: away("2026-09-07", "2026-09-08", "2026-09-09", "2026-09-10",
                          "2026-09-11", calendar: cal), calendar: cal)

        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(result.outOfOfficeDays, 0)
        XCTAssertEqual(result.weeksEntirelyOff, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600)

        let onlyThatWeek = stats([day(2026, 9, 9, hours: 5, calendar: cal)],
                                 now: date(2026, 9, 23, 12, calendar: cal),
                                 outOfOffice: away("2026-09-07", "2026-09-08", "2026-09-09",
                                                   "2026-09-10", "2026-09-11", calendar: cal),
                                 calendar: cal)
        XCTAssertEqual(onlyThatWeek.completedWeeks, 0)
        XCTAssertEqual(onlyThatWeek.weeksEntirelyOff, 1)
        XCTAssertNil(onlyThatWeek.averageWork)
    }

    func testAWeekendOutOfOfficeDoesNotShortenAMondayToFridayWeek() throws {
        let cal = calendar()
        let days = [day(2026, 9, 7, hours: 20, calendar: cal),
                    day(2026, 9, 12, hours: 20, calendar: cal)]
        let now = date(2026, 9, 16, 12, calendar: cal)
        let saturday = away("2026-09-12", calendar: cal)

        let weekdaysOnly = stats(days, now: now, outOfOffice: saturday, calendar: cal)
        XCTAssertEqual(weekdaysOnly.effectiveWeeks, 1)
        XCTAssertEqual(weekdaysOnly.outOfOfficeDays, 0)
        XCTAssertEqual(try XCTUnwrap(weekdaysOnly.averageWork), 20 * 3600,
                       "the day off is excluded, even though it was not a planned day")

        let sevenDays = stats(days, now: now, outOfOffice: saturday, includeWeekends: true,
                              calendar: cal)
        XCTAssertEqual(sevenDays.effectiveWeeks, 6.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(sevenDays.outOfOfficeDays, 1)
    }

    func testInitDefaultsAssumeNobodyWasAway() {
        let plain = WeeklyWorkStats(completedWeeks: 2, totalWork: 100)
        XCTAssertEqual(plain.effectiveWeeks, 2)
        XCTAssertEqual(plain.outOfOfficeDays, 0)
        XCTAssertEqual(plain.averageWork, 50)
    }

    func testWeeksWithTimeOffNeitherOverNorUnderweightTheAverage() throws {
        let cal = calendar()
        // Three ordinary 40-hour weeks, one week with two days off and 24 hours
        // worked in the other three (the same rate), and one with four days off.
        let days = [
            day(2026, 9, 7, hours: 40, calendar: cal),
            day(2026, 9, 14, hours: 40, calendar: cal),
            day(2026, 9, 21, hours: 40, calendar: cal),
            day(2026, 9, 28, hours: 24, calendar: cal),
            day(2026, 10, 7, hours: 8, calendar: cal),
        ]
        let result = stats(days, period: .year, now: date(2026, 10, 14, 12, calendar: cal),
                           outOfOffice: away("2026-09-30", "2026-10-01",
                                             "2026-10-05", "2026-10-06", "2026-10-08", "2026-10-09",
                                             calendar: cal),
                           calendar: cal)

        XCTAssertEqual(result.completedWeeks, 5)
        XCTAssertEqual(result.weeksWithTimeOff, 2)
        XCTAssertEqual(result.outOfOfficeDays, 6)
        XCTAssertEqual(result.effectiveWeeks, 3 + 0.6 + 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600, accuracy: 0.001,
                       "every week ran at 40 hours of working time, so the average is 40")

        // Counting those weeks whole would drag the average down.
        let naive = stats(days, period: .year, now: date(2026, 10, 14, 12, calendar: cal),
                          calendar: cal)
        XCTAssertLessThan(try XCTUnwrap(naive.averageWork), 40 * 3600 - 3600)
    }

    func testWeeksEntirelyOffAreCountedWithoutNeedingARecordAndDoNotMoveTheAverage() throws {
        let cal = calendar()
        let days = [day(2026, 9, 7, hours: 40, calendar: cal)]
        let off = away("2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18",
                       calendar: cal)
        let result = stats(days, now: date(2026, 9, 23, 12, calendar: cal), outOfOffice: off,
                           calendar: cal)
        XCTAssertEqual(result.weeksEntirelyOff, 1)
        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600)
    }

    func testWeeksOffOutsideThePeriodOrStillRunningAreNotCounted() {
        let cal = calendar()
        let off = away("2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04",   // Crosses the month start.
                       "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25",   // Not over yet.
                       calendar: cal)
        let result = stats([day(2026, 9, 9, hours: 40, calendar: cal)],
                           now: date(2026, 9, 23, 12, calendar: cal), outOfOffice: off, calendar: cal)
        XCTAssertEqual(result.weeksEntirelyOff, 0)
        XCTAssertEqual(result.completedWeeks, 1)
    }

    func testWeekAfterATimeOffWeekStartsFromItsOwnWeight() throws {
        let cal = calendar()
        let result = stats([
            day(2026, 9, 7, hours: 16, calendar: cal),   // Two of five days worked.
            day(2026, 9, 14, hours: 40, calendar: cal),
        ], now: date(2026, 9, 23, 12, calendar: cal),
        outOfOffice: away("2026-09-09", "2026-09-10", "2026-09-11", calendar: cal), calendar: cal)

        XCTAssertEqual(result.weeksWithTimeOff, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 56.0 / 1.4 * 3600, accuracy: 0.001)
    }
}
