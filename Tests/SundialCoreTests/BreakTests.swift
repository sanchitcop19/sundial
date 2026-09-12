import XCTest
@testable import SundialCore

final class BreakTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private var settings: Settings {
        var s = Settings.default
        s.workBeforeBreak = 1500   // 25 min
        s.breakLength = 300        // 5 min
        return s
    }

    /// Builds a back-to-back run of segments from minute lengths.
    private func run(_ parts: [(TimeCategory, Double)]) -> [Segment] {
        var at = t0
        return parts.map { state, minutes in
            let end = at.addingTimeInterval(minutes * 60)
            defer { at = end }
            return Segment(start: at, end: end, state: state, reason: "test")
        }
    }

    private func status(_ parts: [(TimeCategory, Double)], snoozedUntil: Date? = nil,
                        inCall: Bool = false, now: Date? = nil,
                        settings: Settings? = nil) -> BreakStatus {
        let segs = run(parts)
        return Breaks.status(segments: segs, now: now ?? segs.last?.end ?? t0,
                             settings: settings ?? self.settings,
                             snoozedUntil: snoozedUntil, inCall: inCall,
                             currentState: segs.last?.state ?? .work)
    }

    func testNothingOwedBeforeTheThreshold() {
        let s = status([(.work, 20)])
        XCTAssertEqual(s.workedStraight, 20 * 60)
        XCTAssertFalse(s.owed)
        XCTAssertFalse(s.due)
        XCTAssertEqual(s.toGo, 5 * 60)
        XCTAssertNil(s.heldBack)
    }

    func testOwedOnceTheWorkAddsUp() {
        let s = status([(.work, 26)])
        XCTAssertTrue(s.owed)
        XCTAssertTrue(s.due)
        XCTAssertEqual(s.toGo, 0)
    }

    /// The point of the whole thing: a kitchen timer would have gone off after
    /// twenty-five minutes at the desk. Only fourteen of these were work.
    func testOnlyWorkCounts() {
        let s = status([(.work, 8), (.personal, 3), (.work, 6), (.away, 2), (.work, 6)])
        XCTAssertEqual(s.workedStraight, 20 * 60)
        XCTAssertFalse(s.owed)
    }

    func testAlongEnoughGapStartsTheCountAgain() {
        // 30 minutes of work, then a proper break, then 10 more.
        let s = status([(.work, 30), (.away, 6), (.work, 10)])
        XCTAssertEqual(s.workedStraight, 10 * 60)
        XCTAssertFalse(s.owed)
    }

    /// Personal time is a break too, if you were away from work long enough.
    func testPersonalTimeCanBeTheBreak() {
        let s = status([(.work, 30), (.personal, 7), (.work, 5)])
        XCTAssertEqual(s.workedStraight, 5 * 60)
    }

    /// Glancing at a message is not a break, and it is not work either.
    func testShortInterruptionsAreIgnoredNotCredited() {
        let s = status([(.work, 13), (.personal, 2), (.work, 13)])
        XCTAssertEqual(s.workedStraight, 26 * 60)
        XCTAssertTrue(s.owed)
    }

    /// Several small gaps in a row still add up to having stepped away.
    func testConsecutiveShortGapsCanReachABreak() {
        let s = status([(.work, 30), (.personal, 3), (.away, 3), (.unclassified, 1), (.work, 4)])
        XCTAssertEqual(s.workedStraight, 4 * 60)
        XCTAssertFalse(s.owed)
    }

    func testNoPromptWhileAlreadyAway() {
        let s = status([(.work, 40), (.away, 2)])
        XCTAssertTrue(s.owed, "the break is still owed")
        XCTAssertFalse(s.due, "but there is no point saying so to an empty chair")
        XCTAssertEqual(s.heldBack, "already away from the machine")
    }

    func testNoPromptDuringACall() {
        let s = status([(.work, 40)], inCall: true)
        XCTAssertTrue(s.owed)
        XCTAssertFalse(s.due)
        XCTAssertEqual(s.heldBack, "in a call")
    }

    func testSnoozeHoldsItBackUntilItExpires() {
        let segs = run([(.work, 40)])
        let now = segs.last!.end
        let snoozed = Breaks.status(segments: segs, now: now, settings: settings,
                                    snoozedUntil: now.addingTimeInterval(60))
        XCTAssertTrue(snoozed.owed)
        XCTAssertFalse(snoozed.due)
        XCTAssertEqual(snoozed.heldBack, "reminder snoozed")

        let expired = Breaks.status(segments: segs, now: now, settings: settings,
                                    snoozedUntil: now.addingTimeInterval(-1))
        XCTAssertTrue(expired.due)
        XCTAssertNil(expired.heldBack)
    }

    func testSwitchedOffSaysNothing() {
        var off = settings
        off.breakReminders = false
        let s = status([(.work, 300)], settings: off)
        XCTAssertFalse(s.owed)
        XCTAssertFalse(s.due)
        XCTAssertEqual(s.workedStraight, 0)
    }

    func testEmptyDay() {
        let s = Breaks.status(segments: [], now: t0, settings: settings)
        XCTAssertEqual(s.workedStraight, 0)
        XCTAssertFalse(s.owed)
        XCTAssertEqual(s.toGo, 1500)
    }

    /// A hand-edited zero must not make every moment overdue.
    func testZeroThresholdIsInert() {
        var broken = settings
        broken.workBeforeBreak = 0
        let s = status([(.work, 60)], settings: broken)
        XCTAssertFalse(s.owed)
    }

    /// Work before a break must not leak past it, however much of it there was.
    func testWorkBeforeABreakIsForgotten() {
        let s = status([(.work, 240), (.away, 60), (.work, 1)])
        XCTAssertEqual(s.workedStraight, 60)
        XCTAssertFalse(s.owed)
    }

    func testStoredBreakSettingsAreClamped() throws {
        func decode(_ json: String) throws -> Settings {
            try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"workBeforeBreak": 0}"#).workBeforeBreak, 60)
        XCTAssertEqual(try decode(#"{"breakLength": -5}"#).breakLength, 60)
        XCTAssertEqual(try decode("{}").workBeforeBreak, Settings.default.workBeforeBreak)
        XCTAssertTrue(try decode("{}").breakReminders)
    }
}
