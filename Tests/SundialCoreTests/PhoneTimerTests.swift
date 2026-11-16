import XCTest
@testable import SundialCore

final class PhoneTimerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var timer: PhoneTimer { PhoneTimer(start: t0, label: "Calls", outcome: .work) }

    func testElapsedIsMeasuredFromTheStart() {
        XCTAssertEqual(timer.elapsed(at: t0 + 90), 90)
    }

    func testElapsedNeverGoesNegativeIfTheClockMovesBack() {
        XCTAssertEqual(timer.elapsed(at: t0 - 30), 0)
    }

    func testAMinuteOrMoreIsSent() {
        XCTAssertEqual(timer.finish(at: t0 + 1800), .send(1800))
        XCTAssertEqual(timer.finish(at: t0 + 60), .send(60))
    }

    func testUnderAMinuteIsTooShort() {
        XCTAssertEqual(timer.finish(at: t0 + 59), .tooShort)
        XCTAssertEqual(timer.finish(at: t0 - 5), .tooShort)
    }

    func testOverADayIsTooLong() {
        XCTAssertEqual(timer.finish(at: t0 + Manual.maxLength), .send(Manual.maxLength))
        XCTAssertEqual(timer.finish(at: t0 + Manual.maxLength + 1), .tooLong)
    }

    /// It is stored while running, so it has to survive a round trip.
    func testSurvivesEncoding() throws {
        let back = try JSONDecoder().decode(PhoneTimer.self, from: JSONEncoder().encode(timer))
        XCTAssertEqual(back, timer)
    }

    func testStopwatchReading() {
        XCTAssertEqual(Format.clockDuration(7), "0:07")
        XCTAssertEqual(Format.clockDuration(723), "12:03")
        XCTAssertEqual(Format.clockDuration(3723), "1:02:03")
        XCTAssertEqual(Format.clockDuration(-4), "0:00")
    }
}
