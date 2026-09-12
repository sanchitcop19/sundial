import XCTest
import Compression
@testable import SundialCore

final class FirefoxSessionTests: XCTestCase {
    static func mozlz4(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var buf = [UInt8](repeating: 0, count: max(64, payload.count * 2))
        let n = payload.withUnsafeBytes { src in
            compression_encode_buffer(&buf, buf.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                      nil, COMPRESSION_LZ4_RAW)
        }
        var file = Data("mozLz40\0".utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(contentsOf: buf[0..<n])
        return file
    }

    static let session = """
    {"selectedWindow": 1, "windows": [{
      "selected": 1,
      "spaces": [{"uuid": "{w}", "name": "Work", "containerTabId": 8}],
      "tabs": [
        {"index": 1, "userContextId": 0, "lastAccessed": 10,
         "entries": [{"url": "https://news.example/", "title": "News"}]},
        {"index": 2, "userContextId": 8, "zenWorkspace": "{w}", "lastAccessed": 99,
         "entries": [{"url": "https://old.example", "title": "Old"},
                     {"url": "https://acme.com/board", "title": "Acme Board"}]}
      ]}]}
    """
    static let containers = """
    {"identities": [{"userContextId": 8, "public": true, "name": "Work"},
                    {"userContextId": 5, "public": false, "name": "internal"}]}
    """

    func parsed() throws -> FirefoxSession {
        let c = FirefoxSession.parseContainers(Data(Self.containers.utf8))
        return try XCTUnwrap(FirefoxSession.parse(Data(Self.session.utf8), containers: c))
    }

    func testContainersOnlyIncludePublicOnes() {
        let c = FirefoxSession.parseContainers(Data(Self.containers.utf8))
        XCTAssertEqual(c[8], "Work")
        XCTAssertNil(c[5])
    }

    func testUsesCurrentHistoryEntryAndAttachesContainer() throws {
        let s = try parsed()
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.tabs[1].url, "https://acme.com/board")
        XCTAssertEqual(s.tabs[1].container, "Work")
        XCTAssertEqual(s.tabs[1].space, "Work")
        XCTAssertNil(s.tabs[0].container)
    }

    func testSelectedPointerIsHonoured() throws {
        XCTAssertEqual(try parsed().selected?.title, "News")
    }

    /// The session store lags a tab switch; the live title closes the gap.
    func testLiveTitleBeatsStaleSelection() throws {
        let tab = try XCTUnwrap(parsed().tab(matchingTitle: "Acme Board"))
        XCTAssertEqual(tab.container, "Work")
    }

    func testTitleMatchPrefersMostRecentDuplicate() {
        let s = FirefoxSession(tabs: [
            BrowserTab(title: "Docs", url: "a", container: nil, lastAccessed: 1),
            BrowserTab(title: "Docs", url: "b", container: "Work", lastAccessed: 9),
        ], selected: nil)
        XCTAssertEqual(s.tab(matchingTitle: "Docs")?.container, "Work")
    }

    func testEmptyTitleMatchesNothing() throws {
        XCTAssertNil(try parsed().tab(matchingTitle: ""))
        XCTAssertNil(try parsed().tab(matchingTitle: "Never opened"))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(FirefoxSession.parse(Data("nope".utf8), containers: [:]))
        XCTAssertNil(FirefoxSession.parse(Data("{\"windows\":[]}".utf8), containers: [:]))
    }

