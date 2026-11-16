import XCTest
@testable import SundialCore

final class PhoneDeliveryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func entry(_ name: String, _ text: String = "5 min of work", at: Date? = nil) -> PhoneDelivery {
        PhoneDelivery(fileName: name, description: text, queuedAt: at ?? t0)
    }

    func testFileStillInInboxIsWaitingAndQuotesTheMacInterval() {
        let r = PhoneDeliveries.resolve([entry("a")], present: ["a"], now: t0 + 30)
        XCTAssertEqual(r.remaining, [entry("a")])
        guard case .waiting(let message) = r.state else { return XCTFail("\(String(describing: r.state))") }
        XCTAssertTrue(message.contains("5 min of work"))
        XCTAssertTrue(message.contains("5 minutes"))
    }

    func testFileTakenByTheMacIsDelivered() {
        let r = PhoneDeliveries.resolve([entry("a")], present: [], now: t0 + 30)
        XCTAssertTrue(r.remaining.isEmpty)
        XCTAssertEqual(r.state, .delivered("Added 5 min of work to your Mac."))
    }

    func testLongWaitIsReportedAsFailureButStaysTracked() {
        let r = PhoneDeliveries.resolve([entry("a")], present: ["a"],
                                        now: t0 + PhoneDeliveries.stallAfter)
        XCTAssertEqual(r.remaining.count, 1, "it may still arrive, so keep watching")
        guard case .stalled(let message) = r.state else { return XCTFail("\(String(describing: r.state))") }
        XCTAssertTrue(message.contains("10 minutes"))
    }

    func testJustUnderTheLimitIsStillWaiting() {
        let r = PhoneDeliveries.resolve([entry("a")], present: ["a"],
                                        now: t0 + PhoneDeliveries.stallAfter - 1)
        guard case .waiting = r.state else { return XCTFail("\(String(describing: r.state))") }
    }

    /// A newer entry must not hide that an older one is stuck.
    func testStuckEntryWinsOverFreshOne() {
        let old = entry("old", at: t0), fresh = entry("new", "1 hr of work", at: t0 + 590)
        let r = PhoneDeliveries.resolve([old, fresh], present: ["old", "new"],
                                        now: t0 + PhoneDeliveries.stallAfter)
        guard case .stalled(let message) = r.state else { return XCTFail("\(String(describing: r.state))") }
        XCTAssertTrue(message.contains("2 entries"))
    }

    func testDeliveredEntryIsDroppedWhileAnotherStillWaits() {
        let a = entry("a"), b = entry("b", "1 hr of work")
        let r = PhoneDeliveries.resolve([a, b], present: ["b"], now: t0 + 10)
        XCTAssertEqual(r.remaining, [b])
        guard case .waiting(let message) = r.state else { return XCTFail("\(String(describing: r.state))") }
        XCTAssertTrue(message.contains("1 hr of work"))
    }

    func testSeveralDeliveredAreCounted() {
        let r = PhoneDeliveries.resolve([entry("a"), entry("b")], present: [], now: t0)
        XCTAssertEqual(r.state, .delivered("Added 2 entries to your Mac."))
    }

    func testNothingPendingSaysNothing() {
        let r = PhoneDeliveries.resolve([], present: ["x"], now: t0)
        XCTAssertTrue(r.remaining.isEmpty)
        XCTAssertNil(r.state)
    }

    func testDeliveryRoundTripsThroughJSON() throws {
        let e = entry("a")
        let back = try JSONDecoder().decode(PhoneDelivery.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
    }
}
