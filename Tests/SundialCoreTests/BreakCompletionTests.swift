import XCTest
@testable import SundialCore

final class BreakCompletionTests: XCTestCase {
    private struct Session {
        var tracker = BreakCompletionTracker()
        var settings = Settings.default
        var now = Date(timeIntervalSince1970: 1_750_000_000)
        var segments: [Segment] = []

        init(worked: TimeInterval = 1500) {
            settings.workBeforeBreak = 1500
            settings.breakLength = 300
            append(.work, seconds: worked)
        }

        mutating func append(_ state: TimeCategory, seconds: TimeInterval) {
            guard seconds > 0 else { return }
            let end = now.addingTimeInterval(seconds)
            segments.append(Segment(start: now, end: end, state: state, reason: "test"))
            now = end
        }

        mutating func observe(inCall: Bool = false) -> Bool {
            tracker.update(segments: segments, now: now, settings: settings, inCall: inCall)
        }

        /// Keep the tracker live while advancing the timeline, including at
        /// the exact requested boundary rather than jumping across the break.
        mutating func record(_ state: TimeCategory, seconds: TimeInterval,
                             inCall: Bool = false) -> Int {
            var remaining = seconds
            var completions = 0
            while remaining > 0 {
                let step = min(remaining, 10)
                append(state, seconds: step)
                if observe(inCall: inCall) { completions += 1 }
                remaining -= step
            }
            return completions
        }
    }

    func testCompletesAtTheExactBreakLength() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 299), 0)
        XCTAssertEqual(session.record(.away, seconds: 1), 1)
    }

    func testConsecutiveNonworkCategoriesCombine() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.personal, seconds: 100), 0)
        XCTAssertEqual(session.record(.away, seconds: 100), 0)
        XCTAssertEqual(session.record(.unclassified, seconds: 100), 1)
    }

    func testCompletionIsOnlyDeliveredOnceDuringAnExtendedBreak() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 1)
        XCTAssertFalse(session.observe(), "An unchanged sample must not repeat the alert")
        XCTAssertEqual(session.record(.away, seconds: 600), 0)
        XCTAssertEqual(session.record(.personal, seconds: 300), 0)
    }

    func testShortBreakInterruptedBySustainedWorkMustStartAgain() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 200), 0)
        XCTAssertEqual(session.record(.work, seconds: Breaks.interruptionTolerance + 1), 0)
        XCTAssertEqual(session.record(.personal, seconds: 299), 0)
        XCTAssertEqual(session.record(.personal, seconds: 1), 1)
    }

    func testASecondOwedWorkCycleCanCompleteAnotherBreak() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 1)
        XCTAssertEqual(session.record(.work, seconds: 1500), 0)
        XCTAssertEqual(session.record(.away, seconds: 300), 1)
    }

    func testBreakBeforeEnoughWorkDoesNotNotify() {
        var session = Session(worked: 1499)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 600), 0)
    }

    func testStartupDoesNotNotifyForAHistoricalCompletedBreak() {
        var session = Session()
        session.append(.away, seconds: 600)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 60), 0)
    }

    func testGapBetweenSamplesCancelsThePendingCompletion() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 200), 0)
        session.append(.away, seconds: session.settings.maxSampleGap + 1)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
    }

    func testDisablingRemindersCancelsThePendingCompletion() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 200), 0)
        session.settings.breakReminders = false
        XCTAssertEqual(session.record(.away, seconds: 100), 0)
        session.settings.breakReminders = true
        XCTAssertEqual(session.record(.away, seconds: 100), 0)
    }

    func testResetCancelsThePendingCompletion() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 200), 0)
        session.tracker.reset()
        XCTAssertEqual(session.record(.away, seconds: 100), 0)
    }

    func testCompletionDuringACallIsConsumedWithoutAnAlert() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 290), 0)
        XCTAssertEqual(session.record(.away, seconds: 10, inCall: true), 0)
        XCTAssertEqual(session.record(.away, seconds: 100), 0,
                       "Ending the call must not deliver the old completion")
    }

    func testDisjointNonworkSegmentsDoNotCombineAcrossMissingTime() {
        var session = Session()
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.personal, seconds: 150), 0)
        // Missing observations are not proof of an uninterrupted break. The
        // sample gap itself stays below maxSampleGap to isolate this rule.
        session.now = session.now.addingTimeInterval(5)
        XCTAssertEqual(session.record(.away, seconds: 150), 0)
        XCTAssertEqual(session.record(.away, seconds: 150), 1)
    }
}
