import XCTest
@testable import SundialCore

final class ModelTests: XCTestCase {
    func testCategoryPresentation() {
        XCTAssertEqual(TimeCategory.work.label, "Work")
        XCTAssertEqual(TimeCategory.personal.label, "Personal")
        XCTAssertEqual(TimeCategory.away.label, "Away")
        XCTAssertEqual(TimeCategory.unclassified.label, "Unclassified")
        let glyphs = TimeCategory.allCases.map(\.glyph)
        XCTAssertEqual(Set(glyphs).count, glyphs.count, "each state must look different")
    }

    func testOutcomeMapsToCategory() {
        XCTAssertEqual(Outcome.work.state, .work)
        XCTAssertEqual(Outcome.personal.state, .personal)
        XCTAssertEqual(Outcome.personal.label, "Personal")
    }

    func testSegmentDurationNeverNegative() {
        let now = Date()
        XCTAssertEqual(Segment(start: now, end: now - 50, state: .away, reason: "x").duration, 0)
    }

    func testObservationSpanDuration() {
        let now = Date()
        let s = ObservationSpan(start: now, end: now + 30,
                                snapshot: Snapshot(bundleId: "b", appName: "A"))
        XCTAssertEqual(s.duration, 30, accuracy: 0.001)
    }

    func testSnapshotSummaryFallbackChain() {
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "Code", projectName: "api").summary,
                       "Code · api")
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "App", windowTitle: "Doc").summary,
                       "App · Doc")
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "Bare").summary, "Bare")
    }

    func testSnapshotGroupingForWebAndProject() {
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "C", host: "a.com",
                                browserProfile: "Work").groupingKey, "web:a.com@Work")
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "C", projectPath: "/p").groupingKey,
                       "project:/p")
    }

    func testDayDataEmptiness() {
        XCTAssertTrue(DayData(day: "2026-01-01").isEmpty)
        XCTAssertFalse(DayData(day: "2026-01-01",
                               presence: PresenceLog(input: [Span(Date(), Date())])).isEmpty)
    }

    func testFormatClockAndDay() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.clock(d).count, 5)
        XCTAssertEqual(Format.clockSeconds(d).count, 8)
        XCTAssertEqual(Format.day(d).count, 10)
    }

    func testPresenceNormaliseIsIdempotent() {
        let now = Date()
        var p = PresenceLog(input: [Span(now, now + 5), Span(now + 6, now + 9)])
        p.normalise(tolerance: 2)
        let once = p
        p.normalise(tolerance: 2)
        XCTAssertEqual(p, once)
    }

    func testMergeOfEmptyIsEmpty() {
        XCTAssertTrue(PresenceLog.merge([], tolerance: 5).isEmpty)
    }

    func testTotalsTrackedExcludesAway() {
        let now = Date()
        let t = Totals.compute([
            Segment(start: now, end: now + 10, state: .work, reason: ""),
            Segment(start: now + 10, end: now + 20, state: .away, reason: ""),
            Segment(start: now + 20, end: now + 25, state: .unclassified, reason: ""),
        ])
        XCTAssertEqual(t.tracked, 15, accuracy: 0.01)
        XCTAssertEqual(t.away, 10, accuracy: 0.01)
    }

    func testReviewBuildIgnoresDecidedTime() {
        let now = Date()
        XCTAssertTrue(ReviewItem.build(from: [
            Segment(start: now, end: now + 10, state: .work, reason: "")]).isEmpty)
    }
}

final class StoreEdgeTests: XCTestCase {
    var root: URL!
    var store: Store!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = Store(root: root)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testSaveOpenNilClearsRecovery() {
        let now = Date()
        store.saveOpen(ObservationSpan(start: now, end: now + 10,
                                       snapshot: Snapshot(bundleId: "b", appName: "A")))
        store.saveOpen(nil)
        XCTAssertNil(store.recoverOpen())
    }

    func testSpanWithinOneDayIsNotSplit() {
        let now = Date()
        XCTAssertEqual(Store.splitAcrossDays(
            ObservationSpan(start: now, end: now + 60,
                            snapshot: Snapshot(bundleId: "b", appName: "A"))).count, 1)
    }

    func testLoadingAnUnknownDayIsEmptyNotAnError() {
        XCTAssertTrue(store.load(day: "1999-01-01").isEmpty)
        XCTAssertTrue(store.availableDays().isEmpty)
        XCTAssertTrue(store.loadDaily().isEmpty)
    }

    func testRebuildOnEmptyStoreWritesJustTheHeader() {
        XCTAssertTrue(store.rebuildDaily(rules: RuleSet(), settings: .default).isEmpty)
        let text = try! String(contentsOf: store.dailyCSVURL, encoding: .utf8)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), DailySummary.csvHeader)
    }

    func testDailySummaryWithNoActivityHasNoSpan() {
        let s = DailySummary.compute(day: "2026-01-01", segments: [
            Segment(start: Date(), end: Date() + 10, state: .away, reason: "")])
        XCTAssertNil(s.firstActivity)
        XCTAssertEqual(s.work, 0)
    }

    func testMultipleDaysAreListedInOrder() {
        let cal = Calendar.current
        let now = Date()
        for offset in [-2, -1, 0] {
            let d = cal.date(byAdding: .day, value: offset, to: now)!
            store.append(ObservationSpan(start: d, end: d + 30,
                                         snapshot: Snapshot(bundleId: "b", appName: "A")))
        }
        let days = store.availableDays()
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days, days.sorted())
    }
}

