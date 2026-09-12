import XCTest
@testable import SundialCore

final class InboxTests: XCTestCase {
    var folder: URL!
    var store: Store!

    override func setUp() {
        super.setUp()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        folder = tmp.appendingPathComponent("mirror")
        store = Store(root: tmp.appendingPathComponent("data"))
        try? FileManager.default.createDirectory(at: Inbox.directory(in: folder),
                                                 withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        super.tearDown()
    }

    var encoder: JSONEncoder {
        let e = JSONEncoder()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: d))
        }
        return e
    }

    func drop(_ name: String, _ value: some Encodable) throws {
        try encoder.encode(value)
            .write(to: Inbox.directory(in: folder).appendingPathComponent(name))
    }

    func testRuleFromThePhoneIsAdoptedAndRemoved() throws {
        let rule = Rule(name: "phone rule",
                        conditions: [Condition(.host, .hostOrSubdomain, "acme.com")], outcome: .work)
        try drop("rule-\(rule.id.uuidString).json", rule)

        var rules = RuleSet()
        let r = Inbox.drain(from: folder, into: store, rules: &rules)
        XCTAssertEqual(r.rulesAdded, 1)
        XCTAssertEqual(rules.rules.first?.name, "phone rule")
        XCTAssertTrue(try FileManager.default
            .contentsOfDirectory(atPath: Inbox.directory(in: folder).path).isEmpty)
    }

    /// Draining twice, or a file arriving after the Mac already has the rule,
    /// must not duplicate it.
    func testAlreadyKnownRuleIsNotAddedTwice() throws {
        let rule = Rule(name: "dupe", conditions: [Condition(.host, .equals, "x")], outcome: .work)
        try drop("rule-\(rule.id.uuidString).json", rule)
        var rules = RuleSet(rules: [rule])
        let r = Inbox.drain(from: folder, into: store, rules: &rules)
        XCTAssertEqual(r.rulesAdded, 0)
        XCTAssertEqual(rules.rules.count, 1)
    }

    /// A session the user started counts as time they were present for.
    func testSessionBecomesObservationAndPresence() throws {
        let start = Date().addingTimeInterval(-600)
        let span = ObservationSpan(start: start, end: start + 600,
                                   snapshot: Snapshot(bundleId: "sundial.phone.session",
                                                      appName: "Phone", workspace: "On call"))
        try drop("session-\(UUID().uuidString).json", span)

        var rules = RuleSet(rules: [Rule(name: "phone",
            conditions: [Condition(.workspace, .equals, "On call")], outcome: .work)])
        let r = Inbox.drain(from: folder, into: store, rules: &rules)
        XCTAssertEqual(r.sessionsAdded, 1)
        XCTAssertEqual(r.sessionSeconds, 600, accuracy: 1)

        let day = store.load(day: Format.day(start))
        XCTAssertEqual(day.observations.count, 1)
        let segs = Classifier(rules: rules, settings: .default)
            .classify(observations: day.observations, presence: day.presence)
        XCTAssertEqual(Totals.compute(segs).work, 600, accuracy: 5)
    }

    func testZeroLengthSessionIsDiscarded() throws {
        let now = Date()
        try drop("session-\(UUID().uuidString).json",
                 ObservationSpan(start: now, end: now,
                                 snapshot: Snapshot(bundleId: "b", appName: "Phone")))
        var rules = RuleSet()
        let r = Inbox.drain(from: folder, into: store, rules: &rules)
        XCTAssertEqual(r.sessionsAdded, 0)
        XCTAssertTrue(store.load(day: Format.day(now)).observations.isEmpty)
    }

    func testUnreadableDropIsCountedAndLeftAlone() throws {
        try Data("not json".utf8)
            .write(to: Inbox.directory(in: folder).appendingPathComponent("rule-bad.json"))
        var rules = RuleSet()
        let r = Inbox.drain(from: folder, into: store, rules: &rules)
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(rules.rules.count, 0)
        XCTAssertFalse(try FileManager.default
            .contentsOfDirectory(atPath: Inbox.directory(in: folder).path).isEmpty,
            "a bad drop stays put so it can be inspected")
    }

    func testMissingInboxIsHarmless() {
        var rules = RuleSet()
        let r = Inbox.drain(from: folder.appendingPathComponent("nope"), into: store, rules: &rules)
        XCTAssertEqual(r, Inbox.Result())
    }
}
