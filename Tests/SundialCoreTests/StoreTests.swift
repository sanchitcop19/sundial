import XCTest
import Compression
@testable import SundialCore

final class StoreTests: XCTestCase {
    var root: URL!
    var store: Store!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = Store(root: root)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func snap(_ h: String = "a.com") -> Snapshot {
        Snapshot(bundleId: "b", appName: "App", host: h, urlPath: "/")
    }

    func testObservationRoundTrip() {
        let now = Date()
        store.append(ObservationSpan(start: now, end: now + 60, snapshot: snap()))
        let d = store.load(day: Format.day(now))
        XCTAssertEqual(d.observations.count, 1)
        XCTAssertEqual(d.observations[0].snapshot.host, "a.com")
        XCTAssertEqual(d.observations[0].duration, 60, accuracy: 0.01)
    }

    func testZeroLengthObservationsAreDropped() {
        let now = Date()
        store.append(ObservationSpan(start: now, end: now, snapshot: snap()))
        XCTAssertTrue(store.load(day: Format.day(now)).observations.isEmpty)
    }

    func testSpanCrossingMidnightIsSplit() {
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = 2; c.hour = 23; c.minute = 40
        let start = Calendar.current.date(from: c)!
        let pieces = Store.splitAcrossDays(ObservationSpan(start: start, end: start + 3600, snapshot: snap()))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].duration, 1200, accuracy: 1)
        XCTAssertEqual(pieces[1].duration, 2400, accuracy: 1)
        XCTAssertNotEqual(Format.day(pieces[0].start), Format.day(pieces[1].start))
    }

    /// Times are stored as readable ISO-8601 with milliseconds. That is three
    /// orders of magnitude finer than the sampling interval, so equality is
    /// asserted to the millisecond rather than to the bit.
    func testPresenceRoundTripToMillisecondPrecision() {
        let now = Date()
        var p = PresenceLog(input: [Span(now, now + 10)], call: [Span(now, now + 5)])
        p.normalise()
        store.savePresence(p, day: Format.day(now))
        let back = store.load(day: Format.day(now)).presence
        XCTAssertEqual(back.input.count, 1)
        XCTAssertEqual(back.input[0].start.timeIntervalSince1970,
                       p.input[0].start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.input[0].duration, 10, accuracy: 0.001)
        XCTAssertEqual(back.call[0].duration, 5, accuracy: 0.001)
    }

    func testObservationTimesSurviveToMillisecond() {
        let now = Date()
        store.append(ObservationSpan(start: now, end: now + 61.25, snapshot: snap()))
        let back = store.load(day: Format.day(now)).observations[0]
        XCTAssertEqual(back.duration, 61.25, accuracy: 0.001)
        XCTAssertEqual(back.start.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRulesAndSettingsRoundTrip() {
        let set = RuleSet(rules: [Rule(name: "a", conditions: [Condition(.host, .equals, "x")], outcome: .work)])
        store.save(set)
        let back = store.loadRules()
        XCTAssertEqual(back?.rules.count, 1)
        XCTAssertEqual(back?.rules[0].id, set.rules[0].id)
        XCTAssertEqual(back?.rules[0].name, "a")
        XCTAssertEqual(back?.rules[0].conditions, set.rules[0].conditions)
        XCTAssertEqual(back?.rules[0].outcome, .work)
        XCTAssertNil(Store(root: root.appendingPathComponent("empty")).loadRules(),
                     "a fresh install has no rules, which is how setup is triggered")

        var s = Settings.default
        s.idleThreshold = 42
        store.save(s)
        XCTAssertEqual(store.loadSettings().idleThreshold, 42)
    }

    func testCrashRecoveryCommitsTheOpenSpan() {
        let now = Date()
        store.saveOpen(ObservationSpan(start: now, end: now + 30, snapshot: snap()))
        XCTAssertEqual(store.recoverOpen()?.duration, 30)
        XCTAssertEqual(store.load(day: Format.day(now)).observations.count, 1)
        XCTAssertNil(store.recoverOpen(), "recovery is idempotent")
    }

    func testAvailableDaysListsWrittenFiles() {
        let now = Date()
        store.append(ObservationSpan(start: now, end: now + 10, snapshot: snap()))
        XCTAssertEqual(store.availableDays(), [Format.day(now)])
    }

    // MARK: daily rollup

    func testDailySummaryFromSegments() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let segs = [
            Segment(start: t0, end: t0 + 3600, state: .work, reason: ""),
            Segment(start: t0 + 3600, end: t0 + 3900, state: .away, reason: ""),
            Segment(start: t0 + 3900, end: t0 + 4200, state: .personal, reason: ""),
        ]
        let s = DailySummary.compute(day: "2026-09-02", segments: segs, now: t0)
        XCTAssertEqual(s.work, 3600)
        XCTAssertEqual(s.away, 300)
        XCTAssertEqual(s.firstActivity, t0)
        XCTAssertEqual(s.lastActivity, t0 + 4200)
        XCTAssertTrue(s.csvRow.contains("1.000"), "decimal hours for charting")
    }

    func testCSVRoundTripAndHeaderRejection() {
        let s = DailySummary(date: "2026-09-02", work: 60, updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(DailySummary.parse(row: s.csvRow)?.work, 60)
        XCTAssertNil(DailySummary.parse(row: DailySummary.csvHeader))
        XCTAssertNil(DailySummary.parse(row: ""))
    }

    func testUpsertReplacesOneDayAndKeepsOrder() {
        store.upsertDaily(DailySummary(date: "2026-09-03", work: 10))
        store.upsertDaily(DailySummary(date: "2026-09-01", work: 20))
        store.upsertDaily(DailySummary(date: "2026-09-03", work: 999))
        let rows = store.loadDaily()
        XCTAssertEqual(rows.map(\.date), ["2026-09-01", "2026-09-03"])
        XCTAssertEqual(rows.last?.work, 999)
    }

    /// Rebuilding is how a rule fix reaches days already written.
    func testRebuildRecomputesHistoryUnderNewRules() {
        let now = Date()
        let day = Format.day(now)
        store.append(ObservationSpan(start: now, end: now + 600, snapshot: snap("acme.com")))
        var p = PresenceLog(input: stride(from: 0.0, through: 600.0, by: 5).map {
            Span(now.addingTimeInterval($0), now.addingTimeInterval($0)) })
        p.normalise()
        store.savePresence(p, day: day)

        let none = store.rebuildDaily(rules: RuleSet(), settings: .default)
        XCTAssertEqual(none.first?.work ?? -1, 0, accuracy: 1)
        XCTAssertGreaterThan(none.first?.unclassified ?? 0, 500)

        let rules = RuleSet(rules: [Rule(name: "acme",
                                         conditions: [Condition(.host, .hostOrSubdomain, "acme.com")],
                                         outcome: .work)])
        let after = store.rebuildDaily(rules: rules, settings: .default)
        XCTAssertGreaterThan(after.first?.work ?? 0, 500)
        XCTAssertEqual(store.loadDaily().first?.work ?? 0, after.first?.work ?? -1, accuracy: 1)
    }
}

final class CloudMirrorTests: XCTestCase {
    var home: URL!
    var store: Store!

    override func setUp() {
        super.setUp()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        home = tmp.appendingPathComponent("home")
        store = Store(root: tmp.appendingPathComponent("data"))
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent()); super.tearDown()
    }

    @discardableResult func mk(_ rel: String) -> URL {
        let u = home.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testResolvesKnownServicesOnlyWhenPresent() {
        XCTAssertNil(CloudMirror.resolve("icloud", home: home))
        mk("Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertEqual(CloudMirror.resolve("icloud", home: home)?.lastPathComponent, "Sundial")
        mk("Library/CloudStorage/GoogleDrive-me@x.com/My Drive")
        XCTAssertTrue(CloudMirror.resolve("gdrive", home: home)!.path.contains("My Drive"))
        mk("Library/CloudStorage/OneDrive-Personal")
        XCTAssertNotNil(CloudMirror.resolve("onedrive", home: home))
        XCTAssertEqual(Set(CloudMirror.available(home: home)), ["icloud", "gdrive", "onedrive"])
    }

    func testLiteralPathAndTildeExpansion() {
        XCTAssertEqual(CloudMirror.resolve("/tmp/x", home: home)?.path, "/tmp/x")
        XCTAssertFalse(CloudMirror.resolve("~/b", home: home)!.path.contains("~"))
    }

    func testMirrorCopiesCSVAndRules() {
        mk("Library/Mobile Documents/com~apple~CloudDocs")
        store.upsertDaily(DailySummary(date: "2026-09-02", work: 60))
        store.save(RuleSet())
        let r = store.mirror(to: ["icloud"], includeObservations: false, day: "2026-09-02", home: home)
        XCTAssertEqual(r.errors, [])
        let dir = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Sundial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("daily.csv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rules.json").path))
    }

    func testMissingDestinationIsReportedNotFatal() {
        let r = store.mirror(to: ["dropbox"], includeObservations: false, day: "x", home: home)
        XCTAssertTrue(r.destinations.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.errors[0].contains("Dropbox"))
    }
}

