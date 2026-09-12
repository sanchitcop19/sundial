import XCTest
@testable import SundialCore

final class ClassifierTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func snap(_ host: String? = nil, bundle: String = "com.editor",
              project: String? = nil, path: String? = nil) -> Snapshot {
        Snapshot(bundleId: bundle, appName: "App",
                 url: host.map { "https://\($0)\(path ?? "")" }, host: host, urlPath: path,
                 projectPath: project)
    }

    func obs(_ a: TimeInterval, _ b: TimeInterval, _ s: Snapshot) -> ObservationSpan {
        ObservationSpan(start: at(a), end: at(b), snapshot: s)
    }

    /// Continuous typing across the whole window.
    func typing(_ a: TimeInterval, _ b: TimeInterval, every: TimeInterval = 5) -> [Span] {
        stride(from: a, through: b, by: every).map { Span(at($0), at($0)) }
    }

    func workRules() -> RuleSet {
        RuleSet(rules: [Rule(name: "work site",
                             conditions: [Condition(.host, .hostOrSubdomain, "acme.com")],
                             outcome: .work)])
    }

    // MARK: presence

    func testActiveTimeOnAWorkSiteCountsAsWork() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 600, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 600)))
        XCTAssertEqual(Totals.compute(segs).work, 600, accuracy: 1)
    }

    /// The headline case: an agent left running with nobody at the keyboard.
    func testSilenceBecomesAwayAtTheThreshold() {
        var s = Settings.default
        s.idleThreshold = 120
        let segs = Classifier(rules: workRules(), settings: s)
            .classify(observations: [obs(0, 3600, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 600)))
        let t = Totals.compute(segs)
        // Work runs to the last keystroke plus the 120s grace, then stops.
        XCTAssertEqual(t.work, 720, accuracy: 2)
        XCTAssertEqual(t.away, 2880, accuracy: 2)
    }

    /// Sitting still in a meeting is still working, whatever app the call is in.
    func testCallKeepsYouPresentThroughSilence() {
        var s = Settings.default
        s.idleThreshold = 120
        s.callIdleThreshold = 3600
        let segs = Classifier(rules: workRules(), settings: s)
            .classify(observations: [obs(0, 1800, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 60),
                                            call: [Span(at(0), at(1800))]))
        XCTAssertEqual(Totals.compute(segs).work, 1800, accuracy: 5)
    }

    func testCallEndingReinstatesTheShorterThreshold() {
        var s = Settings.default
        s.idleThreshold = 120
        s.callIdleThreshold = 3600
        let segs = Classifier(rules: workRules(), settings: s)
            .classify(observations: [obs(0, 3600, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 60), call: [Span(at(0), at(600))]))
        let t = Totals.compute(segs)
        XCTAssertLessThan(t.work, 900, "once the call ends the ordinary idle rule applies")
        XCTAssertGreaterThan(t.away, 2000)
    }

    func testLockedScreenIsAwayEvenWhileTyping() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 600, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 600), absent: [Span(at(0), at(600))]))
        XCTAssertEqual(Totals.compute(segs).away, 600, accuracy: 1)
    }

    func testOfflineGapIsAwayNotCreditedToTheLastApp() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 60, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 60),
                                            offline: [Span(at(60), at(3660))]))
        let t = Totals.compute(segs)
        XCTAssertEqual(t.work, 60, accuracy: 2)
        XCTAssertEqual(t.away, 3600, accuracy: 2)
    }

    func testNoInputAtAllIsAway() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 600, snap("acme.com"))], presence: PresenceLog())
        XCTAssertEqual(Totals.compute(segs).away, 600, accuracy: 1)
    }

    // MARK: content

    func testUnmatchedSnapshotIsUnclassifiedNotGuessed() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 300, snap("random.example"))],
                      presence: PresenceLog(input: typing(0, 300)))
        XCTAssertEqual(Totals.compute(segs).unclassified, 300, accuracy: 1)
        XCTAssertEqual(Totals.compute(segs).work, 0)
    }

    func testReviewQueueGroupsAndRanksUnclassifiedTime() {
        let segs = Classifier(rules: RuleSet())
            .classify(observations: [obs(0, 60, snap("a.example")),
                                     obs(60, 400, snap("b.example")),
                                     obs(400, 460, snap("a.example"))],
                      presence: PresenceLog(input: typing(0, 460)))
        let review = ReviewItem.build(from: segs)
        XCTAssertEqual(review.first?.snapshot.host, "b.example")
        XCTAssertEqual(review.count, 2)
        XCTAssertEqual(review.first?.seconds ?? 0, 340, accuracy: 5)
        XCTAssertEqual(review.last?.occurrences, 2)
    }

    /// The property the whole design exists for: a rule added now changes what
    /// time recorded earlier counts as.
    func testChangingRulesReclassifiesPastTime() {
        let observations = [obs(0, 600, snap("newtool.example"))]
        let presence = PresenceLog(input: typing(0, 600))

        let before = Classifier(rules: RuleSet()).classify(observations: observations, presence: presence)
        XCTAssertEqual(Totals.compute(before).unclassified, 600, accuracy: 1)

        let after = Classifier(rules: RuleSet(rules: [
            Rule(name: "new tool", conditions: [Condition(.host, .hostOrSubdomain, "newtool.example")],
                 outcome: .work)])).classify(observations: observations, presence: presence)
        XCTAssertEqual(Totals.compute(after).work, 600, accuracy: 1)
        XCTAssertEqual(Totals.compute(after).unclassified, 0)
    }

    /// Thresholds are settings, not baked-in decisions, so they also apply to
    /// history.
    func testChangingIdleThresholdReclassifiesPastTime() {
        let observations = [obs(0, 1800, snap("acme.com"))]
        let presence = PresenceLog(input: typing(0, 300))
        var tight = Settings.default; tight.idleThreshold = 60
        var loose = Settings.default; loose.idleThreshold = 900

        let a = Totals.compute(Classifier(rules: workRules(), settings: tight)
            .classify(observations: observations, presence: presence))
        let b = Totals.compute(Classifier(rules: workRules(), settings: loose)
            .classify(observations: observations, presence: presence))
        XCTAssertEqual(a.work, 360, accuracy: 5)
        XCTAssertEqual(b.work, 1200, accuracy: 5)
    }

    func testNeighbouringIdenticalStretchesAreJoined() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 100, snap("acme.com")),
                                     obs(100, 200, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 200)))
        XCTAssertEqual(segs.filter { $0.state == .work }.count, 1)
    }

    func testDifferentSitesStaySeparate() {
        let rules = RuleSet(rules: [
            Rule(name: "acme", conditions: [Condition(.host, .hostOrSubdomain, "acme.com")], outcome: .work),
            Rule(name: "other", conditions: [Condition(.host, .hostOrSubdomain, "other.com")], outcome: .work),
        ])
        let segs = Classifier(rules: rules)
            .classify(observations: [obs(0, 100, snap("acme.com")), obs(100, 200, snap("other.com"))],
                      presence: PresenceLog(input: typing(0, 200)))
        XCTAssertEqual(segs.filter { $0.state == .work }.count, 2)
    }

    func testSegmentCarriesTheRuleThatDecidedIt() {
        let segs = Classifier(rules: workRules())
            .classify(observations: [obs(0, 100, snap("acme.com"))],
                      presence: PresenceLog(input: typing(0, 100)))
        XCTAssertEqual(segs.first(where: { $0.state == .work })?.ruleName, "work site")
        XCTAssertTrue(segs.first(where: { $0.state == .work })?.reason.contains("acme.com") ?? false)
    }

    func testEmptyInputProducesNoSegments() {
        XCTAssertTrue(Classifier(rules: RuleSet())
            .classify(observations: [], presence: PresenceLog()).isEmpty)
    }

    func testPreviewExplainsASnapshotWithoutTime() {
        let c = Classifier(rules: workRules())
        XCTAssertEqual(c.preview(snap("acme.com")).state, .work)
        XCTAssertEqual(c.preview(snap("nope.example")).state, .unclassified)
    }
}
