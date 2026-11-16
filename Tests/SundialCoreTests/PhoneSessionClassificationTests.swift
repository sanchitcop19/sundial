import XCTest
@testable import SundialCore

/// Phone time is something the user said happened. A locked or sleeping Mac is
/// the usual reason they were on the phone, so it must not swallow the entry.
final class PhoneSessionClassificationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func phone(_ a: TimeInterval, _ b: TimeInterval, _ label: String = "Calls") -> ObservationSpan {
        ObservationSpan(start: at(a), end: at(b),
                        snapshot: Snapshot(bundleId: MobileSession.bundleId, appName: "Phone",
                                           windowTitle: label, workspace: label))
    }

    func mac(_ a: TimeInterval, _ b: TimeInterval) -> ObservationSpan {
        ObservationSpan(start: at(a), end: at(b),
                        snapshot: Snapshot(bundleId: "com.editor", appName: "Editor",
                                           host: "acme.com"))
    }

    func rules(_ outcome: Outcome = .work) -> RuleSet {
        RuleSet(rules: [
            Rule(name: "Phone: Calls",
                 conditions: [Condition(.bundleId, .equals, MobileSession.bundleId),
                              Condition(.workspace, .equals, "Calls")],
                 outcome: outcome, origin: .manual),
            Rule(name: "work site",
                 conditions: [Condition(.host, .hostOrSubdomain, "acme.com")], outcome: .work),
        ])
    }

    func totals(_ obs: [ObservationSpan], _ presence: PresenceLog,
                _ r: RuleSet? = nil) -> Totals {
        Totals.compute(Classifier(rules: r ?? rules())
            .classify(observations: obs, presence: presence))
    }

    func testPhoneTimeCountsWhileTheScreenIsLocked() {
        let p = PresenceLog(input: [Span(at(1800), at(3600))],
                            absent: [Span(at(0), at(3600))])
        let t = totals([phone(600, 2400)], p)
        XCTAssertEqual(t.work, 1800, accuracy: 1)
        XCTAssertEqual(t.away, 1800, accuracy: 1, "only the rest of the lock stays away")
    }

    func testPhoneTimeCountsWhileTheMachineIsAsleep() {
        let p = PresenceLog(offline: [Span(at(0), at(3600))])
        let t = totals([phone(0, 1800)], p)
        XCTAssertEqual(t.work, 1800, accuracy: 1)
        XCTAssertEqual(t.away, 1800, accuracy: 1)
    }

    func testPhoneTimeUsesItsRuleOutcome() {
        let p = PresenceLog(absent: [Span(at(0), at(1800))])
        let t = totals([phone(0, 1800)], p, rules(.personal))
        XCTAssertEqual(t.personal, 1800, accuracy: 1)
        XCTAssertEqual(t.work, 0, accuracy: 1)
    }

    /// Entering phone time while also at the Mac must count the hour once.
    func testPhoneTimeWinsOverMacActivityItOverlaps() {
        let p = PresenceLog(input: (0...36).map { Span(at(Double($0) * 100), at(Double($0) * 100)) })
        let segs = Classifier(rules: rules(.personal))
            .classify(observations: [mac(0, 3600), phone(1200, 2400)], presence: p)
        let t = Totals.compute(segs)
        XCTAssertEqual(t.personal, 1200, accuracy: 2)
        XCTAssertEqual(t.work, 2400, accuracy: 2)
        XCTAssertEqual(t.work + t.personal + t.away + t.unclassified, 3600, accuracy: 2)
    }

    func testOverlappingPhoneEntriesStillCountOnce() {
        let p = PresenceLog(absent: [Span(at(0), at(3600))])
        let t = totals([phone(0, 1800), phone(900, 2700)], p)
        XCTAssertEqual(t.work, 2700, accuracy: 1)
    }

    /// Regression: ordinary observations still obey the lock.
    func testMacActivityWhileLockedStillCountsAsAway() {
        let p = PresenceLog(input: [Span(at(0), at(1800))], absent: [Span(at(0), at(1800))])
        let t = totals([mac(0, 1800)], p)
        XCTAssertEqual(t.work, 0, accuracy: 1)
        XCTAssertEqual(t.away, 1800, accuracy: 1)
    }
}
