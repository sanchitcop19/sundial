import XCTest
@testable import SundialCore

final class WorkProgressSnapshotTests: XCTestCase {
    private var macCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ day: Int = 15, hour: Int = 12, minute: Int = 0) -> Date {
        macCalendar.date(from: DateComponents(year: 2026, month: 9, day: day,
                                             hour: hour, minute: minute))!
    }

    private func snapshot(at now: Date? = nil) -> WorkProgressSnapshot {
        let now = now ?? date()
        return WorkProgressSnapshot(day: Format.day(now, calendar: macCalendar),
                                    timeZoneIdentifier: macCalendar.timeZone.identifier,
                                    updatedAt: now.timeIntervalSince1970,
                                    worked: 6.5 * 3600, target: 8 * 3600,
                                    weeklyWorked: 14.5 * 3600, weeklyTarget: 40 * 3600,
                                    state: "work", isPaused: false)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testSnapshotRoundTripPreservesAllFieldsAndUnixTimestamp() throws {
        let original = snapshot()
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WorkProgressSnapshot.self, from: encoded), original)
        let json = try object(original)
        XCTAssertEqual(Set(json.keys), ["day", "timeZoneIdentifier", "updatedAt", "worked", "target",
                                        "weeklyWorked", "weeklyTarget", "state", "isPaused"])
        XCTAssertEqual(try XCTUnwrap(json["updatedAt"] as? Double), date().timeIntervalSince1970)
        XCTAssertTrue(original.isValid)
    }

    func testUpdatePayloadUsesExactActivityKitEnvelope() throws {
        let original = snapshot()
        let now = date().addingTimeInterval(12)
        let json = try object(LiveActivityPushPayload(snapshot: original, now: now))
        XCTAssertEqual(Set(json.keys), ["aps"])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(Set(aps.keys), ["timestamp", "event", "content-state", "stale-date"])
        XCTAssertEqual(aps["event"] as? String, "update")
        XCTAssertEqual(aps["timestamp"] as? Int, Int(now.timeIntervalSince1970))
        XCTAssertEqual(aps["stale-date"] as? Int, Int(date().timeIntervalSince1970) + 300)
        let content = try XCTUnwrap(aps["content-state"] as? [String: Any])
        let decoded = try JSONDecoder().decode(WorkProgressSnapshot.self,
                                               from: JSONSerialization.data(withJSONObject: content))
        XCTAssertEqual(decoded, original)
    }

    func testEndPayloadDismissesAtTheGivenTime() throws {
        let now = date().addingTimeInterval(60)
        let json = try object(LiveActivityPushPayload(snapshot: snapshot(), ending: true, now: now))
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(Set(aps.keys), ["timestamp", "event", "content-state", "stale-date", "dismissal-date"])
        XCTAssertEqual(aps["event"] as? String, "end")
        XCTAssertEqual(aps["dismissal-date"] as? Int, Int(now.timeIntervalSince1970))
    }

    func testRemainingClampsAtZeroWhenTargetIsReachedOrExceeded() {
        var progress = snapshot()
        XCTAssertEqual(progress.remaining, 1.5 * 3600)
        progress.worked = progress.target
        XCTAssertEqual(progress.remaining, 0)
        progress.worked += 3600
        XCTAssertEqual(progress.remaining, 0)
        progress.target = 0
        XCTAssertEqual(progress.remaining, 0)
    }

    func testProgressBecomesStaleAtFiveMinutes() {
        let progress = snapshot()
        XCTAssertEqual(progress.staleDate, date().addingTimeInterval(300))
        XCTAssertFalse(progress.isStale(at: date().addingTimeInterval(299.9)))
        XCTAssertTrue(progress.isStale(at: date().addingTimeInterval(300)))
    }

    func testOvertimeStartsOnlyAfterAPositiveTargetIsExceeded() {
        var progress = snapshot()
        XCTAssertFalse(progress.isOverTarget)
        XCTAssertEqual(progress.overtime, 0)
        progress.worked = progress.target
        XCTAssertFalse(progress.isOverTarget)
        XCTAssertEqual(progress.overtime, 0)
        progress.worked += 1
        XCTAssertTrue(progress.isOverTarget)
        XCTAssertEqual(progress.overtime, 1)
        progress.worked += 899
        XCTAssertEqual(progress.overtime, 900)
    }

    func testUnplannedDayNeverShowsOvertime() {
        var progress = snapshot()
        progress.target = 0
        XCTAssertFalse(progress.isOverTarget)
        XCTAssertEqual(progress.overtime, 0)
    }

    func testAutomaticWindowEndRoundTripsWithoutChangingOlderSnapshots() throws {
        var progress = snapshot(at: date(hour: 23))
        progress.automaticActivityEnd = date(16, hour: 2).timeIntervalSince1970
        XCTAssertTrue(progress.isValid)
        let data = try JSONEncoder().encode(progress)
        XCTAssertEqual(try JSONDecoder().decode(WorkProgressSnapshot.self, from: data), progress)
        let legacy = try JSONEncoder().encode(snapshot())
        XCTAssertNil(try JSONDecoder().decode(WorkProgressSnapshot.self, from: legacy).automaticActivityEnd)
    }

    func testStopPausesThroughOvernightWindowBeforeAndAfterMidnight() {
        var progress = snapshot(at: date(hour: 23))
        let end = date(16, hour: 2)
        progress.automaticActivityEnd = end.timeIntervalSince1970
        XCTAssertEqual(progress.automaticPauseDeadline(at: date(hour: 23, minute: 30)), end)
        XCTAssertEqual(progress.automaticPauseDeadline(at: date(16, hour: 1)), end)
        XCTAssertEqual(progress.automaticPauseDeadline(at: end), date(17, hour: 0))
    }

    func testStopWithoutAnActiveWindowUsesCurrentMacDaysEnd() {
        let progress = snapshot(at: date(hour: 23))
        XCTAssertEqual(progress.automaticPauseDeadline(at: date(hour: 23)), date(16, hour: 0))
        XCTAssertEqual(progress.automaticPauseDeadline(at: date(16, hour: 1)), date(17, hour: 0))
    }

    func testInvalidWindowEndCannotCreateAnIndefinitePause() {
        var progress = snapshot()
        progress.automaticActivityEnd = .infinity
        XCTAssertFalse(progress.isValid)
        XCTAssertEqual(progress.automaticPauseDeadline(at: date()), date(16, hour: 0))
        progress.automaticActivityEnd = date().addingTimeInterval(26 * 3600 + 1).timeIntervalSince1970
        XCTAssertFalse(progress.isValid)
        progress.automaticActivityEnd = date().addingTimeInterval(-1).timeIntervalSince1970
        XCTAssertFalse(progress.isValid)
    }

    func testMacMidnightExpiresProgressEvenWhenPhoneHasAnotherDate() {
        let updated = date(hour: 23, minute: 59)
        let progress = snapshot(at: updated)
        var phoneCalendar = macCalendar
        phoneCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(Format.day(updated, calendar: phoneCalendar), "2026-09-16")
        XCTAssertEqual(progress.day, "2026-09-15")
        XCTAssertTrue(progress.isValid)
        XCTAssertFalse(progress.isStale(at: updated))
        XCTAssertEqual(progress.staleDate, date(16, hour: 0))
        XCTAssertTrue(progress.isStale(at: date(16, hour: 0)))
    }

    func testFutureClockSkewAllowsOnlyOneMinute() {
        let progress = snapshot()
        XCTAssertFalse(progress.isStale(at: date().addingTimeInterval(-60)))
        XCTAssertTrue(progress.isStale(at: date().addingTimeInterval(-61)))
    }

    func testMissingAndInvalidTimeZonesAreRejected() throws {
        var json = try object(snapshot())
        json.removeValue(forKey: "timeZoneIdentifier")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkProgressSnapshot.self, from: data))
        var invalid = snapshot()
        invalid.timeZoneIdentifier = "Invalid/Zone"
        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(invalid.isStale(at: date()))
    }

    func testInvalidProgressValuesAreRejected() {
        var invalid = snapshot()
        invalid.target = -1
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.target = 24 * 3600 + 1
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.worked = -1
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.updatedAt = .nan
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.weeklyWorked = .infinity
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.weeklyTarget = -1
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.state = "unknown"
        XCTAssertFalse(invalid.isValid)
    }

    func testSnapshotDateMustBeRealAndMatchItsMacTimestamp() {
        for day in ["abcdefghij", "2026-99-99", "2026-02-30", "2026-9-15", "2026-09-14"] {
            var invalid = snapshot()
            invalid.day = day
            XCTAssertFalse(invalid.isValid, day)
            XCTAssertTrue(invalid.isStale(at: date()), day)
        }
    }

    func testFiniteButImpossibleDurationsAreRejectedBeforeDisplayFormatting() {
        var invalid = snapshot()
        invalid.worked = 1e308
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.weeklyWorked = 1e308
        XCTAssertFalse(invalid.isValid)
        invalid = snapshot(); invalid.weeklyTarget = 1e308
        XCTAssertFalse(invalid.isValid)
    }

    func testWorkBoundsRespectDaylightSavingDayAndWeekLengths() {
        let fallBack = macCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1,
                                                              hour: 23, minute: 59))!
        var progress = snapshot(at: fallBack)
        progress.worked = 25 * 3600
        progress.weeklyWorked = 169 * 3600
        XCTAssertTrue(progress.isValid)
        progress.worked += 1
        XCTAssertFalse(progress.isValid)

        let springForward = macCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8,
                                                                   hour: 23, minute: 59))!
        progress = snapshot(at: springForward)
        progress.worked = 23 * 3600
        progress.target = 24 * 3600
        XCTAssertTrue(progress.isValid, "A configured target may exceed the shortened day's capacity")
        progress.worked += 1
        XCTAssertFalse(progress.isValid)
    }

    private func registration() -> LiveActivityRegistration {
        LiveActivityRegistration(id: "activity-1", token: String(repeating: "ab", count: 32),
                                 environment: "sandbox", day: "2026-09-15",
                                 expiresAt: date().addingTimeInterval(3600).timeIntervalSince1970)
    }

    func testRegistrationAcceptsValidEnvironmentsAndRoundTrips() throws {
        var registration = registration()
        XCTAssertTrue(registration.isValid(at: date()))
        registration.environment = "production"
        XCTAssertTrue(registration.isValid(at: date()))
        let encoded = try JSONEncoder().encode(registration)
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityRegistration.self, from: encoded), registration)
    }

    func testRegistrationRejectsInvalidTokensEnvironmentAndExpiry() {
        for token in ["", "ab", String(repeating: "a", count: 33),
                      String(repeating: "a", count: 514), String(repeating: "gg", count: 32),
                      String(repeating: "ａ", count: 64)] {
            var invalid = registration()
            invalid.token = token
            XCTAssertFalse(invalid.isValid(at: date()), "Unexpected valid token: \(token)")
        }
        var invalid = registration(); invalid.environment = "development"
        XCTAssertFalse(invalid.isValid(at: date()))
        invalid = registration(); invalid.id = ""
        XCTAssertFalse(invalid.isValid(at: date()))
        invalid = registration(); invalid.expiresAt = date().timeIntervalSince1970
        XCTAssertFalse(invalid.isValid(at: date()))
        invalid.expiresAt -= 1
        XCTAssertFalse(invalid.isValid(at: date()))
        invalid.expiresAt = .infinity
        XCTAssertFalse(invalid.isValid(at: date()))
    }

    func testRegistrationRequiresStrictGregorianDate() {
        for day in ["abcdefghij", "2026-99-99", "2026-02-30", "2026-9-15"] {
            var invalid = registration()
            invalid.day = day
            XCTAssertFalse(invalid.isValid(at: date()), day)
        }
    }

    func testExpiredRegistrationRemainsWellFormedSoProviderCanEndActivity() {
        var expired = registration()
        expired.expiresAt = date().timeIntervalSince1970
        XCTAssertTrue(expired.isWellFormed)
        XCTAssertFalse(expired.isValid(at: date()))
        expired.token = "invalid"
        XCTAssertFalse(expired.isWellFormed)
    }

    func testAutomaticRegistrationRemainsCurrentAcrossMidnight() {
        var activity = registration()
        activity.automatic = true
        activity.expiresAt = date(16, hour: 2).timeIntervalSince1970
        let nextDay = snapshot(at: date(16, hour: 1))
        XCTAssertTrue(activity.isCurrent(for: nextDay, at: date(16, hour: 1)))
        XCTAssertFalse(activity.isCurrent(for: nextDay, at: date(16, hour: 2)))
        activity.automatic = false
        XCTAssertFalse(activity.isCurrent(for: nextDay, at: date(16, hour: 1)))
        activity.automatic = nil
        XCTAssertFalse(activity.isCurrent(for: nextDay, at: date(16, hour: 1)))
    }
}
