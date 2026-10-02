import XCTest
@testable import SundialCore

final class AnalyticsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-09-01 at the given local hour/minute.
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 1,
                                      hour: hour, minute: minute))!
    }

    func seg(_ a: Date, _ b: Date, _ state: TimeCategory = .work, key: String = "k") -> Segment {
        Segment(start: a, end: b, state: state,
                snapshot: Snapshot(bundleId: key, appName: key), reason: "")
    }

    // MARK: hour splitting

    func testSpanWithinOneHourStaysThere() {
        let parts = Analytics.splitByHour(start: at(10, 5), end: at(10, 35), calendar: cal)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].hour, 10)
        XCTAssertEqual(parts[0].seconds, 1800, accuracy: 1)
    }

    func testSpanIsDividedAcrossTheHoursItCovers() {
        let parts = Analytics.splitByHour(start: at(10, 45), end: at(12, 30), calendar: cal)
        XCTAssertEqual(parts.map(\.hour), [10, 11, 12])
        XCTAssertEqual(parts[0].seconds, 900, accuracy: 1)
        XCTAssertEqual(parts[1].seconds, 3600, accuracy: 1)
        XCTAssertEqual(parts[2].seconds, 1800, accuracy: 1)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.seconds }, 6300, accuracy: 1)
    }

    func testSpanEndingExactlyOnTheHour() {
        let parts = Analytics.splitByHour(start: at(9, 30), end: at(10, 0), calendar: cal)
        XCTAssertEqual(parts.map(\.hour), [9])
        XCTAssertEqual(parts[0].seconds, 1800, accuracy: 1)
    }

    func testEmptyAndInvertedSpansProduceNothing() {
        XCTAssertTrue(Analytics.splitByHour(start: at(10), end: at(10), calendar: cal).isEmpty)
        XCTAssertTrue(Analytics.splitByHour(start: at(11), end: at(10), calendar: cal).isEmpty)
    }

    func testSpanCrossingMidnightWrapsToHourZero() {
        let parts = Analytics.splitByHour(start: at(23, 30), end: at(23, 30).addingTimeInterval(3600),
                                          calendar: cal)
        XCTAssertEqual(parts.map(\.hour), [23, 0])
    }

    func testBucketsOnlyCountTheRequestedState() {
        let segs = [seg(at(9), at(10)), seg(at(10), at(11), .personal), seg(at(11), at(12))]
        let work = Analytics.hourBuckets(segs, state: .work, calendar: cal)
        XCTAssertEqual(work[9], 3600, accuracy: 1)
        XCTAssertEqual(work[10], 0)
        XCTAssertEqual(work[11], 3600, accuracy: 1)
        XCTAssertEqual(Analytics.hourBuckets(segs, state: .personal, calendar: cal)[10],
                       3600, accuracy: 1)
    }

    /// Buckets are filled from hour edges computed once per range; they must
    /// match splitting every segment on its own, including across a DST change.
    func testBucketsMatchPerSegmentSplittingAcrossDaylightSaving() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dayStart = la.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        var rng = SystemRandomNumberGenerator()
        var segs: [Segment] = []
        var t = dayStart
        while t < dayStart.addingTimeInterval(25 * 3600) {
            let end = t.addingTimeInterval(Double.random(in: 1...5400, using: &rng))
            segs.append(seg(t, end, Bool.random(using: &rng) ? .work : .personal))
            t = end.addingTimeInterval(Double.random(in: 0...600, using: &rng))
        }
        for state in [TimeCategory.work, .personal] {
            var expected = [TimeInterval](repeating: 0, count: 24)
            for s in segs where s.state == state {
                for p in Analytics.splitByHour(start: s.start, end: s.end, calendar: la) {
                    expected[p.hour] += p.seconds
                }
            }
            let got = Analytics.hourBuckets(segs, state: state, calendar: la)
            for h in 0..<24 { XCTAssertEqual(got[h], expected[h], accuracy: 1e-6, "hour \(h)") }
        }
    }

    func testBucketsForSegmentsSpreadOverDaysStillAddUp() {
        let segs = [seg(at(9), at(10)), seg(at(9).addingTimeInterval(3 * 86400),
                                            at(9).addingTimeInterval(3 * 86400 + 1800))]
        let work = Analytics.hourBuckets(segs, state: .work, calendar: cal)
        XCTAssertEqual(work[9], 5400, accuracy: 1)
        XCTAssertEqual(work.reduce(0, +), 5400, accuracy: 1)
    }

    func testBucketsAlwaysCoverTwentyFourHours() {
        XCTAssertEqual(Analytics.hourBuckets([], state: .work, calendar: cal).count, 24)
    }

    // MARK: day stats

    func dayOfWork() -> DayStats {
        let segs = [
            seg(at(9), at(10, 30)),                       // 90m work
            seg(at(10, 30), at(10, 45), .away),           // break
            seg(at(10, 45), at(12), key: "other"),        // 75m work, different context
            seg(at(12), at(13), .personal),               // lunch
            seg(at(13), at(14), key: "k"),                // 60m work
        ]
        return DayStats.compute(day: "2026-09-01", segments: segs,
                                presence: PresenceLog(call: [Span(at(11), at(11, 30))]),
                                calendar: cal)
    }

    func testDayTotalsAndHourBreakdown() {
        let d = dayOfWork()
        XCTAssertEqual(d.totals.work, 225 * 60, accuracy: 1)
        XCTAssertEqual(d.workByHour[9], 3600, accuracy: 1)
        XCTAssertEqual(d.workByHour[10], 2700, accuracy: 1,
                       "30 min before the break plus 15 after it")
        XCTAssertEqual(d.workByHour[12], 0, "lunch is personal, not work")
        XCTAssertEqual(d.workByHour[13], 3600, accuracy: 1)
        XCTAssertEqual(d.workByHour.reduce(0, +), d.totals.work, accuracy: 1,
                       "hour buckets must account for exactly the day's work")
    }

    func testDayEdgesAndDensity() {
        let d = dayOfWork()
        XCTAssertEqual(d.firstActivity, at(9))
        XCTAssertEqual(d.lastActivity, at(14))
        XCTAssertEqual(d.span, 5 * 3600, accuracy: 1)
        XCTAssertEqual(d.density, (225 * 60) / (5 * 3600), accuracy: 0.001)
    }

    func testCallTimeComesFromPresence() {
        XCTAssertEqual(dayOfWork().callSeconds, 1800, accuracy: 1)
    }

    func testContextSwitchesCountChangesOfSubject() {
        XCTAssertEqual(dayOfWork().contextSwitches, 2, "k -> other -> k")
    }

    /// A short interruption should not end a focus block; a real break should.
    func testFocusBlocksToleratePausesButNotBreaks() {
        let segs = [
            seg(at(9), at(10)),
            seg(at(10), at(10, 1), .personal),   // 60s glance
            seg(at(10, 1), at(11)),
            seg(at(11), at(11, 30), .away),      // real break
            seg(at(11, 30), at(12)),
        ]
        let (longest, count) = DayStats.focusRuns(segs, tolerance: 120)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(longest, 7140, accuracy: 1,
                       "the brief pause preserves the block but contributes no focus time")
    }

    func testWeekendDetection() {
        // 2026-09-05 is a Saturday.
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let sat = c.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 10))!
        let d = DayStats.compute(day: "2026-09-05",
                                 segments: [seg(sat, sat.addingTimeInterval(3600))],
                                 presence: PresenceLog(), calendar: c)
        XCTAssertTrue(d.isWeekend)
    }

    // MARK: range stats

    func range() -> RangeStats {
        var days: [DayStats] = []
        for offset in 0..<5 {
            let base = cal.date(byAdding: .day, value: offset, to: at(0))!
            func t(_ h: Int) -> Date { cal.date(byAdding: .hour, value: h, to: base)! }
            let segs = [seg(t(9), t(12)), seg(t(13), t(offset == 4 ? 22 : 17))]
            days.append(DayStats.compute(day: Format.day(base), segments: segs,
                                         presence: PresenceLog(), calendar: cal))
        }
        return RangeStats.compute(days: days, contexts: [])
    }

    func testRangeAveragesOverActiveDaysOnly() {
        var r = range()
        r.days.append(DayStats.compute(day: "2026-09-20", segments: [],
                                       presence: PresenceLog(), calendar: cal))
        XCTAssertEqual(r.activeDays.count, 5, "an empty day is not a slow day")
        XCTAssertEqual(r.averageWorkPerActiveDay, r.totalWork / 5, accuracy: 1)
    }

    func testBusiestHourAndCoreHours() {
        let r = range()
        XCTAssertNotNil(r.busiestHour)
        let core = try? XCTUnwrap(r.coreHours)
        XCTAssertNotNil(core)
        XCTAssertTrue(core!.contains(10), "mid-morning is inside the core window")
        XCTAssertFalse(core!.contains(3), "the small hours are not")
    }

    func testWorkOutsideCoreHoursIsMeasured() {
        let r = range()
        let evening = r.workOutside(9...17)
        XCTAssertGreaterThan(evening, 3600, "one day ran to 22:00")
    }

    func testRangeHourBucketsSumToTotalWork() {
        let r = range()
        XCTAssertEqual(r.workByHour.reduce(0, +), r.totalWork, accuracy: 1)
    }

    func testEmptyRangeIsSafe() {
        let r = RangeStats.compute(days: [], contexts: [])
        XCTAssertEqual(r.totalWork, 0)
        XCTAssertEqual(r.averageWorkPerActiveDay, 0)
        XCTAssertNil(r.busiestHour)
        XCTAssertNil(r.coreHours)
        XCTAssertEqual(r.averageSwitchesPerWorkHour, 0)
    }

    func testContextRollupRanksBiggestFirst() {
        let a = [seg(at(9), at(11), key: "alpha")]
        let b = [seg(at(9), at(9, 30), key: "beta"), seg(at(10), at(10, 15), key: "alpha")]
        let contexts = RangeStats.contexts(from: [a, b])
        XCTAssertEqual(contexts.first?.key, "app:alpha")
        XCTAssertEqual(contexts.first?.seconds ?? 0, 8100, accuracy: 1)
        XCTAssertEqual(contexts.count, 2)
    }

    func testContextRollupIgnoresNonWork() {
        XCTAssertTrue(RangeStats.contexts(from: [[seg(at(9), at(10), .personal)]]).isEmpty)
    }
}

