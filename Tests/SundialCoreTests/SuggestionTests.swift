import XCTest
@testable import SundialCore

final class SuggestionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func typing(_ a: TimeInterval, _ b: TimeInterval) -> [Span] {
        stride(from: a, through: b, by: 5).map { Span(at($0), at($0)) }
    }

    func testWebLadderRunsNarrowToBroad() {
        let s = Snapshot(bundleId: "com.google.Chrome", appName: "Chrome",
                         url: "https://github.com/acme/api/pull/3", host: "github.com",
                         urlPath: "/acme/api/pull/3", browserProfile: "Work")
        let scopes = Suggestions.build(for: s).map(\.scope)
        XCTAssertEqual(scopes, [.exactPage, .section, .site, .profile, .app])
        XCTAssertTrue(scopes == scopes.sorted(), "must be ordered narrow to broad")
    }

    func testSectionSuggestionUsesTheFirstPathPart() {
        let s = Snapshot(bundleId: "b", appName: "Chrome", url: "https://github.com/acme/api",
                         host: "github.com", urlPath: "/acme/api")
        let section = Suggestions.build(for: s).first { $0.scope == .section }
        XCTAssertEqual(section?.conditions.first?.value, "github.com/acme")
        XCTAssertTrue(section?.title.contains("github.com/acme") ?? false)
    }

    func testSiteSuggestionStripsWww() {
        let s = Snapshot(bundleId: "b", appName: "Chrome", url: "https://www.acme.com/x",
                         host: "www.acme.com", urlPath: "/x")
        let site = Suggestions.build(for: s).first { $0.scope == .site }
        XCTAssertEqual(site?.conditions.first?.value, "acme.com")
    }

    func testRootPathOffersNoPageScope() {
        let s = Snapshot(bundleId: "b", appName: "Chrome", url: "https://acme.com/",
                         host: "acme.com", urlPath: "/")
        XCTAssertNil(Suggestions.build(for: s).first { $0.scope == .exactPage })
    }

    func testWorkspaceLadderForMultiTenantApps() {
        let s = Snapshot(bundleId: "notion.id", appName: "Notion", workspace: "Acme")
        let scopes = Suggestions.build(for: s).map(\.scope)
        XCTAssertEqual(scopes, [.workspace, .app])
        let ws = Suggestions.build(for: s).first!
        XCTAssertEqual(ws.conditions.count, 2, "scoped to the app as well as the workspace")
    }

    func testProjectLadderOffersRepoThenParentFolder() {
        let s = Snapshot(bundleId: "com.microsoft.VSCode", appName: "Code",
                         projectName: "api", projectPath: "/Users/x/code/api")
        let scopes = Suggestions.build(for: s).map(\.scope)
        XCTAssertEqual(scopes, [.project, .folder, .app])
        let folder = Suggestions.build(for: s).first { $0.scope == .folder }
        XCTAssertEqual(folder?.conditions.first?.value, "/Users/x/code")
    }

    func testTitlePartOfferedForPlainApps() {
        let s = Snapshot(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack",
                         windowTitle: "general (Channel) - Acme - Slack")
        let part = Suggestions.build(for: s).first { $0.scope == .titlePart }
        XCTAssertEqual(part?.conditions.last?.value, "Acme")
        XCTAssertEqual(part?.conditions.last?.op, .titleSegment)
    }

    func testEveryLadderEndsWithTheWholeApp() {
        for s in [Snapshot(bundleId: "x", appName: "X"),
                  Snapshot(bundleId: "y", appName: "Y", host: "a.com", urlPath: "/b")] {
            XCTAssertEqual(Suggestions.build(for: s).last?.scope, .app)
        }
    }

    func testSuggestionBecomesAUsableRule() {
        let s = Snapshot(bundleId: "b", appName: "Chrome", url: "https://acme.com/x",
                         host: "acme.com", urlPath: "/x")
        let rule = Suggestions.build(for: s).first { $0.scope == .site }!.rule(outcome: .work)
        XCTAssertTrue(rule.matches(s))
        XCTAssertEqual(rule.origin, .correction)
    }

    // MARK: impact

    func testImpactCountsTimeThatWouldMove() {
        let obs = [ObservationSpan(start: at(0), end: at(600),
                                   snapshot: Snapshot(bundleId: "b", appName: "Chrome",
                                                      url: "https://acme.com/x", host: "acme.com",
                                                      urlPath: "/x"))]
        let presence = PresenceLog(input: typing(0, 600))
        var after = RuleSet()
        after.insertBySpecificity(Rule(name: "acme",
                                       conditions: [Condition(.host, .hostOrSubdomain, "acme.com")],
                                       outcome: .work))
        let impact = Impact.compute(observations: obs, presence: presence, settings: .default,
                                    before: RuleSet(), after: after)
        XCTAssertEqual(impact.changedSeconds, 600, accuracy: 2)
        XCTAssertEqual(impact.workDelta, 600, accuracy: 2)
        XCTAssertEqual(impact.reclassifiedFromDecided, 0,
                       "time that had no rule is not counted as overreach")
        XCTAssertTrue(impact.summary.contains("reclassified"))
    }

    /// The warning signal: a new rule stealing time that another rule had
    /// already decided.
    func testImpactFlagsOverreachIntoDecidedTime() {
        let obs = [ObservationSpan(start: at(0), end: at(600),
                                   snapshot: Snapshot(bundleId: "b", appName: "Chrome",
                                                      url: "https://acme.com/x", host: "acme.com",
                                                      urlPath: "/x"))]
        let presence = PresenceLog(input: typing(0, 600))
        let before = RuleSet(rules: [Rule(name: "acme work",
                                          conditions: [Condition(.host, .hostOrSubdomain, "acme.com")],
                                          outcome: .work)])
        var after = before
        after.insertBySpecificity(Rule(name: "that page",
                                       conditions: [Condition(.url, .urlPrefix, "acme.com/x")],
                                       outcome: .personal))
        let impact = Impact.compute(observations: obs, presence: presence, settings: .default,
                                    before: before, after: after)
        XCTAssertEqual(impact.reclassifiedFromDecided, 600, accuracy: 2)
        XCTAssertEqual(impact.workDelta, -600, accuracy: 2)
        XCTAssertTrue(impact.summary.contains("already had a rule"))
    }

    func testNoChangeReportsNothing() {
        let obs = [ObservationSpan(start: at(0), end: at(60),
                                   snapshot: Snapshot(bundleId: "b", appName: "B"))]
        let impact = Impact.compute(observations: obs, presence: PresenceLog(input: typing(0, 60)),
                                    settings: .default, before: RuleSet(), after: RuleSet())
        XCTAssertEqual(impact.changedSeconds, 0)
        XCTAssertEqual(impact.summary, "No time already recorded would change.")
    }
}

