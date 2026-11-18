import XCTest
@testable import SundialCore

/// Regression: pressing a button twice while its work ran started the work
/// twice. A running job must refuse to start again until it ends.
final class BusyTrackerTests: XCTestCase {
    func testSecondPressWhileRunningIsRejected() {
        var busy = BusyTracker()
        XCTAssertTrue(busy.begin("backup"))
        XCTAssertTrue(busy.isBusy("backup"))
        XCTAssertFalse(busy.begin("backup"), "a second press must not start the job again")
    }

    func testJobCanRunAgainOnceFinished() {
        var busy = BusyTracker()
        busy.begin("backup")
        busy.end("backup")
        XCTAssertFalse(busy.isBusy("backup"))
        XCTAssertTrue(busy.isIdle)
        XCTAssertTrue(busy.begin("backup"))
    }

    func testUnrelatedJobsDoNotBlockEachOther() {
        var busy = BusyTracker()
        busy.begin("backup")
        XCTAssertTrue(busy.begin("rebuild"))
        busy.end("backup")
        XCTAssertTrue(busy.isBusy("rebuild"))
        XCTAssertFalse(busy.isIdle)
    }
}
