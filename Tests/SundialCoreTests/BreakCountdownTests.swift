import XCTest
@testable import SundialCore

final class BreakCountdownTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private var settings: Settings {
        var settings = Settings.default
        settings.workBeforeBreak = 1500
        settings.breakLength = 300
        return settings
    }

    private func run(_ parts: [(TimeCategory, TimeInterval)]) -> [Segment] {
        var start = t0
        return parts.map { state, seconds in
            let end = start.addingTimeInterval(seconds)
            defer { start = end }
            return Segment(start: start, end: end, state: state, reason: "test")
        }
    }

    private func status(_ parts: [(TimeCategory, TimeInterval)],
                        snoozedUntil: Date? = nil, settings: Settings? = nil,
                        activeBreak: Span? = nil) -> BreakStatus {
        let segments = run(parts)
        return Breaks.status(segments: segments, now: segments.last?.end ?? t0,
                             settings: settings ?? self.settings, snoozedUntil: snoozedUntil,
                             currentState: segments.last?.state ?? .work, activeBreak: activeBreak)
    }

    func testWorkingShowsTheTimeUntilTheNextBreak() {
        let result = status([(.work, 1200)])

        XCTAssertEqual(result.nextBreakIn, 300)
        XCTAssertNil(result.breakRemaining)
        XCTAssertEqual(result.countdownText, "Next break in 5:00")
    }

    func testNextBreakCountdownRoundsPositiveFractionsUp() {
        let result = status([(.work, 1499.75)])

        XCTAssertEqual(result.nextBreakIn, 0.25)
        XCTAssertEqual(result.countdownText, "Next break in 0:01")
        XCTAssertFalse(result.owed)
    }

    func testCountdownKeepsTotalMinutesBeyondAnHour() {
        var longerCycle = settings
        longerCycle.workBeforeBreak = 4800

        let result = status([], settings: longerCycle)

        XCTAssertEqual(result.nextBreakIn, 4800)
        XCTAssertEqual(result.countdownText, "Next break in 80:00")
    }

    func testQuietIntervalShowsTimeUntilTheReminderCanReturn() {
        let result = status([(.work, 1500)], snoozedUntil: t0 + 1800)

        XCTAssertEqual(result.toGo, 0)
        XCTAssertEqual(result.nextBreakIn, 300)
        XCTAssertEqual(result.countdownText, "Next break in 5:00")
        XCTAssertTrue(result.owed)
        XCTAssertFalse(result.due)
    }

    func testLongerQuietIntervalWinsOverRemainingWork() {
        let result = status([(.work, 1200)], snoozedUntil: t0 + 1800)

        XCTAssertEqual(result.toGo, 300)
        XCTAssertEqual(result.nextBreakIn, 600)
        XCTAssertEqual(result.countdownText, "Next break in 10:00")
    }

    func testRemainingWorkWinsOverAShorterQuietInterval() {
        let result = status([(.work, 1200)], snoozedUntil: t0 + 1260)

        XCTAssertEqual(result.toGo, 300)
        XCTAssertEqual(result.nextBreakIn, 300)
        XCTAssertEqual(result.countdownText, "Next break in 5:00")
    }

    func testQuietIntervalExpiresAtItsExactEnd() {
        let result = status([(.work, 1800)], snoozedUntil: t0 + 1800)

        XCTAssertEqual(result.nextBreakIn, 0)
        XCTAssertEqual(result.countdownText, "Break due now")
        XCTAssertTrue(result.due)
        XCTAssertNil(result.heldBack)
    }

    func testExactWorkThresholdShowsBreakDueNow() {
        let result = status([(.work, 1500)])

        XCTAssertEqual(result.nextBreakIn, 0)
        XCTAssertNil(result.breakRemaining)
        XCTAssertEqual(result.countdownText, "Break due now")
        XCTAssertTrue(result.due)
    }

    func testExplicitBreakShowsTheTimeRemaining() {
        let result = status([(.work, 1500), (.away, 120)], activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 180)
        XCTAssertEqual(result.countdownText, "Break ends in 3:00")
        XCTAssertFalse(result.owed)
        XCTAssertFalse(result.due)
    }

    func testBreakCountdownRoundsPositiveFractionsUp() {
        let result = status([(.work, 1500), (.away, 299.75)], activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 0.25)
        XCTAssertEqual(result.countdownText, "Break ends in 0:01")
        XCTAssertFalse(result.owed)
    }

    func testFifteenSecondsOfWorkDoNotFreezeAnExplicitBreak() {
        let result = status([(.work, 1500), (.away, 120), (.work, 15)],
                            activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 165)
        XCTAssertEqual(result.countdownText, "Break ends in 2:45")
        XCTAssertEqual(result.workedStraight, 1515)
    }

    func testResumedRestPreservesTheExplicitDeadline() {
        let result = status([(.work, 1500), (.away, 120), (.work, 15), (.personal, 60)],
                            activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 105)
        XCTAssertEqual(result.countdownText, "Break ends in 1:45")
        XCTAssertEqual(result.workedStraight, 1515)
    }

    func testSustainedWorkDoesNotEndTheExplicitBreakCountdown() {
        let result = status([(.work, 1500), (.away, 120), (.work, 16)],
                            activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 164)
        XCTAssertEqual(result.countdownText, "Break ends in 2:44")
        XCTAssertEqual(result.workedStraight, 1516)
    }

    func testMissingObservationsDoNotMoveTheExplicitDeadline() {
        var segments = run([(.work, 1500), (.away, 120)])
        segments.append(Segment(start: t0 + 1625, end: t0 + 1685,
                                state: .personal, reason: "test"))

        let result = Breaks.status(segments: segments, now: t0 + 1685,
                                   settings: settings, currentState: .personal,
                                   activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 115)
        XCTAssertEqual(result.countdownText, "Break ends in 1:55")
        XCTAssertEqual(result.workedStraight, 1500)
    }

    func testMixedNonworkCategoriesShareTheBreakCountdown() {
        let result = status([(.work, 1500), (.personal, 60), (.away, 60), (.unclassified, 60)],
                            activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 120)
        XCTAssertEqual(result.countdownText, "Break ends in 2:00")
    }

    func testExactBreakLengthShowsCompletion() {
        let result = status([(.work, 1500), (.away, 300)], activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.breakRemaining, 0)
        XCTAssertEqual(result.nextBreakIn, 1500)
        XCTAssertEqual(result.countdownText, "Break complete")
        XCTAssertFalse(result.owed)
    }

    func testResumingWorkAfterACompletedBreakShowsTheNextBreakCountdown() {
        let result = status([(.work, 1500), (.away, 300), (.work, 5)])

        XCTAssertNil(result.breakRemaining)
        XCTAssertEqual(result.nextBreakIn, 1495)
        XCTAssertEqual(result.countdownText, "Next break in 24:55")
        XCTAssertEqual(result.workedStraight, 5)
    }

    func testDisabledRemindersDoNotExposeAnActiveBreakCountdown() {
        var disabled = settings
        disabled.breakReminders = false

        let result = status([(.work, 1500), (.away, 120)], settings: disabled,
                            activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertNil(result.breakRemaining)
        XCTAssertFalse(result.owed)
        XCTAssertFalse(result.due)
    }

    func testWorkProjectionCountsDownThroughTheDueBoundaryWithoutChangingStatus() {
        let result = status([(.work, 1200)])

        XCTAssertEqual(result.countdownText(after: 60, currentState: .work), "Next break in 4:00")
        XCTAssertEqual(result.countdownText(after: 300, currentState: .work), "Break due now")
        XCTAssertEqual(result.countdownText(after: 301, currentState: .work), "Break due now")
        XCTAssertEqual(result.nextBreakIn, 300)
        XCTAssertEqual(result.toGo, 300)
        XCTAssertEqual(result.countdownText, "Next break in 5:00")
    }

    func testWorkProjectionAlsoCountsDownTheQuietInterval() {
        let result = status([(.work, 1200)], snoozedUntil: t0 + 1800)

        XCTAssertEqual(result.countdownText(after: 120, currentState: .work), "Next break in 8:00")
        XCTAssertEqual(result.countdownText(after: 480, currentState: .work), "Next break in 2:00")
        XCTAssertEqual(result.countdownText(after: 600, currentState: .work), "Break due now")
        XCTAssertEqual(result.nextBreakIn, 600)
        XCTAssertEqual(result.toGo, 300)
    }

    func testNonworkProjectionExpiresQuietTimeButPreservesRemainingWork() {
        let result = status([(.work, 1200)], snoozedUntil: t0 + 1800)

        XCTAssertEqual(result.countdownText(after: 120, currentState: .away), "Next break in 8:00")
        XCTAssertEqual(result.countdownText(after: 600, currentState: .away), "Next break in 5:00")
        XCTAssertEqual(result.countdownText(after: 1200, currentState: .away), "Next break in 5:00")
        XCTAssertNil(result.breakRemaining)
        XCTAssertEqual(result.toGo, 300)
    }

    func testBreakProjectionAdvancesRegardlessOfActivityAndStopsAtCompletion() {
        let result = status([(.work, 1500), (.away, 120)], activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(result.countdownText(after: 60, currentState: .away), "Break ends in 2:00")
        XCTAssertEqual(result.countdownText(after: 5, currentState: .work), "Break ends in 2:55")
        XCTAssertEqual(result.countdownText(after: 180, currentState: .personal), "Break complete")
        XCTAssertEqual(result.countdownText(after: 181, currentState: .unclassified), "Break complete")
        XCTAssertEqual(result.breakRemaining, 180)
        XCTAssertEqual(result.countdownText, "Break ends in 3:00")
    }

    func testPassiveRestDoesNotStartATimer() {
        let result = status([(.work, 1500), (.away, 120)])
        XCTAssertNil(result.breakRemaining)
        XCTAssertNil(result.breakEndsAt)
        XCTAssertEqual(result.countdownText, "Break due now")
    }

    func testLongPassiveRestEarnsWorkCreditWithoutStartingATimer() {
        let result = status([(.work, 1500), (.personal, 300)])
        XCTAssertNil(result.breakRemaining)
        XCTAssertNil(result.breakEndsAt)
        XCTAssertEqual(result.countdownText, "Next break in 25:00")
        XCTAssertFalse(result.owed)
    }

    func testNegativeElapsedTimeDoesNotIncreaseEitherCountdown() {
        let working = status([(.work, 1200)])
        let resting = status([(.work, 1500), (.away, 120)], activeBreak: Span(t0 + 1500, t0 + 1800))

        XCTAssertEqual(working.countdownText(after: -60, currentState: .work), "Next break in 5:00")
        XCTAssertEqual(resting.countdownText(after: -60, currentState: .away), "Break ends in 3:00")
    }
}
