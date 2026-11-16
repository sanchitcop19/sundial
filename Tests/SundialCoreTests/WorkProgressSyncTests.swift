import XCTest
@testable import SundialCore

final class WorkProgressSyncTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func snapshot() -> WorkProgressSnapshot {
        WorkProgressSnapshot(day: "2026-09-15", timeZoneIdentifier: "UTC",
                             updatedAt: ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!.timeIntervalSince1970,
                             worked: 4 * 3600, target: 8 * 3600,
                             weeklyWorked: 12 * 3600, weeklyTarget: 40 * 3600,
                             state: "away", isPaused: false)
    }

    private var file: URL { folder.appendingPathComponent(WorkProgressSnapshot.fileName) }

    private func readSummary() throws -> WorkProgressSnapshot {
        try JSONDecoder().decode(WorkProgressSnapshot.self, from: Data(contentsOf: file))
    }

    func testFirstSnapshotPublishesImmediately() {
        XCTAssertTrue(WorkProgressSync.shouldPublish(snapshot(), replacing: nil))
    }

    func testWorkingTotalsContinuePublishingEveryMinute() {
        var previous = snapshot()
        previous.state = "work"
        var current = previous
        current.updatedAt += 60
        current.worked += 60
        current.weeklyWorked! += 60
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testUnchangedTotalsWaitThreeMinutesBetweenHeartbeats() {
        let previous = snapshot()
        var current = previous
        current.updatedAt += 60
        XCTAssertFalse(WorkProgressSync.shouldPublish(current, replacing: previous))
        current.updatedAt += 60
        XCTAssertFalse(WorkProgressSync.shouldPublish(current, replacing: previous))
        current.updatedAt += 60
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testHeartbeatRefreshesBeforeFiveMinuteStaleness() {
        let previous = snapshot()
        var heartbeat = previous
        heartbeat.updatedAt += WorkProgressSync.heartbeatInterval
        XCTAssertFalse(previous.isStale(at: Date(timeIntervalSince1970: heartbeat.updatedAt)))
        XCTAssertTrue(WorkProgressSync.shouldPublish(heartbeat, replacing: previous))
        XCTAssertEqual(heartbeat.staleDate.timeIntervalSince1970, previous.updatedAt + 480)
        XCTAssertFalse(heartbeat.isStale(at: Date(timeIntervalSince1970: previous.updatedAt + 360)))
    }

    func testResumedWorkPublishesBeforeTotalsIncrease() {
        let previous = snapshot()
        var current = previous
        current.updatedAt += 1
        current.state = "work"
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testPausedStatePublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.isPaused = true
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testPersonalStatePublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.state = "personal"
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testNewDayPublishesWithoutWaitingForHeartbeat() {
        var previous = snapshot()
        previous.updatedAt = ISO8601DateFormatter().date(from: "2026-09-15T23:59:30Z")!.timeIntervalSince1970
        var current = previous
        current.updatedAt += 60
        current.day = "2026-09-16"
        XCTAssertTrue(current.isValid)
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testTimeZoneChangePublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.timeZoneIdentifier = "Europe/London"
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testDailyTargetChangePublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.target += 3600
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testWeeklyWorkCorrectionPublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.weeklyWorked! -= 3600
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testWeeklyTargetChangePublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.weeklyTarget! += 3600
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testAutomaticActivityEndChangePublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.automaticActivityEnd = current.updatedAt + 3600
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testClockMovingBackwardsPublishesImmediately() {
        let previous = snapshot()
        var current = previous
        current.updatedAt -= 1
        XCTAssertTrue(WorkProgressSync.shouldPublish(current, replacing: previous))
    }

    func testSkippedWritePreservesFileContentsModificationTimeAndSnapshotTime() throws {
        let previous = snapshot()
        XCTAssertTrue(try WorkProgressSync.writeSummary(previous, to: file))
        let originalData = try Data(contentsOf: file)
        let modificationDate = Date(timeIntervalSince1970: previous.updatedAt)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path)
        var current = previous
        current.updatedAt += 60

        XCTAssertFalse(try WorkProgressSync.writeSummary(current, to: file))
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       modificationDate)
        XCTAssertEqual(try readSummary(), previous)
    }

    func testNewFolderReceivesCurrentSummaryImmediately() throws {
        let current = snapshot()
        XCTAssertTrue(try WorkProgressSync.writeSummary(current, to: file))
        XCTAssertEqual(try readSummary(), current)
    }

    func testDeletedSummaryIsRecreatedBeforeHeartbeat() throws {
        let current = snapshot()
        try WorkProgressSync.writeSummary(current, to: file)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try WorkProgressSync.writeSummary(current, to: file))
        XCTAssertEqual(try readSummary(), current)
    }

    func testCorruptSummaryIsReplacedBeforeHeartbeat() throws {
        let current = snapshot()
        try WorkProgressSync.writeSummary(current, to: file)
        try Data("invalid json".utf8).write(to: file)
        XCTAssertTrue(try WorkProgressSync.writeSummary(current, to: file))
        XCTAssertEqual(try readSummary(), current)
    }

    func testInvalidDecodedSummaryIsReplacedBeforeHeartbeat() throws {
        var invalid = snapshot()
        invalid.day = "2026-09-14"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(invalid).write(to: file)
        XCTAssertTrue(try WorkProgressSync.writeSummary(snapshot(), to: file))
        XCTAssertEqual(try readSummary(), snapshot())
    }

    func testOversizedSummaryIsReplacedBeforeHeartbeat() throws {
        let current = snapshot()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paddedJSON = try JSONEncoder().encode(current) + Data(repeating: 32, count: 8192)
        try paddedJSON.write(to: file)
        XCTAssertTrue(try WorkProgressSync.writeSummary(current, to: file))
        XCTAssertEqual(try readSummary(), current)
    }

    func testFailedWriteThrowsAndCanBeRetried() throws {
        try Data("blocks parent directory".utf8).write(to: folder)
        XCTAssertThrowsError(try WorkProgressSync.writeSummary(snapshot(), to: file))
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(try WorkProgressSync.writeSummary(snapshot(), to: file))
        XCTAssertEqual(try readSummary(), snapshot())
    }
}
