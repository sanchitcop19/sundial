import XCTest
@testable import SundialCore

final class ConditionTests: XCTestCase {
    func snap(host: String? = nil, path: String? = nil, bundle: String = "com.app",
              title: String? = nil, workspace: String? = nil, profile: String? = nil,
              project: String? = nil) -> Snapshot {
        Snapshot(bundleId: bundle, appName: "App", windowTitle: title,
                 url: host.map { "https://\($0)\(path ?? "")" }, host: host, urlPath: path,
                 browserProfile: profile, workspace: workspace, projectPath: project)
    }

    func testHostMatchesSubdomainButNotSuffix() {
        let c = Condition(.host, .hostOrSubdomain, "acme.com")
        XCTAssertTrue(c.matches(snap(host: "acme.com")))
        XCTAssertTrue(c.matches(snap(host: "mail.acme.com")))
        XCTAssertFalse(c.matches(snap(host: "notacme.com")))
        XCTAssertFalse(c.matches(snap(host: "acme.com.evil.net")))
    }

    /// A path-scoped rule must stop at a path boundary, or "/acme" would also
    /// capture "/acmecorp".
    func testUrlPrefixStopsAtPathBoundary() {
        let c = Condition(.url, .urlPrefix, "github.com/acme")
        XCTAssertTrue(c.matches(snap(host: "github.com", path: "/acme")))
        XCTAssertTrue(c.matches(snap(host: "github.com", path: "/acme/api")))
        XCTAssertFalse(c.matches(snap(host: "github.com", path: "/acmecorp/api")))
        XCTAssertFalse(c.matches(snap(host: "gitlab.com", path: "/acme")))
    }

    func testUrlPrefixIgnoresSchemeAndCase() {
        let c = Condition(.url, .urlPrefix, "https://GitHub.com/Acme")
        XCTAssertTrue(c.matches(snap(host: "github.com", path: "/acme/api")))
    }

    func testTitleSegmentIsExactPerPart() {
        let c = Condition(.title, .titleSegment, "Acme")
        XCTAssertTrue(c.matches(snap(title: "general (Channel) - Acme - Slack")))
        XCTAssertTrue(c.matches(snap(title: "notes — Acme")))
        XCTAssertFalse(c.matches(snap(title: "Acme Alumni - Slack")),
                       "a different workspace containing the word must not match")
        XCTAssertFalse(c.matches(snap(title: "acme-feedback (Channel) - Other - Slack")))
    }

    func testContainsIsLooseByDesign() {
        XCTAssertTrue(Condition(.title, .contains, "acme").matches(snap(title: "Acme Alumni")))
    }

    func testPathUnderMatchesFolderNotPrefix() {
        let c = Condition(.projectPath, .pathUnder, "/Users/x/work")
        XCTAssertTrue(c.matches(snap(project: "/Users/x/work")))
        XCTAssertTrue(c.matches(snap(project: "/Users/x/work/api")))
        XCTAssertFalse(c.matches(snap(project: "/Users/x/workshop")))
    }

    func testPathUnderExpandsTilde() {
        let c = Condition(.projectPath, .pathUnder, "~/code")
        let home = NSHomeDirectory()
        XCTAssertTrue(c.matches(snap(project: "\(home)/code/app")))
    }

    func testMissingFieldNeverMatches() {
        XCTAssertFalse(Condition(.host, .hostOrSubdomain, "acme.com").matches(snap()))
        XCTAssertFalse(Condition(.workspace, .equals, "Acme").matches(snap()))
    }

    func testWorkspaceAndProfileEquality() {
        XCTAssertTrue(Condition(.workspace, .equals, "acme").matches(snap(workspace: "Acme")))
        XCTAssertTrue(Condition(.browserProfile, .equals, "Work").matches(snap(profile: "work")))
    }

    func testDescriptionsAreReadable() {
        XCTAssertEqual(Condition(.host, .hostOrSubdomain, "acme.com").describe,
                       "site is acme.com (or a subdomain)")
        XCTAssertTrue(Condition(.projectPath, .pathUnder, "/w").describe.contains("inside"))
    }
}

