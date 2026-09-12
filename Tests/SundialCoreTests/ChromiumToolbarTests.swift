import XCTest
@testable import SundialCore

final class ChromiumToolbarTests: XCTestCase {
    func b(_ depth: Int, _ desc: String, _ role: String = "button") -> ChromiumToolbar.Button {
        ChromiumToolbar.Button(depth: depth, description: desc, roleDescription: role)
    }

    /// The real toolbar of a Chrome window, in traversal order.
    var realWindow: [ChromiumToolbar.Button] {
        [b(1, "", "close button"), b(1, "", "full screen button"), b(1, "", "minimize button"),
         b(6, "New Tab"), b(7, "Back"), b(7, "Forward"), b(7, "Reload"),
         b(7, "Open tab in split view"),
         b(7, "Sanchit"),
         b(7, "Venmo", "bookmark button"),
         b(7, "Unnamed bookmark for https://example.com", "bookmark button")]
    }

    func testFindsTheProfileChip() {
        XCTAssertEqual(ChromiumToolbar.profileName(from: realWindow), "Sanchit")
    }

    func testWorkProfileNameIsReturnedVerbatim() {
        var w = realWindow
        w[8] = b(7, "Work")
        XCTAssertEqual(ChromiumToolbar.profileName(from: w), "Work")
    }

    /// Bookmarks are named by the user and would otherwise look exactly like a
    /// profile, so scanning stops when the bookmarks bar begins.
    func testBookmarksAreNeverMistakenForAProfile() {
        let noProfile = [b(7, "Back"), b(7, "Forward"), b(7, "Reload"),
                         b(7, "Venmo", "bookmark button"), b(7, "Payroll", "bookmark button")]
        XCTAssertNil(ChromiumToolbar.profileName(from: noProfile))
    }

    func testStandardCommandsAreIgnored() {
        let onlyCommands = [b(7, "Back"), b(7, "Forward"), b(7, "Reload"),
                            b(7, "Extensions"), b(7, "Tab Search"), b(7, "You")]
        XCTAssertNil(ChromiumToolbar.profileName(from: onlyCommands))
    }

    func testCommandMatchingIgnoresCase() {
        let mixed = [b(7, "Back"), b(7, "Forward"), b(7, "Reload"), b(7, "EXTENSIONS"), b(7, "Ana")]
        XCTAssertEqual(ChromiumToolbar.profileName(from: mixed), "Ana")
    }

    /// Only the row holding back/forward/reload is the toolbar; a control
    /// elsewhere in the window must not be read as a profile.
    func testOnlyTheNavigationRowIsTrusted() {
        let elsewhere = [b(7, "Back"), b(7, "Forward"), b(7, "Reload"),
                         b(12, "Some Page Button")]
        XCTAssertNil(ChromiumToolbar.profileName(from: elsewhere))
    }

    func testWindowWithoutNavigationButtonsYieldsNothing() {
        XCTAssertNil(ChromiumToolbar.profileName(from: [b(7, "Sanchit")]))
        XCTAssertNil(ChromiumToolbar.profileName(from: []))
    }

    func testUrlLikeAndOverlongLabelsAreRejected() {
        let odd = [b(7, "Back"), b(7, "Forward"), b(7, "Reload"),
                   b(7, "https://example.com/thing"),
                   b(7, String(repeating: "x", count: 80)),
                   b(7, "Work")]
        XCTAssertEqual(ChromiumToolbar.profileName(from: odd), "Work")
    }

    /// The point of all this: two profiles in one browser get different rules.
    func testProfilesDriveDifferentVerdicts() {
        var rules = RuleSet()
        rules.insertBySpecificity(Rule(name: "Work profile",
            conditions: [Condition(.bundleId, .equals, "com.google.Chrome"),
                         Condition(.browserProfile, .equals, "Work")], outcome: .work))
        rules.insertBySpecificity(Rule(name: "Personal profile",
            conditions: [Condition(.bundleId, .equals, "com.google.Chrome"),
                         Condition(.browserProfile, .equals, "Personal")], outcome: .personal))

        func snap(_ profile: String) -> Snapshot {
            Snapshot(bundleId: "com.google.Chrome", appName: "Chrome",
                     url: "https://mail.google.com/", host: "mail.google.com",
                     urlPath: "/", browserProfile: profile)
        }
        XCTAssertEqual(rules.match(snap("Work"))?.outcome, .work)
        XCTAssertEqual(rules.match(snap("Personal"))?.outcome, .personal)
        XCTAssertNil(rules.match(snap("Other")), "an unknown profile is surfaced, not guessed")
    }

    func testProfileScopeIsOfferedWhenCorrecting() {
        let snap = Snapshot(bundleId: "com.google.Chrome", appName: "Chrome",
                            url: "https://mail.google.com/", host: "mail.google.com",
                            urlPath: "/", browserProfile: "Work")
        let profile = Suggestions.build(for: snap).first { $0.scope == .profile }
        XCTAssertEqual(profile?.conditions.last?.value, "Work")
        XCTAssertTrue(profile?.title.contains("Work") ?? false)
    }
}
