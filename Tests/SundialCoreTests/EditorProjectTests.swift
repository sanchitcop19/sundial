import XCTest
@testable import SundialCore

/// The same editor is used for work and for side projects, so the open project
/// has to decide the verdict rather than the application.
final class EditorProjectTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func typing(_ a: TimeInterval, _ b: TimeInterval) -> [Span] {
        stride(from: a, through: b, by: 5).map { Span(at($0), at($0)) }
    }

    func code(project: String? = nil, path: String? = nil, title: String? = nil) -> Snapshot {
        Snapshot(bundleId: "com.microsoft.VSCode", appName: "Code", windowTitle: title,
                 projectName: project, projectPath: path)
    }

    func testSameEditorSplitsByProjectFolder() {
        var rules = RuleSet()
        rules.insertBySpecificity(Rule(name: "work code",
            conditions: [Condition(.projectPath, .pathUnder, "/Users/x/work")], outcome: .work))
        rules.insertBySpecificity(Rule(name: "side projects",
            conditions: [Condition(.projectPath, .pathUnder, "/Users/x/side")], outcome: .personal))

        XCTAssertEqual(rules.match(code(project: "api", path: "/Users/x/work/api"))?.outcome, .work)
        XCTAssertEqual(rules.match(code(project: "blog", path: "/Users/x/side/blog"))?.outcome, .personal)
    }

    /// A project rule must beat a blanket rule on the same app, whichever was
    /// added first.
    func testProjectRuleOutranksAnAppWideRule() {
        var rules = RuleSet()
        rules.insertBySpecificity(Rule(name: "all of Code",
            conditions: [Condition(.bundleId, .equals, "com.microsoft.VSCode")], outcome: .personal))
        rules.insertBySpecificity(Rule(name: "work code",
            conditions: [Condition(.projectPath, .pathUnder, "/Users/x/work")], outcome: .work))

        XCTAssertEqual(rules.rules.first?.name, "work code")
        XCTAssertEqual(rules.match(code(project: "api", path: "/Users/x/work/api"))?.outcome, .work)
        XCTAssertEqual(rules.match(code(project: "misc", path: "/Users/x/other"))?.outcome, .personal)
    }

    /// A folder outside any known code root still gets a name from the title,
    /// so it can be told apart and given its own rule.
    func testProjectKnownOnlyByNameCanStillBeRuled() {
        let snap = code(project: "scratchpad", title: "notes.md — scratchpad")
        var rules = RuleSet()
        rules.insertBySpecificity(Rule(name: "scratchpad",
            conditions: [Condition(.bundleId, .equals, "com.microsoft.VSCode"),
                         Condition(.projectPath, .equals, "scratchpad")], outcome: .personal))
        XCTAssertEqual(rules.match(snap)?.outcome, .personal)
        XCTAssertNil(rules.match(code(project: "other")), "a different project is unaffected")
    }

    func testUnresolvedProjectIsOfferedAsItsOwnScope() {
        let ladder = Suggestions.build(for: code(project: "scratchpad"))
        let project = ladder.first { $0.scope == .project }
        XCTAssertNotNil(project)
        XCTAssertEqual(project?.conditions.last?.value, "scratchpad")
        XCTAssertTrue(project!.conditions.contains { $0.field == .bundleId },
                      "scoped to the editor, not to every app with that folder name")
        XCTAssertEqual(ladder.last?.scope, .app)
    }

    func testTwoProjectsInOneEditorGroupSeparatelyForReview() {
        let segs = Classifier(rules: RuleSet()).classify(
            observations: [
                ObservationSpan(start: at(0), end: at(300),
                                snapshot: code(project: "api", path: "/Users/x/work/api")),
                ObservationSpan(start: at(300), end: at(400),
                                snapshot: code(project: "blog", path: "/Users/x/side/blog")),
            ],
            presence: PresenceLog(input: typing(0, 400)))
        let review = ReviewItem.build(from: segs)
        XCTAssertEqual(review.count, 2, "each project needs its own decision")
        XCTAssertEqual(review.first?.snapshot.projectName, "api")
    }

    /// Adding a rule for one project must not sweep up the other.
    func testRulingOneProjectLeavesTheOtherAlone() {
        let observations = [
            ObservationSpan(start: at(0), end: at(300),
                            snapshot: code(project: "api", path: "/Users/x/work/api")),
            ObservationSpan(start: at(300), end: at(600),
                            snapshot: code(project: "blog", path: "/Users/x/side/blog")),
        ]
        let presence = PresenceLog(input: typing(0, 600))
        var after = RuleSet()
        after.insertBySpecificity(Rule(name: "work code",
            conditions: [Condition(.projectPath, .pathUnder, "/Users/x/work")], outcome: .work))

        let impact = Impact.compute(observations: observations, presence: presence,
                                    settings: .default, before: RuleSet(), after: after)
        XCTAssertEqual(impact.changedSeconds, 300, accuracy: 5)
        XCTAssertEqual(impact.after.unclassified, 300, accuracy: 5)
    }

    func testEditorsAndTerminalsGetNoBlanketVerdict() {
        for bundle in ["com.microsoft.VSCode", "com.apple.dt.Xcode", "dev.zed.Zed",
                       "com.todesktop.230313mzl4w4u92", "com.apple.Terminal"] {
            XCTAssertNil(Catalogue.appHints[bundle],
                         "\(bundle) is used for both work and personal; it must not be pre-classified")
            XCTAssertTrue(Catalogue.editors.contains(bundle))
        }
    }

    func testSetupStillOffersCodeFoldersAsTheEditorAnswer() {
        var c = SetupChoices()
        c.workCodeRoots = ["/Users/x/work"]
        c.personalCodeRoots = ["/Users/x/side"]
        let set = StarterRules.build(c)
        XCTAssertEqual(set.match(code(project: "api", path: "/Users/x/work/api"))?.outcome, .work)
        XCTAssertEqual(set.match(code(project: "blog", path: "/Users/x/side/blog"))?.outcome, .personal)
    }
}