/// The mistake that started this: one rule for all of VS Code, which then
/// claimed every personal repository as work.
final class AppScopeCautionTests: XCTestCase {
    private func editor(project: String?) -> Snapshot {
        Snapshot(bundleId: "com.microsoft.VSCode", appName: "Code",
                 windowTitle: project, projectName: project,
                 projectPath: project.map { "/Users/x/repos/\($0)" })
    }

    private func appScope(_ s: Snapshot) -> Suggestion? {
        Suggestions.build(for: s).first { $0.scope == .app }
    }

    func testTheWholeAppIsStillOfferedForAnEditor() {
        XCTAssertNotNil(appScope(editor(project: "sundial")),
                        "sometimes one rule for the whole app is what you want")
    }

    func testButItSaysWhatItWouldSwallow() {
        let caution = appScope(editor(project: "sundial"))?.caution
        XCTAssertNotNil(caution)
        XCTAssertTrue(caution?.contains("sundial") ?? false,
                      "names the project currently open, so the overreach is concrete")
        XCTAssertTrue(caution?.contains("every other") ?? false)
    }

    /// An app with no project is not used two ways, so there is nothing to warn
    /// about and a warning would just be noise.
    func testNoCautionForAnAppWithoutProjects() {
        let slack = Snapshot(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack",
                             windowTitle: "general - Acme - Slack")
        XCTAssertNil(appScope(slack)?.caution)
        XCTAssertNil(appScope(editor(project: nil))?.caution)
    }

    /// The narrower rungs never carry it: they are the recommendation.
    func testNarrowerScopesAreNeverCautioned() {
        let all = Suggestions.build(for: editor(project: "sundial"))
        for s in all where s.scope != .app {
            XCTAssertNil(s.caution, "\(s.title) should not be cautioned")
        }
    }
}
