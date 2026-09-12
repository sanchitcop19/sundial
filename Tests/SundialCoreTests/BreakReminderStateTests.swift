import XCTest
@testable import SundialCore

final class BreakReminderStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private var settings: Settings {
        var settings = Settings.default
        settings.workBeforeBreak = 1500
        settings.breakLength = 300
        return settings
    }

    private func segment(_ state: TimeCategory, from start: TimeInterval,
                         to end: TimeInterval) -> Segment {
        Segment(start: t0 + start, end: t0 + end, state: state, reason: "test")
    }

    private func status(_ state: BreakReminderState, at seconds: TimeInterval,
                        segments: [Segment]? = nil, settings: Settings? = nil) -> BreakStatus {
        Breaks.status(segments: state.segmentsSinceSkip(
            segments ?? [segment(.work, from: -1500, to: seconds)]),
            now: t0 + seconds, settings: settings ?? self.settings,
            snoozedUntil: state.quietUntil)
    }

    func testRemindersWaitTwentyMinutesIncludingTheExactBoundary() {
        var state = BreakReminderState()
        XCTAssertNil(state.quietUntil)
        XCTAssertTrue(status(state, at: 0).due)

        state.recordReminder(at: t0)
        XCTAssertEqual(Breaks.repeatAfter, 1200)
        XCTAssertEqual(state.lastRemindedAt, t0)
        XCTAssertTrue(status(state, at: 1199).owed)
        XCTAssertFalse(status(state, at: 1199).due)
        XCTAssertTrue(status(state, at: 1200).due)

        state.recordReminder(at: t0 + 1200)
        XCTAssertFalse(status(state, at: 2399).due)
        XCTAssertTrue(status(state, at: 2400).due)
    }

    func testSnoozingAfterDeliveryWaitsTwentyMinutesFromTheAction() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        state.snooze(at: t0 + 120)

        XCTAssertEqual(Breaks.snooze, 1200)
        XCTAssertEqual(state.lastRemindedAt, t0)
        XCTAssertEqual(state.snoozedUntil, t0 + 1320)
        XCTAssertFalse(status(state, at: 1200).due)
        XCTAssertFalse(status(state, at: 1319).due)
        XCTAssertTrue(status(state, at: 1320).due)
    }

    func testClearingSnoozeCannotShortenTheMinimumReminderSpacing() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        state.snooze(at: t0 + 60)
        state.clearSnooze()

        XCTAssertNil(state.snoozedUntil)
        XCTAssertEqual(state.quietUntil, t0 + 1200)
        XCTAssertFalse(status(state, at: 1199).due)
        XCTAssertTrue(status(state, at: 1200).due)
    }

    func testSkippingClearsSnoozeButPreservesMinimumReminderSpacing() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        state.snooze(at: t0 + 30)
        state.skip(at: t0 + 60)

        XCTAssertEqual(state.skippedAt, t0 + 60)
        XCTAssertNil(state.snoozedUntil)
        XCTAssertEqual(state.lastRemindedAt, t0)
        XCTAssertEqual(state.quietUntil, t0 + 1200)

        var shortCycle = settings
        shortCycle.workBeforeBreak = 60
        XCTAssertTrue(status(state, at: 120, settings: shortCycle).owed)
        XCTAssertFalse(status(state, at: 120, settings: shortCycle).due)
        XCTAssertTrue(status(state, at: 1200, settings: shortCycle).due)
    }

    func testSkipClearsTheOwedBreakWithoutChangingRecordedWork() {
        let segments = [segment(.work, from: -1800, to: 0)]
        let before = DailySummary.compute(day: "2025-06-15", segments: segments, now: t0)
        var state = BreakReminderState()
        XCTAssertTrue(status(state, at: 0, segments: segments).owed)

        state.skip(at: t0)

        XCTAssertTrue(state.segmentsSinceSkip(segments).isEmpty)
        XCTAssertFalse(status(state, at: 0, segments: segments).owed)
        XCTAssertEqual(status(state, at: 0, segments: segments).toGo, 1500)
        XCTAssertEqual(DailySummary.compute(day: "2025-06-15", segments: segments, now: t0), before)
        XCTAssertEqual(before.work, 1800)
    }

    func testSkipClipsACrossingSegmentAndKeepsItsClassificationMetadata() {
        let crossing = Segment(start: t0 - 30, end: t0 + 30, state: .work,
                               snapshot: Snapshot(bundleId: "test.editor", appName: "Editor"),
                               ruleId: UUID(), ruleName: "Work editor", reason: "matched rule",
                               manual: true)
        let later = segment(.personal, from: 30, to: 60)
        let segments = [segment(.work, from: -1500, to: -30), crossing, later]
        var state = BreakReminderState()
        XCTAssertEqual(state.segmentsSinceSkip(segments), segments)
        state.skip(at: t0)

        var expected = crossing
        expected.start = t0
        XCTAssertEqual(state.segmentsSinceSkip(segments), [expected, later])
        XCTAssertEqual(segments[1], crossing, "Clipping must not rewrite recorded history")
    }

    func testAFullConfiguredWorkCycleAfterSkippingOwesAnotherBreak() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        state.skip(at: t0)

        XCTAssertEqual(status(state, at: 1499).workedStraight, 1499)
        XCTAssertFalse(status(state, at: 1499).owed)
        XCTAssertEqual(status(state, at: 1499).toGo, 1)
        XCTAssertTrue(status(state, at: 1500).owed)
        XCTAssertTrue(status(state, at: 1500).due)
    }

    func testSkippingAnOwedBreakDoesNotProduceABreakCompletion() {
        var state = BreakReminderState()
        var completion = BreakCompletionTracker()
        let work = segment(.work, from: -1500, to: 0)
        XCTAssertFalse(completion.update(segments: [work], now: t0, settings: settings))
        state.skip(at: t0)
        completion.reset()

        XCTAssertFalse(completion.update(segments: state.segmentsSinceSkip([work]),
                                         now: t0, settings: settings))
        for seconds in stride(from: 10.0, through: 300.0, by: 10) {
            let segments = [work, segment(.away, from: 0, to: seconds)]
            XCTAssertFalse(completion.update(segments: state.segmentsSinceSkip(segments),
                                             now: t0 + seconds, settings: settings),
                           "Skipping must not be reported as completing a break")
        }
    }

    func testReclassifyingHistoryAndChangingSettingsCannotRepeatAnEarlyReminder() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        let reclassified = [segment(.personal, from: -1500, to: 30)]
        XCTAssertFalse(status(state, at: 30, segments: reclassified).owed)
        var changed = settings
        changed.workBeforeBreak = 60

        XCTAssertTrue(status(state, at: 60, settings: changed).owed)
        XCTAssertFalse(status(state, at: 60, settings: changed).due)
        XCTAssertTrue(status(state, at: 1200, settings: changed).due)
    }

    func testCompletingABreakCannotRepeatAReminderWithinTwentyMinutes() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        var shortCycle = settings
        shortCycle.workBeforeBreak = 60
        let completedBreak = [segment(.work, from: -1500, to: 0),
                              segment(.away, from: 0, to: 300)]
        XCTAssertFalse(status(state, at: 300, segments: completedBreak,
                              settings: shortCycle).owed)
        let resumedWork = completedBreak + [segment(.work, from: 300, to: 360)]
        XCTAssertTrue(status(state, at: 360, segments: resumedWork, settings: shortCycle).owed)
        XCTAssertFalse(status(state, at: 360, segments: resumedWork, settings: shortCycle).due)
        XCTAssertTrue(status(state, at: 1200, segments: resumedWork, settings: shortCycle).due)
    }

    func testDelayedDeliveryStartsTheNextIntervalAtActualDelivery() {
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        XCTAssertTrue(status(state, at: 1800).due)
        state.recordReminder(at: t0 + 1800)

        XCTAssertFalse(status(state, at: 2400).due)
        XCTAssertFalse(status(state, at: 2999).due)
        XCTAssertTrue(status(state, at: 3000).due)
    }

    func testReminderStateSurvivesRestartWithSnoozeSkipAndDeliveryTime() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        var state = BreakReminderState()
        state.recordReminder(at: t0)
        state.skip(at: t0 + 60)
        state.snooze(at: t0 + 90)
        store.save(state)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("break-reminders.json").path))
        let restored = Store(root: root).loadBreakReminderState()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.quietUntil, t0 + 1290)
        var shortCycle = settings
        shortCycle.workBeforeBreak = 60
        XCTAssertFalse(status(restored, at: 1289, settings: shortCycle).due)
        XCTAssertTrue(status(restored, at: 1290, settings: shortCycle).due)
        XCTAssertEqual(status(restored, at: 1500).workedStraight, 1440)
    }

    func testMissingReminderStateStartsWithoutAQuietPeriodOrSkip() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = Store(root: root).loadBreakReminderState()

        XCTAssertEqual(state, BreakReminderState())
        XCTAssertNil(state.lastRemindedAt)
        XCTAssertNil(state.snoozedUntil)
        XCTAssertNil(state.skippedAt)
        XCTAssertTrue(status(state, at: 0).due)
    }
}