/// The rename from Escapement has to carry the existing record over, and must
/// not be able to destroy one on the way.
final class LegacyRootMigrationTests: XCTestCase {
    var base: URL!
    var legacy: URL!
    var current: URL!

    override func setUp() {
        super.setUp()
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        legacy = base.appendingPathComponent("Escapement")
        current = base.appendingPathComponent("Sundial")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base); super.tearDown() }

    private func write(_ dir: URL, _ contents: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? contents.write(to: dir.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
    }

    private func read(_ dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("rules.json"), encoding: .utf8)
    }

    func testTheOldRecordIsMovedUnderTheNewName() {
        write(legacy, "old rules")
        Store.migrateLegacyRoot(legacy, to: current)
        XCTAssertEqual(read(current), "old rules")
        XCTAssertNil(read(legacy), "the record should be moved out, not copied")
    }

    func testAnExistingRecordIsNeverOverwritten() {
        write(legacy, "old rules")
        write(current, "live rules")
        Store.migrateLegacyRoot(legacy, to: current)
        XCTAssertEqual(read(current), "live rules")
        XCTAssertEqual(read(legacy), "old rules", "the old folder is left alone, not merged")
    }

    func testNothingToMigrateIsHarmless() {
        Store.migrateLegacyRoot(legacy, to: current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    func testAStoreAtAnExplicitRootDoesNotMigrate() {
        write(legacy, "old rules")
        _ = Store(root: current)
        XCTAssertNil(read(current), "an explicit root is not the default one")
        XCTAssertEqual(read(legacy), "old rules")
    }
}

/// The launch path takes a lock inside the record folder, which creates that
/// folder. Migration has to survive finding it already there.
final class LockCreatedRootMigrationTests: XCTestCase {
    var base: URL!
    var legacy: URL!
    var current: URL!

    override func setUp() {
        super.setUp()
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        legacy = base.appendingPathComponent("Escapement")
        current = base.appendingPathComponent("Sundial")
        let days = legacy.appendingPathComponent("days")
        try? FileManager.default.createDirectory(at: days, withIntermediateDirectories: true)
        try? "rules".write(to: legacy.appendingPathComponent("rules.json"),
                           atomically: true, encoding: .utf8)
        try? "obs".write(to: days.appendingPathComponent("observations-2026-09-04.jsonl"),
                         atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base); super.tearDown() }

    private func makeLock() {
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try? "123".write(to: current.appendingPathComponent("tracker.lock"),
                         atomically: true, encoding: .utf8)
    }

    func testAFolderHoldingOnlyALockDoesNotBlockTheMove() {
        makeLock()
        Store.migrateLegacyRoot(legacy, to: current)
        XCTAssertEqual(try? String(contentsOf: current.appendingPathComponent("rules.json"),
                                   encoding: .utf8), "rules")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("days/observations-2026-09-04.jsonl").path),
            "the day files have to come across too")
    }

    func testTheLockItselfIsNeverCarriedOver() {
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try? "stale".write(to: legacy.appendingPathComponent("tracker.lock"),
                           atomically: true, encoding: .utf8)
        try? "live".write(to: current.appendingPathComponent("tracker.lock"),
                          atomically: true, encoding: .utf8)
        Store.migrateLegacyRoot(legacy, to: current)
        XCTAssertEqual(try? String(contentsOf: current.appendingPathComponent("tracker.lock"),
                                   encoding: .utf8), "live",
                       "the running process's lock must survive")
    }

    func testARealRecordAtTheDestinationStillBlocks() {
        makeLock()
        try? "live rules".write(to: current.appendingPathComponent("rules.json"),
                                atomically: true, encoding: .utf8)
        Store.migrateLegacyRoot(legacy, to: current)
        XCTAssertEqual(try? String(contentsOf: current.appendingPathComponent("rules.json"),
                                   encoding: .utf8), "live rules")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacy.appendingPathComponent("rules.json").path),
            "the old record is left where it is")
    }
}
