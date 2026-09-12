import XCTest
@testable import SundialCore

final class IndicatorTests: XCTestCase {
    private let settings = Settings.default   // away after 120s, 3600s in a call

    private func ind(_ state: TimeCategory, idle: TimeInterval,
                     inCall: Bool = false, paused: Bool = false,
                     settings: Settings? = nil) -> LiveIndicator {
        Indicator.current(state: state, idleSeconds: idle, inCall: inCall,
                          isPaused: paused, settings: settings ?? self.settings)
    }

    func testWorkAtTheKeyboardPulses() {
        let i = ind(.work, idle: 1)
        XCTAssertEqual(i.liveness, .active)
        XCTAssertTrue(i.pulses)
        XCTAssertEqual(i.alpha, 1)
        XCTAssertNil(i.awayIn)
        XCTAssertNil(i.note)
    }

    /// The menu bar shows the work total, so only work may beat.
    func testOnlyWorkPulses() {
        XCTAssertFalse(ind(.personal, idle: 1).pulses)
        XCTAssertFalse(ind(.unclassified, idle: 1).pulses)
        XCTAssertEqual(ind(.personal, idle: 1).liveness, .active)
    }

    func testPausedIsItsOwnState() {
        let i = ind(.work, idle: 0, paused: true)
        XCTAssertEqual(i.liveness, .paused)
        XCTAssertFalse(i.pulses)
        XCTAssertEqual(i.note, "Paused")
    }

    func testAwayIsDormant() {
        let i = ind(.away, idle: 600)
        XCTAssertEqual(i.liveness, .dormant)
        XCTAssertFalse(i.pulses)
        XCTAssertEqual(i.alpha, 1)
    }

    /// The gap this whole thing exists for: still counted as work, but nobody
    /// has touched the machine, and the icon has to say so.
    func testQuietStopsThePulseBeforeTheVerdictChanges() {
        let i = ind(.work, idle: 60)
        XCTAssertEqual(i.liveness, .still)
        XCTAssertFalse(i.pulses)
        XCTAssertEqual(i.awayIn ?? 0, 60, accuracy: 0.001)
        XCTAssertLessThan(i.alpha, 1)
        XCTAssertGreaterThan(i.alpha, Indicator.dimmest)
        XCTAssertEqual(i.note, "Quiet for 1m — away in 1m")
    }

    func testTheFadeIsMonotonicAndBounded() {
        var last = 2.0
        for idle in stride(from: 0.0, through: 300.0, by: 5) {
            let a = ind(.work, idle: idle).alpha
            XCTAssertLessThanOrEqual(a, last + 1e-9, "alpha rose at \(idle)s")
            XCTAssertGreaterThanOrEqual(a, Indicator.dimmest - 1e-9)
            last = a
        }
        // It is at its faintest by the cutoff and stays there: the category is
        // only recomputed on a sample, so brightening in between would flash.
        XCTAssertEqual(ind(.work, idle: 119.999).alpha, Indicator.dimmest, accuracy: 0.001)
        XCTAssertEqual(ind(.work, idle: 200).liveness, .dormant)
        XCTAssertEqual(ind(.work, idle: 200).alpha, Indicator.dimmest)
        // Once the verdict does catch up, the away glyph carries the meaning.
        XCTAssertEqual(ind(.away, idle: 200).alpha, 1)
    }

    /// Sitting still in a meeting is working, so the beat carries on - only
    /// dimmer as the far longer call window runs down.
    func testACallKeepsItBeating() {
        let fresh = ind(.work, idle: 2, inCall: true)
        XCTAssertEqual(fresh.liveness, .active)
        XCTAssertTrue(fresh.pulses)
        XCTAssertEqual(fresh.note, "In a call")

        let listening = ind(.work, idle: 900, inCall: true)
        XCTAssertEqual(listening.liveness, .active)
        XCTAssertTrue(listening.pulses)
        XCTAssertLessThan(listening.alpha, 1)
        XCTAssertEqual(listening.awayIn ?? 0, 2700, accuracy: 0.001)
        XCTAssertTrue(listening.note?.hasPrefix("In a call, quiet for") ?? false)

        // Fifteen minutes of silence is nothing in a call, but would be away by
        // the ordinary threshold.
        XCTAssertEqual(ind(.work, idle: 900).liveness, .dormant)
    }