final class StoreStatsTests: XCTestCase {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    private var root: URL!
    private var store: Store!

    override func setUp() {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = Store(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ day: Int, _ hour: Int = 12, month: Int = 9,
                    calendar: Calendar? = nil) -> Date {
        (calendar ?? cal).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// Write a day by its explicit calendar key, independent of the host timezone.
    private func save(_ data: DayData) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try data.observations.map { try encoder.encode($0) }
        var encoded = Data()
        for line in lines { encoded.append(line); encoded.append(0x0A) }
        try encoded.write(to: store.observationsURL(data.day))
        store.savePresence(data.presence, day: data.day)
        store.saveManual(data.manual, day: data.day)
    }

    private func recordedDay(_ day: Int, start: Int = 10, end: Int = 11) -> DayData {
        DayData(day: Format.day(at(day), calendar: cal), observations: [
            ObservationSpan(start: at(day, start), end: at(day, end),
                snapshot: Snapshot(bundleId: "b", appName: "Zen",
                                   url: "https://acme.com/", host: "acme.com", urlPath: "/"))
        ], presence: PresenceLog(input: [Span(at(day, start), at(day, end))]))
    }

    private var rules: RuleSet {
        RuleSet(rules: [Rule(name: "acme",
            conditions: [Condition(.host, .hostOrSubdomain, "acme.com")], outcome: .work)])
    }

    func testStatsClassifyHistoryUnderCurrentRules() throws {
        for day in 7...9 { try save(recordedDay(day)) }
        let before = store.stats(rules: RuleSet(), settings: .default, calendar: cal, now: at(9))
        XCTAssertEqual(before.days.count, 3)
        XCTAssertEqual(before.totalWork, 0, accuracy: 1)
        XCTAssertEqual(before.totalUnclassified, 3 * 3600, accuracy: 1)

        let after = store.stats(rules: rules, settings: .default, calendar: cal, now: at(9))
        XCTAssertEqual(after.totalWork, 3 * 3600, accuracy: 1)
        XCTAssertEqual(after.busiestHour, 10)
        XCTAssertEqual(after.contexts.first?.detail, "acme.com")
    }

    func testDefaultWeekExcludesPreviousWeekAndFutureDays() throws {
        for day in [6, 7, 9, 10] { try save(recordedDay(day)) }
        let stats = store.stats(rules: rules, settings: .default, calendar: cal, now: at(9))
        XCTAssertEqual(stats.days.map(\.day), ["2026-09-07", "2026-09-09"])
        XCTAssertEqual(stats.totalWork, 2 * 3600, accuracy: 1)
        XCTAssertEqual(stats.averageWorkPerActiveDay, 3600, accuracy: 1)
        XCTAssertEqual(stats.completedActiveDays.map(\.day), ["2026-09-07"])
    }

    func testCalendarMonthIncludesEarlierDaysOfThisMonthOnly() throws {
        for date in [at(31, month: 8), at(1), at(9), at(10)] {
            store.saveManual([ManualEntry(start: date, end: date + 3600)],
                             day: Format.day(date, calendar: cal))
        }
        let stats = store.stats(period: .month, rules: rules, settings: .default,
                                calendar: cal, now: at(9, 14))
        XCTAssertEqual(stats.days.map(\.day), ["2026-09-01", "2026-09-09"])
        XCTAssertEqual(stats.totalWork, 2 * 3600, accuracy: 1)
    }

    func testAllPeriodsSelectTheirOwnCalendarStart() {
        for (month, day) in [(12, 31), (1, 1), (6, 30), (7, 1), (8, 31), (9, 1), (9, 7)] {
            let year = month == 12 ? 2025 : 2026
            let date = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
            store.saveManual([ManualEntry(start: date, end: date + 3600)],
                             day: Format.day(date, calendar: cal))
        }
        for (period, expectedHours) in [(StatsPeriod.week, 1.0), (.month, 2.0),
                                         (.quarter, 4.0), (.year, 6.0)] {
            let stats = store.stats(period: period, rules: rules, settings: .default,
                                    calendar: cal, now: at(9))
            XCTAssertEqual(stats.totalWork, expectedHours * 3600, accuracy: 1,
                           "Unexpected total for \(period)")
        }
    }

    func testSegmentsAndCallsUseTheSameElapsedCalendarPeriod() throws {
        let start = at(7, 0)
        let now = at(9, 12)
        let first = DayData(day: "2026-09-07", observations: [
            ObservationSpan(start: start - 3600, end: start + 3600,
                            snapshot: recordedDay(7).observations[0].snapshot)
        ], presence: PresenceLog(input: [Span(start - 3600, start + 3600)],
                                 call: [Span(start - 3600, start + 3600)]))
        var today = recordedDay(9, start: 11, end: 13)
        today.presence.call = [Span(at(9, 11), at(9, 13))]
        try save(first)
        try save(today)

        let stats = store.stats(rules: rules, settings: .default, calendar: cal, now: now)
        XCTAssertEqual(stats.totalWork, 2 * 3600, accuracy: 1)
        XCTAssertEqual(stats.totalCallSeconds, 2 * 3600, accuracy: 1)
        XCTAssertEqual(stats.contexts.reduce(0) { $0 + $1.seconds }, stats.totalWork, accuracy: 1)
        XCTAssertEqual(stats.workByHour.reduce(0, +), stats.totalWork, accuracy: 1)
        XCTAssertEqual(stats.workByHour[0], 3600, accuracy: 1)
        XCTAssertEqual(stats.workByHour[11], 3600, accuracy: 1)
        XCTAssertEqual(stats.workByHour[12], 0)
        XCTAssertEqual(stats.days.first?.firstActivity, start)
        XCTAssertEqual(stats.days.last?.lastActivity, now)
    }

    func testFutureManualTimeCannotContributeToAnyTotals() {
        store.saveManual([ManualEntry(start: at(9, 11), end: at(9, 13)),
                          ManualEntry(start: at(9, 14), end: at(9, 15), category: .personal)],
                         day: "2026-09-09")
        let stats = store.stats(rules: rules, settings: .default, calendar: cal, now: at(9, 12))
        XCTAssertEqual(stats.totalWork, 3600, accuracy: 1)
        XCTAssertEqual(stats.totalPersonal, 0)
        XCTAssertEqual(stats.longestFocus, 0, "manual time cannot establish observed focus")
    }

    func testLiveDayReplacesSavedDayWithoutDoubleCounting() throws {
        try save(recordedDay(8))
        try save(recordedDay(9))
        let live = recordedDay(9, start: 10, end: 12)
        let stats = store.stats(rules: rules, settings: .default, calendar: cal,
                                now: at(9), currentDay: live)
        XCTAssertEqual(stats.days.map(\.day), ["2026-09-08", "2026-09-09"])
        XCTAssertEqual(stats.totalWork, 3 * 3600, accuracy: 1)
        XCTAssertEqual(stats.averageWorkPerActiveDay, 3600, accuracy: 1)
    }

    func testLiveDayAppearsBeforeItHasBeenSaved() {
        XCTAssertTrue(store.availableDays().isEmpty)
        let stats = store.stats(rules: rules, settings: .default, calendar: cal,
                                now: at(9), currentDay: recordedDay(9))
        XCTAssertEqual(stats.days.map(\.day), ["2026-09-09"])
        XCTAssertEqual(stats.totalWork, 3600, accuracy: 1)
        XCTAssertTrue(stats.completedActiveDays.isEmpty)
        XCTAssertEqual(stats.averageWorkPerActiveDay, 0)
    }

    func testEmptyLiveDayReplacesStaleSavedDay() throws {
        try save(recordedDay(9))
        let stats = store.stats(rules: rules, settings: .default, calendar: cal,
                                now: at(9), currentDay: DayData(day: "2026-09-09"))
        XCTAssertTrue(stats.days.isEmpty)
        XCTAssertEqual(stats.totalWork, 0)
    }

    func testTodayAndCompletedDayAverageUseTheSuppliedTimezone() {
        var local = cal
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = at(8, 23, calendar: local) + 30 * 60 // Already September 9 in UTC.
        for (day, hours) in [(7, 2.0), (8, 1.0)] {
            let start = at(day, 10, calendar: local)
            store.saveManual([ManualEntry(start: start, end: start + hours * 3600)],
                             day: Format.day(start, calendar: local))
        }
        let stats = store.stats(rules: rules, settings: .default, calendar: local, now: now)
        XCTAssertEqual(stats.today, "2026-09-08")
        XCTAssertEqual(stats.completedActiveDays.map(\.day), ["2026-09-07"])
        XCTAssertEqual(stats.averageWorkPerActiveDay, 2 * 3600, accuracy: 1)
        XCTAssertEqual(stats.totalWork, 3 * 3600, accuracy: 1)
    }
}

/// A partial day must not be averaged in with finished ones.
extension AnalyticsTests {
    func statsWithToday() -> RangeStats {
        var days: [DayStats] = []
        for (i, hours) in [8.0, 8.0, 1.0].enumerated() {
            let base = cal.date(byAdding: .day, value: i, to: at(0))!
            let segs = [seg(base.addingTimeInterval(9 * 3600),
                            base.addingTimeInterval((9 + hours) * 3600))]
            days.append(DayStats.compute(day: Format.day(base), segments: segs,
                                         presence: PresenceLog(), calendar: cal))
        }
        return RangeStats.compute(days: days, contexts: [], today: days.last!.day)
    }

