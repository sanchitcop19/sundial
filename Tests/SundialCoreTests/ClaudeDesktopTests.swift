import XCTest
@testable import SundialCore

final class ClaudeDesktopTests: XCTestCase {
    func tag(_ json: String) -> String? {
        ClaudeDesktop.accountTag(fromConfig: Data(json.utf8))
    }

    func testReadsTheSignedInAccount() {
        XCTAssertEqual(tag(#"{"locale":"en-US","lastKnownAccountUuid":"D669A9EB-093E-4987-8178-8474A5599CD3","oauth:tokenCache":"x"}"#),
                       "d669a9eb")
    }

    func testSignedOutOrMalformedHasNoAccount() {
        XCTAssertNil(tag(#"{"locale":"en-US"}"#))
        XCTAssertNil(tag(#"{"lastKnownAccountUuid":"not-a-uuid"}"#))
        XCTAssertNil(tag(#"{"lastKnownAccountUuid":42}"#))
        XCTAssertNil(tag("[]"))
        XCTAssertNil(tag("garbage"))
    }

    func testConfigLivesInTheAppsSupportFolder() {
        let url = ClaudeDesktop.configURL(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(url.path, "/Users/x/Library/Application Support/Claude/config.json")
    }

    func testAccountRuleBeatsTheWholeAppRule() {
        var rules = RuleSet(rules: [Rule(name: "All of Claude",
            conditions: [Condition(.bundleId, .equals, ClaudeDesktop.bundleId)], outcome: .personal)])
        rules.insertBySpecificity(Rule(name: "Claude work account",
            conditions: [Condition(.bundleId, .equals, ClaudeDesktop.bundleId),
                         Condition(.workspace, .equals, "d669a9eb")], outcome: .work))
        let work = Snapshot(bundleId: ClaudeDesktop.bundleId, appName: "Claude", workspace: "d669a9eb")
        let personal = Snapshot(bundleId: ClaudeDesktop.bundleId, appName: "Claude", workspace: "a7878de6")
        XCTAssertEqual(rules.match(work)?.outcome, .work)
        XCTAssertEqual(rules.match(personal)?.outcome, .personal)
    }
}
