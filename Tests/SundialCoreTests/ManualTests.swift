import XCTest
@testable import SundialCore

final class ManualTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: dayOffset,
                        to: base.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60))!
    }

    private func entry(_ from: Date, _ to: Date, _ c: TimeCategory = .work) -> ManualEntry {
        ManualEntry(start: from, end: to, category: c)
    }

    private func segment(_ from: Date, _ to: Date, _ c: TimeCategory = .work) -> Segment {
        Segment(start: from, end: to, state: c, reason: "observed")
    }

    // MARK: - What may be added

    func testAGoodEntryHasNoProblem() {
        XCTAssertNil(Manual.problem(with: entry(at(9), at(11)), existing: [], now: at(23)))
    }

    func testRejectsBackwardsAndEmptyEntries() {
        XCTAssertNotNil(Manual.problem(with: entry(at(11), at(9)), existing: [], now: at(23)))
        XCTAssertNotNil(Manual.problem(with: entry(at(9), at(9)), existing: [], now: at(23)))
    }

    func testRejectsTheFuture() {
        let p = Manual.problem(with: entry(at(14), at(15)), existing: [], now: at(10))
        XCTAssertEqual(p, "That is in the future.")
        // A minute's grace, so "the last hour" typed on the hour still works.
        XCTAssertNil(Manual.problem(with: entry(at(9), at(10)), existing: [], now: at(10)))
    }

    func testRejectsMoreThanADay() {
        let long = entry(at(0), at(0, 1, dayOffset: 1))
        XCTAssertNotNil(Manual.problem(with: long, existing: [], now: at(12, 0, dayOffset: 2)))
    }

    func testRejectsUnclassified() {
        XCTAssertNotNil(Manual.problem(with: entry(at(9), at(10), .unclassified),
                                       existing: [], now: at(23)))
    }

    /// Two hand-entered stretches over the same minutes would double count.
    func testRejectsOverlappingAnotherEntry() {
        let existing = [entry(at(9), at(11))]
        XCTAssertNotNil(Manual.problem(with: entry(at(10), at(12)), existing: existing, now: at(23)))
        XCTAssertNotNil(Manual.problem(with: entry(at(8), at(23)), existing: existing, now: at(23)))
        // Touching end to end is not overlapping.
        XCTAssertNil(Manual.problem(with: entry(at(11), at(12)), existing: existing, now: at(23)))
        XCTAssertNil(Manual.problem(with: entry(at(8), at(9)), existing: existing, now: at(23)))
    }

    /// Editing an entry must not collide with the version of itself on disk.
    func testAnEntryDoesNotOverlapItself() {
        let e = entry(at(9), at(11))
        XCTAssertNil(Manual.problem(with: e, existing: [e], now: at(23)))
    }

    // MARK: - Midnight

    func testAnEntryInsideOneDayIsNotSplit() {
        let parts = Manual.split(entry(at(9), at(11)), calendar: cal)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].entry.duration, 2 * 3600)
    }

    func testAnEntryAcrossMidnightIsSplitPerDay() {
        let parts = Manual.split(entry(at(23), at(1, 0, dayOffset: 1)), calendar: cal)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].entry.duration, 3600)
        XCTAssertEqual(parts[1].entry.duration, 3600)
        XCTAssertNotEqual(parts[0].day, parts[1].day)
        XCTAssertEqual(parts[0].entry.end, parts[1].entry.start)
        // Each piece is its own entry, so removing one does not orphan the other.
        XCTAssertNotEqual(parts[0].entry.id, parts[1].entry.id)
    }

    func testSplitKeepsTheWholeDuration() {
        let e = entry(at(22), at(3, 30, dayOffset: 1))
        let total = Manual.split(e, calendar: cal).reduce(0) { $0 + $1.entry.duration }
        XCTAssertEqual(total, e.duration, accuracy: 0.001)
    }

    func testSplitOfNothingIsNothing() {
        XCTAssertTrue(Manual.split(entry(at(9), at(9)), calendar: cal).isEmpty)
    }

    // MARK: - Laying entries over the timeline

    func testWithoutEntriesTheTimelineIsUntouched() {
        let segs = [segment(at(9), at(10))]
        XCTAssertEqual(Manual.apply([], to: segs), segs)
    }

    /// The point of the whole thing: an hour added by hand is an hour, not an
    /// hour on top of whatever the screen happened to be showing.
    func testRecordedTimeUnderneathIsReplacedNotAddedTo() {
        let segs = [segment(at(9), at(12), .personal)]
        let out = Manual.apply([entry(at(10), at(11))], to: segs)
        let totals = Totals.compute(out)
        XCTAssertEqual(totals.work, 3600)
        XCTAssertEqual(totals.personal, 2 * 3600)
        XCTAssertEqual(out.count, 3, "the personal stretch is cut either side of the entry")
        XCTAssertTrue(out[1].manual)
    }

    func testAnEntryCoveringAStretchRemovesItEntirely() {
        let out = Manual.apply([entry(at(9), at(12))], to: [segment(at(10), at(11), .personal)])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].manual)
        XCTAssertEqual(Totals.compute(out).personal, 0)
    }

    func testAnEntryOverEmptyTimeJustAppears() {
        let out = Manual.apply([entry(at(14), at(15))], to: [segment(at(9), at(10))])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].start, at(9))
        XCTAssertEqual(out[1].start, at(14))
    }

    func testOverlappingEndsAreTrimmed() {
        let out = Manual.apply([entry(at(10), at(11))], to: [segment(at(9), at(10, 30), .personal)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].end, at(10))
        XCTAssertEqual(Totals.compute(out).personal, 3600)
    }

    func testSeveralEntriesAllApply() {
        let out = Manual.apply([entry(at(10), at(11)), entry(at(13), at(14), .away)],
                               to: [segment(at(9), at(15), .personal)])
        let t = Totals.compute(out)
        XCTAssertEqual(t.work, 3600)
        XCTAssertEqual(t.away, 3600)
        XCTAssertEqual(t.personal, 4 * 3600)
        XCTAssertEqual(out.map(\.manual), [false, true, false, true, false])
    }

    /// Hand-entered time is never offered for review: nobody needs a rule for
    /// something they typed in themselves.
    func testAddedTimeIsNotOfferedForReview() {
        let out = Manual.apply([entry(at(10), at(11))], to: [segment(at(9), at(12), .unclassified)])
        XCTAssertTrue(ReviewItem.build(from: out).allSatisfy { $0.snapshot.appName != "" })
        XCTAssertEqual(Totals.compute(out).unclassified, 2 * 3600)
    }

    func testTheResultStaysInOrder() {
        let out = Manual.apply([entry(at(14), at(15)), entry(at(8), at(9))],
                               to: [segment(at(10), at(11), .personal)])
        XCTAssertEqual(out, out.sorted { $0.start < $1.start })
    }
}

