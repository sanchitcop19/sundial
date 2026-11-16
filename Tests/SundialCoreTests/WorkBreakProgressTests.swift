import XCTest
@testable import SundialCore

final class WorkBreakProgressTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-09-18T12:00:00Z")!
    private var settings: Settings {
        var settings = Settings.default
        settings.workBeforeBreak = 1500
        settings.breakLength = 300
        return settings
    }

    private func snapshot(at date: Date? = nil, state: String = "away",
                          breakEndsAt: TimeInterval? = nil,
                          breakPausedRemaining: TimeInterval? = nil) -> WorkProgressSnapshot {
        WorkProgressSnapshot(day: "2026-09-18", timeZoneIdentifier: "UTC",
                             updatedAt: (date ?? t0).timeIntervalSince1970,
                             worked: 4 * 3600, target: 8 * 3600,
                             state: state, isPaused: false,
                             breakEndsAt: breakEndsAt, breakPausedRemaining: breakPausedRemaining)
    }

    private func status(_ parts: [(TimeCategory, TimeInterval)],
                        settings: Settings? = nil, activeBreak: Span? = nil) -> BreakStatus {
        var start = t0 - 1500
        let segments = parts.map { state, seconds in
            let end = start + seconds
            defer { start = end }
            return Segment(start: start, end: end, state: state, reason: "test")
        }
        return Breaks.status(segments: segments, now: start, settings: settings ?? self.settings,
                             currentState: segments.last?.state ?? .work,
                             activeBreak: activeBreak ?? Span(t0, t0 + 300))
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testLegacySnapshotWithoutBreakFieldsStillDecodes() throws {
        let legacy = """
        {"day":"2026-09-18","timeZoneIdentifier":"UTC","updatedAt":\(t0.timeIntervalSince1970),
         "worked":14400,"target":28800,"state":"away","isPaused":false}
        """

        let decoded = try JSONDecoder().decode(WorkProgressSnapshot.self, from: Data(legacy.utf8))

        XCTAssertTrue(decoded.isValid)
        XCTAssertNil(decoded.breakEndsAt)
        XCTAssertNil(decoded.breakPausedRemaining)
        XCTAssertNil(decoded.breakRemaining(at: t0))
        XCTAssertFalse(decoded.hasActiveBreak)
    }

    func testRunningBreakRoundTripsAsAUnixDeadline() throws {
        let original = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 300)
        let data = try JSONEncoder().encode(original)
        let json = try object(original)

        XCTAssertEqual(try JSONDecoder().decode(WorkProgressSnapshot.self, from: data), original)
        XCTAssertEqual(json["breakEndsAt"] as? Double, t0.timeIntervalSince1970 + 300)
        XCTAssertNil(json["breakPausedRemaining"])
        XCTAssertTrue(original.isValid)
    }

    func testFrozenBreakRoundTripsAsRemainingSeconds() throws {
        let original = snapshot(state: "work", breakPausedRemaining: 180)
        let data = try JSONEncoder().encode(original)
        let json = try object(original)

        XCTAssertEqual(try JSONDecoder().decode(WorkProgressSnapshot.self, from: data), original)
        XCTAssertEqual(json["breakPausedRemaining"] as? Double, 180)
        XCTAssertNil(json["breakEndsAt"])
        XCTAssertTrue(original.isValid)
    }

    func testAPNsContentStateIncludesTheRunningDeadline() throws {
        let original = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 300)
        let json = try object(LiveActivityPushPayload(snapshot: original, now: t0))
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        let content = try XCTUnwrap(aps["content-state"] as? [String: Any])

        XCTAssertEqual(Set(aps.keys), ["timestamp", "event", "content-state", "stale-date"])
        XCTAssertEqual(content["breakEndsAt"] as? Double, t0.timeIntervalSince1970 + 300)
        XCTAssertNil(content["breakPausedRemaining"])
    }

    func testAPNsContentStateIncludesFrozenBreakSeconds() throws {
        let original = snapshot(state: "work", breakPausedRemaining: 180)
        let json = try object(LiveActivityPushPayload(snapshot: original, now: t0))
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        let content = try XCTUnwrap(aps["content-state"] as? [String: Any])

        XCTAssertEqual(content["breakPausedRemaining"] as? Double, 180)
        XCTAssertNil(content["breakEndsAt"])
    }

    func testRemainingBreakTimeCountsDownAndClampsAtZero() {
        let running = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 300)

        XCTAssertTrue(running.hasActiveBreak)
        XCTAssertEqual(running.breakRemaining(at: t0 + 120), 180)
        XCTAssertEqual(running.breakRemaining(at: t0 + 300), 0)
        XCTAssertEqual(running.breakRemaining(at: t0 + 301), 0)
    }

    func testFrozenBreakTimeDoesNotCountDown() {
        let frozen = snapshot(state: "work", breakPausedRemaining: 180)

        XCTAssertTrue(frozen.hasActiveBreak)
        XCTAssertEqual(frozen.breakRemaining(at: t0), 180)
        XCTAssertEqual(frozen.breakRemaining(at: t0 + 120), 180)
    }

    func testDeadlineStaysStableDespiteDifferentClassificationDelays() {
        let firstStatus = status([(.work, 1500), (.away, 120.25)])
        var first = snapshot(at: t0 + 123)
        first.updateBreak(firstStatus)
        let laterStatus = status([(.work, 1500), (.away, 180.5)])
        var later = snapshot(at: t0 + 187)
        later.updateBreak(laterStatus)

        XCTAssertEqual(first.breakEndsAt, t0.timeIntervalSince1970 + 300)
        XCTAssertEqual(later.breakEndsAt, first.breakEndsAt)
        XCTAssertNil(first.breakPausedRemaining)
        XCTAssertNil(later.breakPausedRemaining)
        XCTAssertTrue(first.isValid)
        XCTAssertTrue(later.isValid)
    }

    func testWorkGlanceAndResumingKeepTheOriginalDeadline() {
        var progress = snapshot(at: t0 + 119.25)
        progress.updateBreak(status([(.work, 1500), (.away, 119.25)]))
        XCTAssertEqual(progress.breakEndsAt, t0.timeIntervalSince1970 + 300)

        progress.state = "work"
        progress.updatedAt = (t0 + 129.25).timeIntervalSince1970
        progress.updateBreak(status([(.work, 1500), (.away, 119.25), (.work, 10)]))
        XCTAssertEqual(progress.breakEndsAt, t0.timeIntervalSince1970 + 300)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertEqual(progress.breakRemaining(at: t0 + 139.25), 160.75)

        progress.state = "away"
        progress.updatedAt = (t0 + 139.25).timeIntervalSince1970
        progress.updateBreak(status([(.work, 1500), (.away, 119.25), (.work, 10), (.away, 10)]))
        XCTAssertEqual(progress.breakEndsAt, t0.timeIntervalSince1970 + 300)
        XCTAssertNil(progress.breakPausedRemaining)
    }

    func testCompletedBreakClearsAnExistingDeadline() {
        var progress = snapshot(at: t0 + 300, breakEndsAt: t0.timeIntervalSince1970 + 300)

        progress.updateBreak(status([(.work, 1500), (.away, 300)]))

        XCTAssertNil(progress.breakEndsAt)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertFalse(progress.hasActiveBreak)
    }

    func testDisabledRemindersClearAnExistingFrozenBreak() {
        var disabled = settings
        disabled.breakReminders = false
        var progress = snapshot(at: t0 + 130, state: "work", breakPausedRemaining: 180)

        progress.updateBreak(status([(.work, 1500), (.away, 120), (.work, 10)], settings: disabled))

        XCTAssertNil(progress.breakEndsAt)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertFalse(progress.hasActiveBreak)
    }

    func testPausingTrackingClearsTheBreak() {
        var progress = snapshot(at: t0 + 120, breakEndsAt: t0.timeIntervalSince1970 + 300)
        progress.isPaused = true
        XCTAssertFalse(progress.hasActiveBreak)

        progress.updateBreak(status([(.work, 1500), (.away, 120)]))

        XCTAssertNil(progress.breakEndsAt)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertTrue(progress.isValid)
    }

    func testClassificationFinishingAtTheDeadlineDoesNotPublishAnExpiredBreak() {
        var progress = snapshot(at: t0 + 300, breakEndsAt: t0.timeIntervalSince1970 + 300)

        progress.updateBreak(status([(.work, 1500), (.away, 120)]))

        XCTAssertNil(progress.breakEndsAt)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertFalse(progress.hasActiveBreak)
    }

    func testNonfiniteDeadlineClearsTheBreak() {
        var invalidStatus = status([(.work, 1500), (.away, 120)])
        invalidStatus.breakEndsAt = Date(timeIntervalSince1970: .infinity)
        var progress = snapshot(at: t0 + 120, breakEndsAt: t0.timeIntervalSince1970 + 300)

        progress.updateBreak(invalidStatus)

        XCTAssertNil(progress.breakEndsAt)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertFalse(progress.hasActiveBreak)
    }

    func testPassiveRestDoesNotPublishABreak() {
        let segments = [Segment(start: t0, end: t0 + 120, state: .away, reason: "test")]
        let status = Breaks.status(segments: segments, now: t0 + 120, settings: settings,
                                   currentState: .away)
        var progress = snapshot(at: t0 + 120)
        progress.updateBreak(status)
        XCTAssertNil(progress.breakEndsAt)
        XCTAssertNil(progress.breakPausedRemaining)
        XCTAssertFalse(progress.hasActiveBreak)
    }

    func testFractionalDeadlineIsCopiedExactlyDuringWork() {
        var progress = snapshot(at: t0 + 120, state: "work")
        let explicit = status([(.work, 1620)], activeBreak: Span(t0 + 0.25, t0 + 300.25))
        progress.updateBreak(explicit)
        XCTAssertEqual(progress.breakEndsAt, t0.timeIntervalSince1970 + 300.25)
        XCTAssertNil(progress.breakPausedRemaining)
    }

    func testFreshnessRemainsSeparateFromWhetherABreakIsPresent() {
        let progress = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 600)

        XCTAssertTrue(progress.hasActiveBreak)
        XCTAssertFalse(progress.isStale(at: t0 + 299))
        XCTAssertTrue(progress.isStale(at: t0 + 300))
        XCTAssertEqual(progress.breakRemaining(at: t0 + 300), 300)
    }

    func testUnchangedDeadlineWaitsForTheThreeMinuteHeartbeat() {
        let previous = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 600)
        var current = previous
        current.updatedAt += 179
        XCTAssertFalse(WorkProgressSync.shouldPublish(current, replacing: previous))

        current.updatedAt += 1
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
        XCTAssertEqual(current.breakEndsAt, previous.breakEndsAt)
    }

    func testStartingABreakPublishesWithoutChangingTheActivityCategory() {
        let previous = snapshot()
        var current = previous
        current.updatedAt += 1
        current.breakEndsAt = t0.timeIntervalSince1970 + 300

        XCTAssertEqual(current.state, previous.state)
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testFreezingABreakPublishesWithoutWaitingForTheHeartbeat() {
        let previous = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 300)
        var current = previous
        current.updatedAt += 1
        current.breakEndsAt = nil
        current.breakPausedRemaining = 299

        XCTAssertEqual(current.state, previous.state)
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testResumingABreakPublishesWithoutWaitingForTheHeartbeat() {
        let previous = snapshot(breakPausedRemaining: 180)
        var current = previous
        current.updatedAt += 1
        current.breakPausedRemaining = nil
        current.breakEndsAt = current.updatedAt + 180

        XCTAssertEqual(current.state, previous.state)
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testCompletingABreakPublishesWhileStillAway() {
        let previous = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 1)
        var current = previous
        current.updatedAt += 1
        current.breakEndsAt = nil

        XCTAssertEqual(current.state, "away")
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testDeadlineValidationRejectsNonfinitePastAndExcessiveValues() {
        XCTAssertFalse(snapshot(breakEndsAt: .nan).isValid)
        XCTAssertFalse(snapshot(breakEndsAt: .infinity).isValid)
        XCTAssertFalse(snapshot(breakEndsAt: t0.timeIntervalSince1970 - 1).isValid)
        XCTAssertFalse(snapshot(breakEndsAt: t0.timeIntervalSince1970 + 24 * 3600 + 1).isValid)
        XCTAssertTrue(snapshot(breakEndsAt: t0.timeIntervalSince1970).isValid)
        XCTAssertTrue(snapshot(breakEndsAt: t0.timeIntervalSince1970 + 24 * 3600).isValid)
    }

    func testFrozenDurationValidationRejectsNonfiniteNonpositiveAndExcessiveValues() {
        XCTAssertFalse(snapshot(breakPausedRemaining: .nan).isValid)
        XCTAssertFalse(snapshot(breakPausedRemaining: .infinity).isValid)
        XCTAssertFalse(snapshot(breakPausedRemaining: -1).isValid)
        XCTAssertFalse(snapshot(breakPausedRemaining: 0).isValid)
        XCTAssertFalse(snapshot(breakPausedRemaining: 24 * 3600 + 1).isValid)
        XCTAssertTrue(snapshot(breakPausedRemaining: 24 * 3600).isValid)
    }

    func testRunningAndFrozenBreakFieldsAreMutuallyExclusive() {
        let invalid = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 300,
                               breakPausedRemaining: 300)

        XCTAssertFalse(invalid.isValid)
    }

    func testPausedTrackingCannotCarryARunningBreak() {
        var invalid = snapshot(breakEndsAt: t0.timeIntervalSince1970 + 300)
        invalid.isPaused = true

        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(invalid.hasActiveBreak)
    }

    func testPausedTrackingCannotCarryAFrozenBreak() {
        var invalid = snapshot(breakPausedRemaining: 180)
        invalid.isPaused = true

        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(invalid.hasActiveBreak)
    }
}
