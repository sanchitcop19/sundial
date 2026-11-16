import XCTest
@testable import SundialCore

final class OutOfOfficeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, month: Int = 9, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func away(_ days: String...) -> OutOfOffice { OutOfOffice(days: Set(days)) }

    // MARK: marking days

    func testAddMarksEveryDayInclusiveAndIsIdempotent() {
        var days = OutOfOffice()
        XCTAssertEqual(days.add(from: date(14, hour: 18), through: date(16, hour: 6), calendar: calendar), 3)
        XCTAssertEqual(days.days, ["2026-09-14", "2026-09-15", "2026-09-16"])
        XCTAssertEqual(days.add(from: date(15), through: date(17), calendar: calendar), 1,
                       "only the new day is counted")
        XCTAssertTrue(days.contains("2026-09-17"))
        XCTAssertTrue(days.contains(date(17, hour: 23), calendar: calendar))
        XCTAssertFalse(days.contains(date(18), calendar: calendar))
    }

    func testRangeGivenBackwardsStillMarksTheSameDays() {
        var days = OutOfOffice()
        days.add(from: date(16), through: date(14), calendar: calendar)
        XCTAssertEqual(days.days, ["2026-09-14", "2026-09-15", "2026-09-16"])
    }

    func testRangeAcrossDaylightSavingChangeHasNoGapsOrRepeats() {
        var days = OutOfOffice()
        // US clocks went back on 2026-11-01.
        days.add(from: date(30, month: 10), through: date(2, month: 11), calendar: calendar)
        XCTAssertEqual(days.days, ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
    }

    func testRangeIsCappedSoATypoCannotFillTheFile() {
        var days = OutOfOffice()
        days.add(from: date(1, month: 1, year: 2026), through: date(1, month: 1, year: 2030),
                 calendar: calendar)
        XCTAssertEqual(days.days.count, OutOfOffice.maxRangeDays)
    }

    func testRemoveByRangeAndByDays() {
        var days = away("2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17")
        XCTAssertEqual(days.remove(from: date(15), through: date(16), calendar: calendar), 2)
        XCTAssertEqual(days.days, ["2026-09-14", "2026-09-17"])
        XCTAssertEqual(days.remove(days: ["2026-09-14", "2026-12-25"]), 1)
        XCTAssertEqual(days.days, ["2026-09-17"])
        XCTAssertFalse(days.isEmpty)
    }

    // MARK: grouping

    func testRunsJoinConsecutiveDaysAcrossMonthsAndSplitOnGaps() {
        let days = away("2026-09-29", "2026-09-30", "2026-10-01", "2026-10-05", "2026-10-07",
                        "2026-10-08")
        let runs = days.runs(calendar: calendar)
        XCTAssertEqual(runs.map(\.first), ["2026-09-29", "2026-10-05", "2026-10-07"])
        XCTAssertEqual(runs.map(\.last), ["2026-10-01", "2026-10-05", "2026-10-08"])
        XCTAssertEqual(runs.map(\.count), [3, 1, 2])
        XCTAssertEqual(runs[0].days, ["2026-09-29", "2026-09-30", "2026-10-01"])
        XCTAssertTrue(OutOfOffice().runs(calendar: calendar).isEmpty)
    }

    func testRunsAreContinuousAcrossDaylightSavingChange() {
        let runs = away("2026-10-31", "2026-11-01", "2026-11-02").runs(calendar: calendar)
        XCTAssertEqual(runs.count, 1)
    }

    func testDateOfRejectsMalformedAndImpossibleDays() {
        XCTAssertEqual(OutOfOffice.date(of: "2026-09-14", calendar: calendar), date(14, hour: 0))
        XCTAssertNil(OutOfOffice.date(of: "2026-02-30", calendar: calendar))
        XCTAssertNil(OutOfOffice.date(of: "2026-9-14", calendar: calendar))
        XCTAssertNil(OutOfOffice.date(of: "yesterday", calendar: calendar))
    }

    // MARK: persistence

    func testEncodesSortedAndRoundTripsThroughTheStore() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        XCTAssertTrue(store.loadOutOfOffice().isEmpty, "nothing saved yet")

        let saved = away("2026-09-16", "2026-09-14")
        store.save(saved)
        XCTAssertEqual(store.loadOutOfOffice(), saved)
        let text = try String(contentsOf: store.outOfOfficeURL, encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "2026-09-14")).lowerBound,
                          try XCTUnwrap(text.range(of: "2026-09-16")).lowerBound)
    }

    func testUnreadableOrHandEditedFilesDegradeGracefully() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)

        try Data("not json".utf8).write(to: store.outOfOfficeURL)
        XCTAssertTrue(store.loadOutOfOffice().isEmpty)

        try Data(#"{"days":["2026-09-14","soon","2026-9-1",""]}"#.utf8).write(to: store.outOfOfficeURL)
        XCTAssertEqual(store.loadOutOfOffice().days, ["2026-09-14"])

        try Data("{}".utf8).write(to: store.outOfOfficeURL)
        XCTAssertTrue(store.loadOutOfOffice().isEmpty)

        XCTAssertEqual(OutOfOffice(days: ["bad", "2026-01-02"]).days, ["2026-01-02"])
    }

    // MARK: attendance

    func testAttendanceCountsOnlyPlannedDays() {
        let week = StatsPeriod.week.interval(containing: date(16), calendar: calendar)
        let none = OutOfOffice().attendance(of: week, includeWeekends: false, calendar: calendar)
        XCTAssertEqual(none.planned, 5)
        XCTAssertEqual(none.fraction, 1)

        let days = away("2026-09-16", "2026-09-17", "2026-09-19")
        let weekdays = days.attendance(of: week, includeWeekends: false, calendar: calendar)
        XCTAssertEqual(weekdays.away, 2, "Saturday is not a planned day")
        XCTAssertEqual(weekdays.present, 3)
        XCTAssertEqual(weekdays.fraction, 0.6, accuracy: 1e-9)

        let sevenDays = days.attendance(of: week, includeWeekends: true, calendar: calendar)
        XCTAssertEqual(sevenDays.planned, 7)
        XCTAssertEqual(sevenDays.away, 3)
    }

    func testAttendanceIsZeroWhenEveryPlannedDayIsAway() {
        let week = StatsPeriod.week.interval(containing: date(16), calendar: calendar)
        let all = away("2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18")
        XCTAssertEqual(all.attendance(of: week, includeWeekends: false, calendar: calendar).fraction, 0)
    }

    // MARK: ranges and averages

    private func dayStats(_ day: String, hours: Double) -> DayStats {
        let start = OutOfOffice.date(of: day, calendar: calendar)!
        var totals = Totals()
        totals.byState[.work] = hours * 3600
        return DayStats(day: day, date: start, totals: totals,
                        workByHour: Array(repeating: 0, count: 24),
                        personalByHour: Array(repeating: 0, count: 24),
                        firstActivity: nil, lastActivity: nil, longestFocus: 0,
                        focusBlocks: 0, contextSwitches: 0, callSeconds: 0)
    }

    func testDaysOutOfOfficeAreNotActiveDaysButStillCountInTotals() {
        let stats = RangeStats.compute(
            days: [dayStats("2026-09-14", hours: 8), dayStats("2026-09-15", hours: 0.5),
                   dayStats("2026-09-16", hours: 6)],
            contexts: [], today: "2026-09-17", outOfOffice: away("2026-09-15"))
        XCTAssertEqual(stats.activeDays.map(\.day), ["2026-09-14", "2026-09-16"])
        XCTAssertEqual(stats.completedActiveDays.count, 2)
        XCTAssertEqual(stats.averageWorkPerActiveDay, 7 * 3600, accuracy: 0.001)
        XCTAssertEqual(stats.totalWork, 14.5 * 3600, accuracy: 0.001, "work done is still work")
        XCTAssertTrue(stats.isOutOfOffice(stats.days[1]))
        XCTAssertFalse(stats.isOutOfOffice(stats.days[0]))
    }

    func testAllActiveDaysOutOfOfficeMeansNoAverage() {
        let stats = RangeStats.compute(days: [dayStats("2026-09-14", hours: 4)], contexts: [],
                                       today: "2026-09-17", outOfOffice: away("2026-09-14"))
        XCTAssertTrue(stats.completedActiveDays.isEmpty)
        XCTAssertEqual(stats.averageWorkPerActiveDay, 0)
    }

    func testStatsComparisonNoticesAChangeInDaysOff() {
        let days = [dayStats("2026-09-14", hours: 8)]
        XCTAssertNotEqual(RangeStats.compute(days: days, contexts: []),
                          RangeStats.compute(days: days, contexts: [], outOfOffice: away("2026-09-14")))
    }

    func testStoreStatsReadTheSavedDaysOff() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        for (day, hours) in [(7, 2.0), (8, 4.0), (9, 1.0)] {
            let start = date(day, hour: 10)
            store.saveManual([ManualEntry(start: start, end: start + hours * 3600)],
                             day: Format.day(start, calendar: calendar))
        }
        store.save(away("2026-09-08"))

        let stats = store.stats(rules: RuleSet(), settings: .default, calendar: calendar,
                                now: date(10))
        XCTAssertEqual(stats.days.count, 3)
        XCTAssertEqual(stats.totalWork, 7 * 3600, accuracy: 1)
        XCTAssertEqual(stats.completedActiveDays.map(\.day), ["2026-09-07", "2026-09-09"])
        XCTAssertEqual(stats.averageWorkPerActiveDay, 1.5 * 3600, accuracy: 1)
    }

    func testBackupCopiesTheDaysOff() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("data")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = Store(root: root)
        store.save(away("2026-09-14"))
        let target = home.appendingPathComponent("Backups").path
        let result = store.mirror(to: [target], includeObservations: false, day: "2026-09-14",
                                  home: home)
        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Backups/out-of-office.json").path))
    }
}