/// Migration from the earlier tracker.
final class WorkClockImportTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func seg(_ a: TimeInterval, _ b: TimeInterval, _ state: String, key: String,
             app: String = "App", detail: String = "") -> WorkClockImport.LegacySegment {
        WorkClockImport.LegacySegment(start: t0.addingTimeInterval(a), end: t0.addingTimeInterval(b),
                                      state: state, app: app, detail: detail,
                                      rule: "r", contextKey: key)
    }

    func testRebuildsSnapshotsFromContextKeys() {
        let web = WorkClockImport.snapshot(
            from: seg(0, 1, "working", key: "web:linear.app", app: "Zen", detail: "linear.app · Work"),
            projectIndex: [:])
        XCTAssertEqual(web?.host, "linear.app")
        XCTAssertEqual(web?.browserProfile, "Work")

        let editor = WorkClockImport.snapshot(
            from: seg(0, 1, "working", key: "editor:api", app: "Code"),
            projectIndex: ["api": "/Users/x/work/api"])
        XCTAssertEqual(editor?.projectPath, "/Users/x/work/api")
        XCTAssertEqual(editor?.projectName, "api")

        let workspace = WorkClockImport.snapshot(
            from: seg(0, 1, "working", key: "app:notion.id#Acme", app: "Notion"),
            projectIndex: [:])
        XCTAssertEqual(workspace?.workspace, "Acme")
        XCTAssertEqual(workspace?.bundleId, "notion.id")

        XCTAssertNil(WorkClockImport.snapshot(from: seg(0, 1, "idle", key: "idle:input"),
                                              projectIndex: [:]))
    }

    /// Away time is imported as absence, so the new idle threshold cannot
    /// re-decide time the old tracker already judged.
    func testActiveBecomesInputAndAwayBecomesAbsence() throws {
        let (obs, presence, skipped) = WorkClockImport.convert(
            segments: [seg(0, 600, "working", key: "web:acme.com", detail: "acme.com · Work"),
                       seg(600, 900, "idle", key: "idle:input")],
            projectIndex: [:], existing: [])
        XCTAssertEqual(obs.count, 1)
        XCTAssertEqual(try XCTUnwrap(presence.input.first).duration, 600, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(presence.absent.first).duration, 300, accuracy: 1)
        XCTAssertEqual(skipped, 0)

        let segs = Classifier(rules: RuleSet(rules: [
            Rule(name: "acme", conditions: [Condition(.host, .hostOrSubdomain, "acme.com")],
                 outcome: .work)])).classify(observations: obs, presence: presence)
        let t = Totals.compute(segs)
        XCTAssertEqual(t.work, 600, accuracy: 2)
        XCTAssertEqual(t.away, 300, accuracy: 2)
    }

    /// Re-running the import, or importing a day the new tracker already
    /// covers, must not double count.
    func testOverlappingStretchesAreSkipped() {
        let existing = [ObservationSpan(start: t0.addingTimeInterval(300),
                                        end: t0.addingTimeInterval(900),
                                        snapshot: Snapshot(bundleId: "b", appName: "A"))]
        let (obs, _, skipped) = WorkClockImport.convert(
            segments: [seg(0, 200, "working", key: "web:a.com"),
                       seg(400, 800, "working", key: "web:b.com")],
            projectIndex: [:], existing: existing)
        XCTAssertEqual(obs.count, 1)
        XCTAssertEqual(obs.first?.snapshot.host, "a.com")
        XCTAssertEqual(skipped, 1)
    }

    func testConfigTranslatesToEquivalentRules() {
        let json = """
        {"workURLPatterns": ["linear.app", "github.com/Acme"],
         "personalURLPatterns": ["netflix.com"],
         "zenWorkSpaceNames": ["Work"],
         "workRepoRoots": ["/Users/x/work"],
         "appStates": {"com.spotify.client": "personal", "com.linear": "working"},
         "titleRules": [{"bundleId": "com.slack", "equalsSegment": "Acme", "state": "working"}],
         "workspaceRules": [{"bundleId": "notion.id", "equals": "Acme", "state": "working"}]}
        """
        let set = WorkClockImport.rules(fromConfig: Data(json.utf8))
        func snap(_ s: Snapshot) -> Outcome? { set.match(s)?.outcome }

        XCTAssertEqual(snap(Snapshot(bundleId: "b", appName: "Z", host: "linear.app", urlPath: "/")), .work)
        XCTAssertEqual(snap(Snapshot(bundleId: "b", appName: "Z", host: "github.com",
                                     urlPath: "/Acme/api")), .work)
        XCTAssertEqual(snap(Snapshot(bundleId: "b", appName: "Z", host: "netflix.com", urlPath: "/")),
                       .personal)
        XCTAssertEqual(snap(Snapshot(bundleId: "b", appName: "Z", host: "misc.example",
                                     urlPath: "/", browserProfile: "Work")), .work)
        XCTAssertEqual(snap(Snapshot(bundleId: "e", appName: "E", projectPath: "/Users/x/work/a")), .work)
        XCTAssertEqual(snap(Snapshot(bundleId: "com.spotify.client", appName: "S")), .personal)
        XCTAssertEqual(snap(Snapshot(bundleId: "com.linear", appName: "L")), .work)
        XCTAssertEqual(snap(Snapshot(bundleId: "com.slack", appName: "S",
                                     windowTitle: "general - Acme - Slack")), .work)
        XCTAssertEqual(snap(Snapshot(bundleId: "notion.id", appName: "N", workspace: "Acme")), .work)
    }

    func testEmptyConfigYieldsNoRules() {
        XCTAssertTrue(WorkClockImport.rules(fromConfig: Data("{}".utf8)).rules.isEmpty)
        XCTAssertTrue(WorkClockImport.rules(fromConfig: Data("junk".utf8)).rules.isEmpty)
    }
}

