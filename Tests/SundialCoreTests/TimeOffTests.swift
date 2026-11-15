import XCTest
@testable import SundialCore

/// Work on a day off is a bonus: it can lift an average, and a day off with no
/// work on it can never pull one down.
final class TimeOffTests: XCTestCase {
    private var cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func day(_ month: Int, _ day: Int, hours: Double) -> DayStats {
        let start = date(month, day)
        var totals = Totals()
        totals.byState[.work] = hours * 3600
        return DayStats(day: Format.day(start, calendar: cal), date: start,
                        totals: totals, workByHour: Array(repeating: 0, count: 24),
                        personalByHour: Array(repeating: 0, count: 24),
                        firstActivity: nil, lastActivity: nil, longestFocus: 0,
                        focusBlocks: 0, contextSwitches: 0, callSeconds: 0,
                        isWeekend: TimeOff.isWeekend(start, calendar: cal))
    }

    /// Monday 7 September to Friday 11 September 2026, eight hours a day.
    private func fullWeek(friday: Double = 8) -> [DayStats] {
        [day(9, 7, hours: 8), day(9, 8, hours: 8), day(9, 9, hours: 8),
         day(9, 10, hours: 8), day(9, 11, hours: friday)]
    }

    private func weekly(_ days: [DayStats], off: Set<String>) -> WeeklyWorkStats {
        RangeStats(days: days, contexts: [], timeOff: off)
            .weeklyWorkStats(period: .month, now: date(9, 23, 12), calendar: cal)
    }

    // MARK: - Weekly

    func testADayOffWithoutWorkDoesNotLowerTheWeek() throws {
        let result = weekly(fullWeek(friday: 0), off: ["2026-09-11"])
        XCTAssertEqual(result.completedWeeks, 1)
        XCTAssertEqual(result.timeOffDays, 1)
        XCTAssertEqual(result.weeksWorked, 0.8, accuracy: 1e-9)
        // 32 hours in four days is a 40-hour pace.
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600, accuracy: 1e-6)
    }

    func testWorkOnADayOffLiftsTheWeek() throws {
        let result = weekly(fullWeek(friday: 2), off: ["2026-09-11"])
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 34 * 3600 / 0.8, accuracy: 1e-6)
    }

    func testADayOffWithNoRecordStillShortensItsWeek() throws {
        let days = Array(fullWeek().prefix(4))
        let result = weekly(days, off: ["2026-09-11"])
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600, accuracy: 1e-6)
    }

    func testAWholeWeekOffAddsItsWorkWithoutAddingAWeek() throws {
        let off: Set<String> = ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18"]
        let result = weekly(fullWeek() + [day(9, 15, hours: 3)], off: off)
        XCTAssertEqual(result.completedWeeks, 2)
        XCTAssertEqual(result.weeksWorked, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 43 * 3600, accuracy: 1e-6)
    }

    func testOnlyWeeksOffLeavesNoAverage() {
        let off = Set(TimeOff.weekdays(from: date(9, 7), through: date(9, 11), calendar: cal))
        XCTAssertNil(weekly([day(9, 8, hours: 1)], off: off).averageWork)
    }

    func testWeekendDaysOffAreIgnoredByTheWeek() throws {
        let result = weekly(fullWeek(), off: ["2026-09-12", "2026-09-13"])
        XCTAssertEqual(result.timeOffDays, 0)
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 40 * 3600, accuracy: 1e-6)
    }

    func testNoTimeOffMatchesThePlainAverage() throws {
        let result = weekly(fullWeek(friday: 0), off: [])
        XCTAssertEqual(try XCTUnwrap(result.averageWork), 32 * 3600, accuracy: 1e-6)
    }

    // MARK: - Daily

    func testDailyAverageLeavesDaysOffOutButKeepsTheirWork() {
        let s = RangeStats(days: [day(9, 7, hours: 8), day(9, 8, hours: 8), day(9, 9, hours: 2)],
                           contexts: [], timeOff: ["2026-09-09"])
        XCTAssertEqual(s.countedDays.map(\.day), ["2026-09-07", "2026-09-08"])
        XCTAssertEqual(s.averageWorkPerActiveDay, 9 * 3600, accuracy: 1e-6)
        XCTAssertEqual(s.timeOffWork, 2 * 3600, accuracy: 1e-6)
        XCTAssertEqual(s.totalWork, 18 * 3600, accuracy: 1e-6)
    }

    func testAnIdleDayOffChangesNothing() {
        let plain = RangeStats(days: [day(9, 7, hours: 8), day(9, 8, hours: 6)], contexts: [])
        let withOff = RangeStats(days: [day(9, 7, hours: 8), day(9, 8, hours: 6), day(9, 9, hours: 0)],
                                 contexts: [], timeOff: ["2026-09-09"])
        XCTAssertEqual(withOff.averageWorkPerActiveDay, plain.averageWorkPerActiveDay, accuracy: 1e-6)
    }

    func testOnlyDaysOffLeavesNoDailyAverage() {
        let s = RangeStats(days: [day(9, 9, hours: 2)], contexts: [], timeOff: ["2026-09-09"])
        XCTAssertTrue(s.countedDays.isEmpty)
        XCTAssertEqual(s.averageWorkPerActiveDay, 0)
    }

    // MARK: - Days and runs

    func testWeekdaysSkipWeekendsAndAcceptEitherOrder() {
        let expected = ["2026-09-10", "2026-09-11", "2026-09-14"]
        XCTAssertEqual(TimeOff.weekdays(from: date(9, 10), through: date(9, 14), calendar: cal), expected)
        XCTAssertEqual(TimeOff.weekdays(from: date(9, 14, 15), through: date(9, 10), calendar: cal), expected)
        XCTAssertEqual(TimeOff.weekdays(from: date(9, 12), through: date(9, 13), calendar: cal), [])
    }

    func testRunsJoinAcrossWeekends() {
        let runs = TimeOff.runs(["2026-09-10", "2026-09-11", "2026-09-14", "2026-09-16"], calendar: cal)
        XCTAssertEqual(runs.map(\.first), ["2026-09-10", "2026-09-16"])
        XCTAssertEqual(runs.map(\.last), ["2026-09-14", "2026-09-16"])
        XCTAssertEqual(runs.map(\.count), [3, 1])
    }

    func testStoreRoundTripsDaysOff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sundial-timeoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        XCTAssertEqual(store.loadTimeOff(), [])
        store.save(timeOff: ["2026-09-11", "2026-09-10"])
        XCTAssertEqual(store.loadTimeOff(), ["2026-09-10", "2026-09-11"])
        store.save(timeOff: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.timeOffURL.path))
    }
}