final class RuleSetTests: XCTestCase {
    func rule(_ name: String, _ conditions: [Condition], _ o: Outcome = .work) -> Rule {
        Rule(name: name, conditions: conditions, outcome: o)
    }

    func testAllConditionsMustMatch() {
        let r = rule("both", [Condition(.bundleId, .equals, "com.app"),
                              Condition(.workspace, .equals, "Acme")])
        let s = Snapshot(bundleId: "com.app", appName: "App", workspace: "Acme")
        XCTAssertTrue(r.matches(s))
        XCTAssertFalse(r.matches(Snapshot(bundleId: "com.app", appName: "App", workspace: "Other")))
    }

    func testEmptyRuleNeverMatches() {
        XCTAssertFalse(rule("empty", []).matches(Snapshot(bundleId: "a", appName: "A")))
    }

    func testFirstEnabledMatchWins() {
        var set = RuleSet(rules: [
            rule("a", [Condition(.bundleId, .equals, "com.app")], .work),
            rule("b", [Condition(.bundleId, .equals, "com.app")], .personal),
        ])
        let s = Snapshot(bundleId: "com.app", appName: "App")
        XCTAssertEqual(set.match(s)?.name, "a")
        set.rules[0].enabled = false
        XCTAssertEqual(set.match(s)?.name, "b")
    }

    /// A broad rule added later must not swallow a precise one added earlier.
    func testSpecificInsertOrdersNarrowRulesFirst() {
        var set = RuleSet()
        set.insertBySpecificity(rule("whole app", [Condition(.bundleId, .equals, "com.chrome")], .personal))
        set.insertBySpecificity(rule("one site", [Condition(.host, .hostOrSubdomain, "acme.com")], .work))
        set.insertBySpecificity(rule("one page", [Condition(.url, .urlPrefix, "acme.com/docs")], .personal))
        XCTAssertEqual(set.rules.map(\.name), ["one page", "one site", "whole app"])

        let s = Snapshot(bundleId: "com.chrome", appName: "Chrome",
                         url: "https://acme.com/wiki", host: "acme.com", urlPath: "/wiki")
        XCTAssertEqual(set.match(s)?.name, "one site")
    }

    func testMoveReordersPredictably() {
        var set = RuleSet(rules: [rule("a", []), rule("b", []), rule("c", [])])
        set.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(set.rules.map(\.name), ["c", "a", "b"])
        set.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(set.rules.map(\.name), ["a", "b", "c"])
    }

    func testRemoveAndReplace() {
        var set = RuleSet(rules: [rule("a", []), rule("b", [])])
        var b = set.rules[1]
        b.name = "renamed"
        set.replace(b)
        XCTAssertEqual(set.rules[1].name, "renamed")
        set.remove(id: set.rules[0].id)
        XCTAssertEqual(set.rules.map(\.name), ["renamed"])
    }

    func testRoundTripsThroughJSON() throws {
        let set = RuleSet(rules: [rule("a", [Condition(.host, .hostOrSubdomain, "x.com")])])
        let data = try JSONEncoder().encode(set)
        XCTAssertEqual(try JSONDecoder().decode(RuleSet.self, from: data), set)
    }

    func testSettingsFillInMissingKeys() throws {
        let c = try JSONDecoder().decode(Settings.self, from: Data("{\"idleThreshold\":300}".utf8))
        XCTAssertEqual(c.idleThreshold, 300)
        XCTAssertEqual(c.callIdleThreshold, Settings.default.callIdleThreshold)
    }
}

extension ConditionTests {
    /// Path scoping must work from host and path alone: imported observations
    /// carry no full URL string.
    func testUrlPrefixMatchesWithoutAFullURLString() {
        let bare = Snapshot(bundleId: "b", appName: "A", url: nil,
                            host: "github.com", urlPath: "/acme/api")
        XCTAssertTrue(Condition(.url, .urlPrefix, "github.com/acme").matches(bare))
        XCTAssertFalse(Condition(.url, .urlPrefix, "github.com/other").matches(bare))
    }

    func testUrlPrefixNeedsAHost() {
        let noHost = Snapshot(bundleId: "b", appName: "A")
        XCTAssertFalse(Condition(.url, .urlPrefix, "github.com/acme").matches(noHost))
    }
}