final class ManualStoreTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private let day = "2026-08-30"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manual-\(UUID().uuidString)")
        store = Store(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func at(_ hour: Int) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.date(from: "\(day) \(String(format: "%02d", hour)):00")!
    }

    func testEntriesSurviveARoundTrip() {
        let e = ManualEntry(start: at(9), end: at(11), category: .work, note: "offsite")
        store.saveManual([e], day: day)
        let back = store.loadManual(day: day)
        XCTAssertEqual(back, [e])
        XCTAssertEqual(back.first?.note, "offsite")
    }

    func testEntriesComeBackInOrder() {
        store.saveManual([ManualEntry(start: at(14), end: at(15)),
                          ManualEntry(start: at(9), end: at(10))], day: day)
        XCTAssertEqual(store.loadManual(day: day).map(\.start), [at(9), at(14)])
    }

    /// Removing the last entry has to remove the file, or the day keeps
    /// appearing in the totals with nothing in it.
    func testSavingNoneRemovesTheFile() {
        store.saveManual([ManualEntry(start: at(9), end: at(10))], day: day)
        XCTAssertTrue(store.availableDays().contains(day))
        store.saveManual([], day: day)
        XCTAssertFalse(store.availableDays().contains(day))
        XCTAssertTrue(store.loadManual(day: day).isEmpty)
    }

    /// A day spent entirely in meetings has no observations at all, and still
    /// has to appear in the day list, the timeline and the CSV.
    func testADayOfNothingButAddedTimeStillCounts() {
        store.saveManual([ManualEntry(start: at(9), end: at(12), category: .work)], day: day)
        XCTAssertEqual(store.availableDays(), [day])

        let segs = store.segments(for: day, rules: RuleSet(), settings: .default)
        XCTAssertEqual(Totals.compute(segs).work, 3 * 3600)
        XCTAssertTrue(segs.allSatisfy(\.manual))

        let rows = store.rebuildDaily(rules: RuleSet(), settings: .default)
        XCTAssertEqual(rows.first?.date, day)
        XCTAssertEqual(rows.first?.work ?? 0, 3 * 3600, accuracy: 0.001)
    }

    func testAMissingFileIsSimplyNoEntries() {
        XCTAssertTrue(store.loadManual(day: "2020-01-01").isEmpty)
    }

    func testCorruptEntriesAreIgnoredRatherThanFatal() {
        try? "not json".write(to: store.manualURL(day), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.loadManual(day: day).isEmpty)
    }
}
