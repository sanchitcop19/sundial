import XCTest
@testable import SundialCore

final class StatsPeriodTests: XCTestCase {
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

    func testDefaultCalendarStartsWeeksOnMonday() {
        XCTAssertEqual(StatsPeriod.calendar.firstWeekday, 2)
        XCTAssertEqual(StatsPeriod.calendar.timeZone, Calendar.current.timeZone)
    }

    func testEachPeriodContainsFullCalendarBoundaries() {
        let cal = calendar()
        let now = date(2026, 9, 9, 14, calendar: cal)
        for (period, start, end) in [
            (StatsPeriod.week, date(2026, 9, 7, calendar: cal), date(2026, 9, 14, calendar: cal)),
            (.month, date(2026, 9, 1, calendar: cal), date(2026, 10, 1, calendar: cal)),
            (.quarter, date(2026, 7, 1, calendar: cal), date(2026, 10, 1, calendar: cal)),
            (.year, date(2026, 1, 1, calendar: cal), date(2027, 1, 1, calendar: cal))
        ] {
            XCTAssertEqual(period.interval(containing: now, calendar: cal),
                           DateInterval(start: start, end: end), "Unexpected boundaries for \(period)")
            XCTAssertEqual(period.interval(containing: end, calendar: cal).start, end,
                           "The exact boundary belongs to the next \(period)")
        }
    }

    func testAWeekCanCrossIntoTheNextYear() {
        let cal = calendar()
        let expected = DateInterval(start: date(2026, 12, 28, calendar: cal),
                                    end: date(2027, 1, 4, calendar: cal))
        XCTAssertEqual(StatsPeriod.week.interval(containing: date(2026, 12, 31, calendar: cal),
                                                 calendar: cal), expected)
        XCTAssertEqual(StatsPeriod.week.interval(containing: date(2027, 1, 1, calendar: cal),
                                                 calendar: cal), expected)
    }

    func testQuarterUsesJanuaryAprilJulyAndOctoberBoundaries() {
        let cal = calendar()
        for month in 1...12 {
            let startMonth = ((month - 1) / 3) * 3 + 1
            let start = date(2026, startMonth, 1, calendar: cal)
            let end = cal.date(byAdding: .month, value: 3, to: start)!
            XCTAssertEqual(StatsPeriod.quarter.interval(
                containing: date(2026, month, 15, calendar: cal), calendar: cal),
                DateInterval(start: start, end: end))
        }
    }

    func testLeapFebruaryUsesItsCalendarMonth() {
        let cal = calendar()
        let interval = StatsPeriod.month.interval(containing: date(2028, 2, 29, calendar: cal),
                                                 calendar: cal)
        XCTAssertEqual(interval.start, date(2028, 2, 1, calendar: cal))
        XCTAssertEqual(interval.end, date(2028, 3, 1, calendar: cal))
        XCTAssertEqual(interval.duration, 29 * 24 * 3600)
    }

    func testInjectedCalendarCanStartWeeksOnSunday() {
        let cal = calendar(firstWeekday: 1)
        let interval = StatsPeriod.week.interval(containing: date(2026, 9, 9, calendar: cal),
                                                calendar: cal)
        XCTAssertEqual(interval.start, date(2026, 9, 6, calendar: cal))
        XCTAssertEqual(interval.end, date(2026, 9, 13, calendar: cal))
    }

    func testLocalWeekBoundariesFollowDaylightSavingChanges() {
        let cal = calendar("America/Los_Angeles")
        let spring = StatsPeriod.week.interval(containing: date(2026, 3, 8, 12, calendar: cal),
                                              calendar: cal)
        XCTAssertEqual(spring.start, date(2026, 3, 2, calendar: cal))
        XCTAssertEqual(spring.end, date(2026, 3, 9, calendar: cal))
        XCTAssertEqual(spring.duration, 167 * 3600)

        let autumn = StatsPeriod.week.interval(containing: date(2026, 11, 1, 12, calendar: cal),
                                              calendar: cal)
        XCTAssertEqual(autumn.start, date(2026, 10, 26, calendar: cal))
        XCTAssertEqual(autumn.end, date(2026, 11, 2, calendar: cal))
        XCTAssertEqual(autumn.duration, 169 * 3600)
    }
}