    func testMozLZ4RoundTripAndRejection() throws {
        let payload = Data(String(repeating: "{\"a\":1}", count: 300).utf8)
        var buf = [UInt8](repeating: 0, count: payload.count * 2)
        let n = payload.withUnsafeBytes { src in
            compression_encode_buffer(&buf, buf.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!,
                                      payload.count, nil, COMPRESSION_LZ4_RAW)
        }
        var file = Data("mozLz40\0".utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(contentsOf: buf[0..<n])
        XCTAssertEqual(try MozLZ4.decompress(file), payload)
        XCTAssertThrowsError(try MozLZ4.decompress(Data(repeating: 7, count: 40)))
        XCTAssertThrowsError(try MozLZ4.decompress(Data("mozLz40\0".utf8)))
    }

    func testFirefoxFamilyRecognition() {
        XCTAssertTrue(FirefoxFamily.isFirefoxFamily("app.zen-browser.zen"))
        XCTAssertTrue(FirefoxFamily.isFirefoxFamily("org.mozilla.firefox"))
        XCTAssertFalse(FirefoxFamily.isFirefoxFamily("com.google.Chrome"))
    }

    func testReaderReportsMissingProfile() {
        let r = FirefoxSessionReader(folderName: "nope-\(UUID().uuidString)",
                                     home: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertNil(r.session())
        XCTAssertNotNil(r.lastError)
        XCTAssertNil(r.activeTab(liveTitle: "x"))
    }

    func testReaderReadsARealProfileOnDisk() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let profile = home.appendingPathComponent("Library/Application Support/testfox/Profiles/abc")
        let backups = profile.appendingPathComponent("sessionstore-backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Self.mozlz4(Self.session).write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        try Data(Self.containers.utf8).write(to: profile.appendingPathComponent("containers.json"))
        defer { try? FileManager.default.removeItem(at: home) }

        let r = FirefoxSessionReader(folderName: "testfox", home: home)
        XCTAssertEqual(r.session()?.tabs.count, 2)
        XCTAssertEqual(r.knownContainers(), ["Work"])
        XCTAssertEqual(r.activeTab(liveTitle: "Acme Board")?.container, "Work")
        XCTAssertEqual(r.session()?.tabs.count, 2, "second read is served from cache")
    }
}

final class SetupTests: XCTestCase {
    func testCodeRootsFoundByRepositoryCount() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        for r in ["repos/a", "repos/b", "code/c"] {
            try fm.createDirectory(at: home.appendingPathComponent("\(r)/.git"),
                                   withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: home.appendingPathComponent("Music"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let roots = EnvironmentScanner.codeRoots(home: home, fm: fm)
        XCTAssertEqual(roots.map { ($0.path as NSString).lastPathComponent }, ["repos", "code"])
        XCTAssertEqual(roots[0].repoCount, 2)
    }

    func testScanSeparatesBrowsersFromOtherApps() {
        let env = EnvironmentScanner.scan(
            installedApps: [("com.google.Chrome", "Google Chrome"),
                            ("com.spotify.client", "Spotify"),
                            ("com.acme.Unknown", "Unknown")],
            home: URL(fileURLWithPath: NSTemporaryDirectory()),
            chromiumProfiles: { _ in ["Work", "Personal"] })
        XCTAssertEqual(env.browsers.map(\.name), ["Google Chrome"])
        XCTAssertEqual(env.browsers[0].identities, ["Work", "Personal"])
        XCTAssertEqual(env.apps.first { $0.bundleId == "com.spotify.client" }?.suggested, .personal)
        XCTAssertNil(env.apps.first { $0.bundleId == "com.acme.Unknown" }?.suggested,
                     "apps with no obvious answer are left for the user")
    }

    func testStarterRulesCoverEveryAnswer() {
        var c = SetupChoices()
        c.workDomains = ["https://www.acme.com/", "acme.atlassian.net"]
        c.workBrowserIdentities = [["com.google.Chrome", "Work"]]
        c.workCodeRoots = ["/Users/x/work"]
        c.personalCodeRoots = ["/Users/x/side"]
        c.workApps = ["com.tinyspeck.slackmacgap"]
        c.personalApps = ["com.spotify.client"]
        c.includePersonalSites = false
        let set = StarterRules.build(c)

        XCTAssertEqual(set.match(Snapshot(bundleId: "b", appName: "B",
                                          host: "mail.acme.com", urlPath: "/"))?.outcome, .work)
        XCTAssertEqual(set.match(Snapshot(bundleId: "com.google.Chrome", appName: "Chrome",
                                          browserProfile: "Work"))?.outcome, .work)
        XCTAssertEqual(set.match(Snapshot(bundleId: "e", appName: "E",
                                          projectPath: "/Users/x/work/api"))?.outcome, .work)
        XCTAssertEqual(set.match(Snapshot(bundleId: "e", appName: "E",
                                          projectPath: "/Users/x/side/blog"))?.outcome, .personal)
        XCTAssertEqual(set.match(Snapshot(bundleId: "com.spotify.client", appName: "Spotify"))?.outcome,
                       .personal)
        XCTAssertNil(set.match(Snapshot(bundleId: "com.netflix", appName: "N",
                                        host: "netflix.com", urlPath: "/")),
                     "the personal site list was declined")
    }

    func testPersonalSiteListIsOptional() {
        var c = SetupChoices()
        c.includePersonalSites = true
        let set = StarterRules.build(c)
        XCTAssertEqual(set.match(Snapshot(bundleId: "b", appName: "B",
                                          host: "www.netflix.com", urlPath: "/"))?.outcome, .personal)
    }

    func testEmptySetupProducesNoRules() {
        XCTAssertTrue(StarterRules.build(SetupChoices()).rules.filter { $0.outcome == .work }.isEmpty)
    }

    func testDomainsAreCleanedBeforeUse() {
        var c = SetupChoices()
        c.workDomains = ["HTTPS://WWW.Acme.COM/path/"]
        let set = StarterRules.build(c)
        XCTAssertEqual(set.rules.first?.conditions.first?.value, "acme.com/path")
    }
}

final class FormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Format.duration(0), "0s")
        XCTAssertEqual(Format.duration(90), "1m")
        XCTAssertEqual(Format.duration(3600), "1h 00m")
        XCTAssertEqual(Format.hours(5400), "1.500")
    }

    func testSpanClampsInvertedRanges() {
        let now = Date()
        XCTAssertEqual(Span(now, now - 100).duration, 0)
        XCTAssertTrue(Span(now, now + 10).contains(now))
        XCTAssertFalse(Span(now, now + 10).contains(now + 10), "end is exclusive")
        XCTAssertNotNil(Span(now, now + 10).intersection(Span(now + 5, now + 20)))
        XCTAssertNil(Span(now, now + 5).intersection(Span(now + 10, now + 20)))
    }

    func testMergeJoinsWithinTolerance() {
        let now = Date()
        let merged = PresenceLog.merge([Span(now, now + 5), Span(now + 7, now + 10),
                                        Span(now + 100, now + 110)], tolerance: 5)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].duration, 10, accuracy: 0.01)
    }

    func testSnapshotSummaryAndGroupingPreferTheMostSpecificFact() {
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "Chrome", host: "acme.com",
                                browserProfile: "Work").summary, "acme.com · Work")
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "Notion", workspace: "Acme").groupingKey,
                       "app:b#Acme")
        XCTAssertEqual(Snapshot(bundleId: "b", appName: "X").groupingKey, "app:b")
    }
}
