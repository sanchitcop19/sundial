import XCTest
@testable import SundialCore

final class DateParsingTests: XCTestCase {
    /// The hand parser must agree with the formatter to the bit, or segment
    /// boundaries read back from disk would drift from those just written.
    func testAgreesExactlyWithTheFormatter() {
        var rng = SystemRandomNumberGenerator()
        let samples = (0..<5000).map { _ in
            Date(timeIntervalSince1970: Double(Int.random(in: 0...4_102_444_800_000, using: &rng)) / 1000)
        } + [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 951_782_400.999),
             Date(timeIntervalSince1970: 4_107_542_399.5)]
        for date in samples {
            let text = Store.dateFormatter.string(from: date)
            let fast = Store.parseWrittenDate(text)
            XCTAssertNotNil(fast, text)
            XCTAssertEqual(fast?.timeIntervalSinceReferenceDate.bitPattern,
                           Store.dateFormatter.date(from: text)?.timeIntervalSinceReferenceDate.bitPattern, text)
        }
    }

    func testLeapDaysAndBridgedStrings() {
        XCTAssertNotNil(Store.parseWrittenDate("2024-02-29T12:00:00.000Z"))
        XCTAssertNotNil(Store.parseWrittenDate("2000-02-29T12:00:00.000Z"))
        XCTAssertNil(Store.parseWrittenDate("2026-02-29T12:00:00.000Z"))
        XCTAssertNil(Store.parseWrittenDate("1900-02-29T12:00:00.000Z"))
        let bridged = NSString(string: "2026-10-02T22:40:47.141Z") as String
        XCTAssertEqual(Store.parseWrittenDate(bridged),
                       Store.dateFormatter.date(from: "2026-10-02T22:40:47.141Z"))
    }

    func testOtherShapesFallBackToTheFormatters() {
        for text in ["2026-10-02T22:40:47Z", "2026-10-02T22:40:47.141+02:00",
                     "2026-13-02T22:40:47.141Z", "2026-10-02T24:40:47.141Z",
                     "2026-10-02T22:60:47.141Z", "2026-10-02T22:40:60.141Z",
                     "2026-10-0xT22:40:47.141Z", "2026-10-00T22:40:47.141Z"] {
            XCTAssertNil(Store.parseWrittenDate(text), text)
        }
        XCTAssertEqual(Store.parseDate("2026-10-02T22:40:47Z"),
                       Date(timeIntervalSince1970: 1_790_980_847))
        XCTAssertEqual(Store.parseDate("2026-10-02T22:40:47.141+02:00"),
                       Date(timeIntervalSince1970: 1_790_973_647.141))
        XCTAssertNil(Store.parseDate("yesterday"))
    }
}
