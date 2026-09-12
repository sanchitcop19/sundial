import XCTest
@testable import SundialCore

final class FocusRunTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(_ start: TimeInterval, _ end: TimeInterval,
                         _ state: TimeCategory = .work, manual: Bool = false) -> Segment {
        Segment(start: origin.addingTimeInterval(start),
                end: origin.addingTimeInterval(end), state: state, reason: "", manual: manual)
    }

    func testBreakSplitIntoShortAwaySegmentsEndsFocus() {
        // Observation changes can split a half-hour break into 30-second
        // segments. It is still one break, not sixty tolerated glances.
        let away = stride(from: 3600.0, to: 5400.0, by: 30).map {
            segment($0, $0 + 30, .away)
        }
        let segments = [segment(0, 3600)] + away + [segment(5400, 7200)]

        let result = DayStats.focusRuns(segments, tolerance: 120)

        XCTAssertEqual(result.longest, 3600)
        XCTAssertEqual(result.count, 2)
    }

    func testConsecutiveDifferentNonworkStatesFormOneInterruption() {
        let segments = [
            segment(0, 3600),
            segment(3600, 3660, .personal),
            segment(3660, 3720, .unclassified),
            segment(3720, 3780, .away),
            segment(3780, 5580),
        ]

        let result = DayStats.focusRuns(segments, tolerance: 120)

        XCTAssertEqual(result.longest, 3600)
        XCTAssertEqual(result.count, 2)
    }

    func testUnrecordedGapEndsFocus() {
        let result = DayStats.focusRuns([segment(0, 3600), segment(7200, 9000)],
                                       tolerance: 120)

        XCTAssertEqual(result.longest, 3600)
        XCTAssertEqual(result.count, 2)
    }

    func testPauseAndMissingRecordGapAccumulate() {
        let result = DayStats.focusRuns([
            segment(0, 3600),
            segment(3660, 3721, .personal),
            segment(3721, 5521),
        ], tolerance: 120)

        XCTAssertEqual(result.longest, 3600)
        XCTAssertEqual(result.count, 2)
    }

    func testBriefPausesPreserveBlockWithoutAddingFocusTime() {
        let segments = [
            segment(0, 3600),
            segment(3600, 3660, .personal),
            segment(3660, 7260),
            segment(7260, 7320, .away),
            segment(7320, 10920),
        ]

        let result = DayStats.focusRuns(segments, tolerance: 120)

        XCTAssertEqual(result.longest, 3 * 3600)
        XCTAssertEqual(result.count, 1)
    }

    func testToleranceBoundaryUsesWholePause() {
        let within = DayStats.focusRuns([segment(0, 3600), segment(3720, 5520)],
                                       tolerance: 120)
        let beyond = DayStats.focusRuns([segment(0, 3600), segment(3721, 5521)],
                                       tolerance: 120)

        XCTAssertEqual(within.longest, 5400)
        XCTAssertEqual(within.count, 1)
        XCTAssertEqual(beyond.longest, 3600)
        XCTAssertEqual(beyond.count, 2)
    }

    func testEmptyWorkSegmentCannotBridgeBreak() {
        let result = DayStats.focusRuns([
            segment(0, 3600), segment(3720, 3720), segment(3840, 5640),
        ], tolerance: 120)

        XCTAssertEqual(result.longest, 3600)
        XCTAssertEqual(result.count, 2)
    }

    func testDayAndRangeStatsUseCorrectedFocusWithoutChangingTotals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let segments = [
            segment(0, 3600),
            segment(3600, 3660, .away),
            segment(3660, 3720, .away),
            segment(3720, 3780, .away),
            segment(3780, 5580),
        ]
        let day = DayStats.compute(day: Format.day(origin, calendar: calendar),
                                   segments: segments, presence: PresenceLog(), calendar: calendar)
        let range = RangeStats.compute(days: [day], contexts: [])

        XCTAssertEqual(day.focusBlocks, 2)
        XCTAssertEqual(day.longestFocus, 3600)
        XCTAssertEqual(range.longestFocus, 3600)
        XCTAssertEqual(day.totals.work, 5400)
        XCTAssertEqual(day.totals.away, 180)
    }

    func testManualDailyTotalDoesNotImplyContinuousFocus() {
        // A daily total entered as a single span is work time, but contains
        // no observations proving an uninterrupted eight-and-a-half-hour run.
        let segments = [segment(0, 8.5 * 3600, manual: true)]
        let day = DayStats.compute(day: Format.day(origin), segments: segments,
                                   presence: PresenceLog())

        XCTAssertEqual(day.longestFocus, 0)
        XCTAssertEqual(day.focusBlocks, 0)
        XCTAssertEqual(day.totals.work, 8.5 * 3600)
    }

    func testShortManualEntryCannotBridgeObservedFocusBlocks() {
        let segments = [
            segment(0, 3600),
            segment(3600, 3660, manual: true),
            segment(3660, 5460),
        ]
        let result = DayStats.focusRuns(segments, tolerance: 120)

        XCTAssertEqual(result.longest, 3600)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Totals.compute(segments).work, 5460)
    }

    func testLongManualEntryBetweenRecordedSessionsContributesOnlyToTotals() {
        let segments = [
            segment(0, 3600),
            segment(3600, 9.5 * 3600, manual: true),
            segment(9.5 * 3600, 11.5 * 3600),
        ]
        let result = DayStats.focusRuns(segments, tolerance: 120)

        XCTAssertEqual(result.longest, 2 * 3600)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Totals.compute(segments).work, 11.5 * 3600)
    }
}