extension WorkClockImportTests {
    /// End to end: a legacy folder on disk becomes classified Sundial history.
    func testRunImportsFilesAndClassifiesThemWithTranslatedRules() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let source = tmp.appendingPathComponent("workclock")
        let store = Store(root: tmp.appendingPathComponent("sundial"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let iso = ISO8601DateFormatter()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let day = Format.day(base)
        func line(_ a: TimeInterval, _ b: TimeInterval, _ state: String,
                  _ key: String, _ detail: String) -> String {
            """
            {"start":"\(iso.string(from: base.addingTimeInterval(a)))",\
            "end":"\(iso.string(from: base.addingTimeInterval(b)))",\
            "state":"\(state)","app":"Zen","detail":"\(detail)","rule":"r","contextKey":"\(key)"}
            """
        }
        try [line(0, 600, "working", "web:acme.com", "acme.com · Work"),
             line(600, 900, "idle", "idle:input", "away"),
             line(900, 1200, "personal", "web:netflix.com", "netflix.com · Personal")]
            .joined(separator: "\n")
            .write(to: source.appendingPathComponent("segments-\(day).jsonl"),
                   atomically: true, encoding: .utf8)

        let config = tmp.appendingPathComponent("config.json")
        try """
        {"workURLPatterns":["acme.com"],"personalURLPatterns":["netflix.com"]}
        """.write(to: config, atomically: true, encoding: .utf8)

        let result = WorkClockImport.run(sourceRoot: source, configURL: config,
                                         store: store, projectIndex: [:])
        XCTAssertEqual(result.days, 1)
        XCTAssertEqual(result.observations, 2)
        XCTAssertEqual(result.rules, 2)
        XCTAssertEqual(result.imported, 900, accuracy: 2)

        let loaded = store.load(day: day)
        let segs = Classifier(rules: try XCTUnwrap(store.loadRules()), settings: .default)
            .classify(observations: loaded.observations, presence: loaded.presence)
        let t = Totals.compute(segs)
        XCTAssertEqual(t.work, 600, accuracy: 5)
        XCTAssertEqual(t.personal, 300, accuracy: 5)
        XCTAssertEqual(t.away, 300, accuracy: 5)
        XCTAssertEqual(t.unclassified, 0, "translated rules classify the imported history")
    }

    func testRunningTwiceDoesNotDoubleCount() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let source = tmp.appendingPathComponent("workclock")
        let store = Store(root: tmp.appendingPathComponent("sundial"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let iso = ISO8601DateFormatter()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try """
        {"start":"\(iso.string(from: base))","end":"\(iso.string(from: base.addingTimeInterval(600)))",\
        "state":"working","app":"Zen","detail":"acme.com · Work","rule":"r","contextKey":"web:acme.com"}
        """.write(to: source.appendingPathComponent("segments-\(Format.day(base)).jsonl"),
                  atomically: true, encoding: .utf8)
        let config = tmp.appendingPathComponent("config.json")
        try "{}".write(to: config, atomically: true, encoding: .utf8)

        let first = WorkClockImport.run(sourceRoot: source, configURL: config,
                                        store: store, projectIndex: [:])
        let second = WorkClockImport.run(sourceRoot: source, configURL: config,
                                         store: store, projectIndex: [:])
        XCTAssertEqual(first.observations, 1)
        XCTAssertEqual(second.observations, 0)
        XCTAssertEqual(second.skippedOverlapping, 1)
        XCTAssertEqual(store.load(day: Format.day(base)).observations.count, 1)
    }

    func testRunOnAMissingFolderIsHarmless() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = Store(root: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = WorkClockImport.run(sourceRoot: tmp.appendingPathComponent("nope"),
                                    configURL: tmp.appendingPathComponent("none.json"),
                                    store: store, projectIndex: [:])
        XCTAssertEqual(r, WorkClockImport.Result())
    }

    func testUnreadableWorkspaceKeyStillYieldsTheApp() {
        let s = WorkClockImport.snapshot(
            from: seg(0, 1, "unknown", key: "app:notion.id#unreadable", app: "Notion"),
            projectIndex: [:])
        XCTAssertEqual(s?.bundleId, "notion.id")
        XCTAssertNil(s?.workspace)
    }

    func testUnknownContextKeysAreSkipped() {
        XCTAssertNil(WorkClockImport.snapshot(from: seg(0, 1, "working", key: "web:unknown"),
                                              projectIndex: [:]))
        XCTAssertNil(WorkClockImport.snapshot(from: seg(0, 1, "working", key: "editor:none"),
                                              projectIndex: [:]))
        XCTAssertNil(WorkClockImport.snapshot(from: seg(0, 1, "working", key: "mystery"),
                                              projectIndex: [:]))
    }
}