    func testAverageExcludesTheDayInProgress() {
        let s = statsWithToday()
        XCTAssertEqual(s.completedActiveDays.count, 2)
        XCTAssertEqual(s.averageWorkPerActiveDay, 8 * 3600, accuracy: 1,
                       "the 1-hour partial day must not drag the average down")
        XCTAssertEqual(s.totalWork, 17 * 3600, accuracy: 1,
                       "the total still counts every hour worked")
    }

    func testAverageIsZeroWhenOnlyTodayHasBeenRecorded() {
        let base = at(0)
        let only = DayStats.compute(day: Format.day(base),
                                    segments: [seg(base.addingTimeInterval(3600),
                                                   base.addingTimeInterval(7200))],
                                    presence: PresenceLog(), calendar: cal)
        let s = RangeStats.compute(days: [only], contexts: [], today: only.day)
        XCTAssertTrue(s.completedActiveDays.isEmpty)
        XCTAssertEqual(s.averageWorkPerActiveDay, 0, "reported as unknown, not as a small number")
        XCTAssertGreaterThan(s.totalWork, 0)
    }

    func testWithoutATodayEveryActiveDayCounts() {
        var s = statsWithToday()
        s.today = nil
        XCTAssertEqual(s.completedActiveDays.count, 3)
    }
}
