import XCTest
@testable import SundialCore

final class BreakInterruptionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private var settings: Settings {
        var settings = Settings.default
        settings.workBeforeBreak = 3600
        settings.breakLength = 600
        return settings
    }

    private func run(_ parts: [(TimeCategory, TimeInterval)]) -> [Segment] {
        var now = t0
        return parts.map { state, seconds in
            let end = now.addingTimeInterval(seconds)
            defer { now = end }
            return Segment(start: now, end: end, state: state, reason: "test")
        }
    }

    private func status(_ segments: [Segment]) -> BreakStatus {
        Breaks.status(segments: segments, now: segments.last?.end ?? t0,
                      settings: settings, currentState: segments.last?.state ?? .work)
    }

    private struct Session {
        var tracker = BreakCompletionTracker()
        var settings: Settings
        var segments: [Segment] = []
        var now: Date

        init(settings: Settings, now: Date) {
            self.settings = settings
            self.now = now
            append(.work, seconds: settings.workBeforeBreak)
        }

        mutating func append(_ state: TimeCategory, seconds: TimeInterval) {
            let end = now.addingTimeInterval(seconds)
            segments.append(Segment(start: now, end: end, state: state, reason: "test"))
            now = end
        }

        mutating func observe() -> Bool {
            tracker.update(segments: segments, now: now, settings: settings)
        }

        /// Observe short live steps so completion tests do not exercise the
        /// separate protection against stale notifications after sample gaps.
        mutating func record(_ state: TimeCategory, seconds: TimeInterval) -> Int {
            var remaining = seconds
            var completions = 0
            while remaining > 0 {
                let step = min(remaining, 10)
                append(state, seconds: step)
                if observe() { completions += 1 }
                remaining -= step
            }
            return completions
        }
    }

    func testBriefWorkClassificationDoesNotDiscardTenMinuteBreak() {
        let segments = run([(.work, 3600), (.away, 255), (.work, 5.6), (.away, 345)])
        let result = status(segments)
        XCTAssertFalse(result.owed)
        XCTAssertFalse(result.due)
        XCTAssertEqual(result.workedStraight, 0)
        XCTAssertEqual(result.toGo, settings.workBeforeBreak)
    }

    func testBriefWorkClassificationStillDeliversOneBreakCompletion() {
        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 255), 0)
        XCTAssertEqual(session.record(.work, seconds: 5.6), 0)
        XCTAssertEqual(session.record(.away, seconds: 344), 0)
        XCTAssertEqual(session.record(.away, seconds: 1), 1)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 600), 0)
    }

    func testExactlyFifteenSecondsOfCumulativeWorkIsTolerated() {
        let segments = run([
            (.work, 3600), (.away, 300), (.work, 7),
            (.personal, 200), (.work, 8), (.unclassified, 100)
        ])
        XCTAssertFalse(status(segments).owed)
        XCTAssertEqual(status(segments).workedStraight, 0)

        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        XCTAssertEqual(session.record(.work, seconds: 7), 0)
        XCTAssertEqual(session.record(.personal, seconds: 200), 0)
        XCTAssertEqual(session.record(.work, seconds: 8), 0)
        XCTAssertEqual(session.record(.unclassified, seconds: 100), 1)
    }

    func testMoreThanFifteenSecondsOfCumulativeWorkInterruptsBreak() {
        let segments = run([
            (.work, 3600), (.away, 300), (.work, 7),
            (.personal, 200), (.work, 8.1), (.away, 100)
        ])
        let result = status(segments)
        XCTAssertTrue(result.owed)
        XCTAssertEqual(result.workedStraight, 3615.1, accuracy: 0.001)

        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        XCTAssertEqual(session.record(.work, seconds: 7), 0)
        XCTAssertEqual(session.record(.personal, seconds: 200), 0)
        XCTAssertEqual(session.record(.work, seconds: 8.1), 0)
        XCTAssertEqual(session.record(.away, seconds: 100), 0)
    }

    func testAdjacentWorkSegmentsShareTheInterruptionLimit() {
        let segments = run([
            (.work, 3600), (.away, 300), (.work, 10), (.work, 10), (.away, 300)
        ])
        XCTAssertTrue(status(segments).owed)
        XCTAssertEqual(status(segments).workedStraight, 3620)

        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        XCTAssertEqual(session.record(.work, seconds: 20), 0)
        XCTAssertEqual(session.record(.away, seconds: 599), 0)
        XCTAssertEqual(session.record(.away, seconds: 1), 1)
    }

    func testToleratedWorkSecondsDoNotCountTowardBreakLength() {
        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        XCTAssertEqual(session.record(.work, seconds: 10), 0)
        XCTAssertEqual(session.record(.personal, seconds: 299), 0)
        XCTAssertTrue(status(session.segments).owed)
        XCTAssertEqual(status(session.segments).workedStraight, 3610)
        XCTAssertEqual(session.record(.personal, seconds: 1), 1)
        XCTAssertFalse(status(session.segments).owed)
    }

    func testMissingTimeDoesNotJoinTwoShortBreaks() {
        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        session.now = session.now.addingTimeInterval(5)
        XCTAssertEqual(session.record(.personal, seconds: 300), 0)
        XCTAssertTrue(status(session.segments).owed)
        XCTAssertEqual(status(session.segments).workedStraight, 3600)
        XCTAssertEqual(session.record(.personal, seconds: 300), 1)
        XCTAssertFalse(status(session.segments).owed)
    }

    func testWorkToleranceDoesNotBridgeMissingTime() {
        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        XCTAssertEqual(session.record(.work, seconds: 5), 0)
        session.now = session.now.addingTimeInterval(5)
        XCTAssertEqual(session.record(.away, seconds: 300), 0)
        XCTAssertTrue(status(session.segments).owed)
        XCTAssertEqual(status(session.segments).workedStraight, 3605)
    }

    func testCompletedBreakDoesNotChangeRecordedCategoryTotals() {
        let segments = run([(.work, 3600), (.away, 255), (.work, 5.6), (.away, 345)])
        XCTAssertFalse(status(segments).owed)
        let totals = Totals.compute(segments)
        XCTAssertEqual(totals.work, 3605.6, accuracy: 0.001)
        XCTAssertEqual(totals.away, 600)
    }

    func testEvenBriefWorkAfterCompletedBreakStartsANewCycle() {
        let segments = run([
            (.work, 3600), (.away, 255), (.work, 5.6), (.away, 345), (.work, 5)
        ])
        XCTAssertFalse(status(segments).owed)
        XCTAssertEqual(status(segments).workedStraight, 5)
        XCTAssertEqual(status(segments).toGo, 3595)
    }

    func testLaterShortBreakDoesNotUndoAnAlreadyCompletedInterruptedBreak() {
        let completed: [(TimeCategory, TimeInterval)] = [
            (.work, 3600), (.away, 400), (.work, 10), (.away, 200)
        ]
        XCTAssertFalse(status(run(completed)).owed)
        XCTAssertEqual(status(run(completed)).workedStraight, 0)

        let resumed = completed + [(.work, 10), (.personal, 200)]
        XCTAssertFalse(status(run(resumed)).owed)
        XCTAssertEqual(status(run(resumed)).workedStraight, 10)

        // The final 200 seconds of the first break can also form the start of
        // a later full break, once another 400 nonwork seconds have elapsed.
        let overlapping = resumed + [(.away, 200)]
        XCTAssertFalse(status(run(overlapping)).owed)
        XCTAssertEqual(status(run(overlapping)).workedStraight, 0)
    }

    func testSustainedWorkAfterCompletedInterruptedBreakOnlyCountsTheNewWork() {
        let segments = run([
            (.work, 3600), (.away, 400), (.work, 10), (.away, 200),
            (.work, 30), (.personal, 100)
        ])
        XCTAssertFalse(status(segments).owed)
        XCTAssertEqual(status(segments).workedStraight, 30)
        XCTAssertEqual(status(segments).toGo, 3570)
    }

    func testSubsequentWorkCycleCanCompleteAnotherInterruptedBreak() {
        var session = Session(settings: settings, now: t0)
        XCTAssertFalse(session.observe())
        XCTAssertEqual(session.record(.away, seconds: 255), 0)
        XCTAssertEqual(session.record(.work, seconds: 5.6), 0)
        XCTAssertEqual(session.record(.away, seconds: 345), 1)
        XCTAssertEqual(session.record(.work, seconds: 3600), 0)
        XCTAssertTrue(status(session.segments).owed)
        XCTAssertEqual(status(session.segments).workedStraight, 3600)
        XCTAssertEqual(session.record(.personal, seconds: 300), 0)
        XCTAssertEqual(session.record(.work, seconds: 10), 0)
        XCTAssertEqual(session.record(.away, seconds: 300), 1)
        XCTAssertFalse(status(session.segments).owed)
    }
}