/// The address bar is the fast path for browser URLs, so what counts as an
/// address has to be exact: a half-typed search must never become a host.
final class AddressBarTests: XCTestCase {
    // Mirrors Signals.normaliseAddressBar, which lives in the app target.
    func normalise(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2048, !t.contains(" ") else { return nil }
        if t.contains("://") {
            guard let c = URLComponents(string: t), let h = c.host, !h.isEmpty else { return nil }
            return t
        }
        let head = t.split(separator: "/").first.map(String.init) ?? t
        guard head == "localhost" || head.hasPrefix("localhost:")
                || (head.contains(".") && !head.hasPrefix(".") && !head.hasSuffix(".")) else { return nil }
        guard let c = URLComponents(string: "https://" + t), let h = c.host, !h.isEmpty else { return nil }
        return "https://" + t
    }

    func testSchemelessAddressesGetHttps() {
        XCTAssertEqual(normalise("www.amazon.com/s?k=earplugs"),
                       "https://www.amazon.com/s?k=earplugs")
        XCTAssertEqual(normalise("github.com/acme"), "https://github.com/acme")
    }

    func testFullURLsPassThrough() {
        XCTAssertEqual(normalise("http://localhost:4300/home"), "http://localhost:4300/home")
        XCTAssertEqual(normalise("https://acme.com/"), "https://acme.com/")
    }

    func testTypedSearchesAreRejected() {
        XCTAssertNil(normalise("loop earplugs"))
        XCTAssertNil(normalise("earplugs"))
        XCTAssertNil(normalise(""))
        XCTAssertNil(normalise("   "))
    }

    func testMalformedHostsAreRejected() {
        XCTAssertNil(normalise(".com"))
        XCTAssertNil(normalise("acme."))
    }

    func testHostParsesOutForRuleMatching() throws {
        let url = try XCTUnwrap(normalise("www.amazon.com/s?k=earplugs"))
        let comps = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(comps.host, "www.amazon.com")
        let snap = Snapshot(bundleId: "b", appName: "Zen", url: url,
                            host: comps.host, urlPath: comps.path)
        XCTAssertTrue(Condition(.host, .hostOrSubdomain, "amazon.com").matches(snap))
    }
}

/// Time captured before Accessibility was granted is a distinct situation: the
/// app was visible but nothing inside its window was, so no rule can ever place
/// it. It must be explained, not offered up as ordinary unclassified time.
final class BlindCaptureTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func typing(_ a: TimeInterval, _ b: TimeInterval) -> [Span] {
        stride(from: a, through: b, by: 5).map { Span(at($0), at($0)) }
    }

    func testBlindSnapshotsGroupApartFromRealOnes() {
        let blind = Snapshot(bundleId: "notion.id", appName: "Notion", detailAvailable: false)
        let seen = Snapshot(bundleId: "notion.id", appName: "Notion", workspace: "Acme")
        XCTAssertEqual(blind.groupingKey, "nodetail:notion.id")
        XCTAssertNotEqual(blind.groupingKey, seen.groupingKey)
    }

    func testReasonNamesThePermission() {
        let segs = Classifier(rules: RuleSet()).classify(
            observations: [ObservationSpan(start: at(0), end: at(120),
                snapshot: Snapshot(bundleId: "notion.id", appName: "Notion",
                                   detailAvailable: false))],
            presence: PresenceLog(input: typing(0, 120)))
        let s = try? XCTUnwrap(segs.first { $0.state == .unclassified })
        XCTAssertTrue(s?.reason.contains("Accessibility") ?? false)
    }

    func testBlindItemsAreNotActionable() {
        let segs = Classifier(rules: RuleSet()).classify(
            observations: [
                ObservationSpan(start: at(0), end: at(60),
                    snapshot: Snapshot(bundleId: "notion.id", appName: "Notion",
                                       detailAvailable: false)),
                ObservationSpan(start: at(60), end: at(200),
                    snapshot: Snapshot(bundleId: "notion.id", appName: "Notion",
                                       workspace: "Personal")),
            ],
            presence: PresenceLog(input: typing(0, 200)))
        let review = ReviewItem.build(from: segs)
        XCTAssertEqual(review.count, 2)
        XCTAssertEqual(review.filter(\.isActionable).count, 1)
        XCTAssertEqual(review.first(where: { !$0.isActionable })?.snapshot.appName, "Notion")
    }

    /// A workspace rule cannot match a stretch where no workspace was captured,
    /// which is exactly why it stayed unclassified.
    func testWorkspaceRuleCannotMatchABlindCapture() {
        let rules = RuleSet(rules: [Rule(name: "work Notion",
            conditions: [Condition(.bundleId, .equals, "notion.id"),
                         Condition(.workspace, .equals, "Acme")], outcome: .work)])
        XCTAssertNil(rules.match(Snapshot(bundleId: "notion.id", appName: "Notion",
                                          detailAvailable: false)))
        XCTAssertNotNil(rules.match(Snapshot(bundleId: "notion.id", appName: "Notion",
                                             workspace: "Acme")))
    }

    func testOlderRecordsWithoutTheFlagAreTreatedAsSeen() throws {
        let json = "{\"appName\":\"Notion\",\"bundleId\":\"notion.id\",\"workspace\":\"Acme\"}"
        let s = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertTrue(s.detailAvailable)
        XCTAssertEqual(s.groupingKey, "app:notion.id#Acme")
    }

    func testFlagSurvivesARoundTrip() throws {
        let s = Snapshot(bundleId: "b", appName: "A", detailAvailable: false)
        let back = try JSONDecoder().decode(Snapshot.self, from: try JSONEncoder().encode(s))
        XCTAssertFalse(back.detailAvailable)
    }
}