    /// A threshold shorter than the quiet grace must not invert the fade or
    /// divide by zero.
    func testVeryShortThreshold() {
        var s = Settings.default
        s.idleThreshold = 10
        XCTAssertEqual(ind(.work, idle: 1, settings: s).liveness, .active)
        let i = ind(.work, idle: 7, settings: s)
        XCTAssertEqual(i.liveness, .still)
        XCTAssertLessThan(i.alpha, 1)
        XCTAssertGreaterThanOrEqual(i.alpha, Indicator.dimmest)
    }

    func testNegativeIdleIsTreatedAsNow() {
        XCTAssertEqual(ind(.work, idle: -5).liveness, .active)
    }

    func testTheFadeRunsFullToFloorAndBack() {
        let p = Settings.default.beatPeriod
        XCTAssertEqual(Indicator.pulseAlpha(at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(Indicator.pulseAlpha(at: p / 2), Indicator.pulseFloor, accuracy: 1e-9)
        XCTAssertEqual(Indicator.pulseAlpha(at: p), 1, accuracy: 1e-9)
        for f in [0.1, 0.2, 0.35, 0.45] {
            XCTAssertEqual(Indicator.pulseAlpha(at: p * f),
                           Indicator.pulseAlpha(at: p * (1 - f)), accuracy: 1e-9,
                           "the way down should match the way back up")
        }
        // Negative time happens if the clock is read across a change.
        XCTAssertEqual(Indicator.pulseAlpha(at: -p / 2), Indicator.pulseFloor, accuracy: 1e-9)
    }

    /// The point of a straight ramp: no dwell at either end. An eased curve
    /// spends its time sitting at full and at the floor, and on a dot this
    /// small that stillness is exactly what looks sluggish.
    func testItIsAlwaysMoving() {
        let p = Settings.default.beatPeriod
        let step = p / 60
        var deltas: [Double] = []
        for i in 0..<30 {
            let a = Indicator.pulseAlpha(at: Double(i) * step)
            let b = Indicator.pulseAlpha(at: Double(i + 1) * step)
            deltas.append(abs(b - a))
        }
        let expected = (1 - Indicator.pulseFloor) / 30
        for (i, d) in deltas.enumerated() {
            XCTAssertEqual(d, expected, accuracy: expected * 0.01, "step \(i) moved differently")
        }
    }

    func testItNeverLeavesItsRange() {
        let p = Settings.default.beatPeriod
        for t in stride(from: -2 * p, through: 3 * p, by: p / 97) {
            let a = Indicator.pulseAlpha(at: t)
            XCTAssertGreaterThanOrEqual(a, Indicator.pulseFloor - 1e-9)
            XCTAssertLessThanOrEqual(a, 1 + 1e-9)
        }
    }

    func testMonotonicWithinEachHalf() {
        let p = Settings.default.beatPeriod
        var last = 2.0
        for t in stride(from: 0.0, through: p / 2, by: p / 400) {
            let a = Indicator.pulseAlpha(at: t)
            XCTAssertLessThanOrEqual(a, last + 1e-9, "brightened at \(t)")
            last = a
        }
        for t in stride(from: p / 2, through: p, by: p / 400) {
            let a = Indicator.pulseAlpha(at: t)
            XCTAssertGreaterThanOrEqual(a, last - 1e-9, "dimmed at \(t)")
            last = a
        }
    }

    /// Nonsense settings must not divide by zero or leave the icon invisible.
    func testDegenerateBeatIsStatic() {
        XCTAssertEqual(Indicator.pulseAlpha(at: 3, period: 0), 1)
        XCTAssertEqual(Indicator.pulseAlpha(at: 3, period: -2), 1)
        XCTAssertEqual(Indicator.pulseAlpha(at: 0.4, period: 2, low: 1), 1)
    }
}
