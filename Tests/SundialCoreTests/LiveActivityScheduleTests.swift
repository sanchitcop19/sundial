import XCTest
@testable import SundialCore

final class LiveActivityScheduleTests: XCTestCase {
    private let deviceID = "D835CB2C-8498-47EA-B55D-BF1682A4C151"

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func snapshot(at now: Date) -> WorkProgressSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return WorkProgressSnapshot(day: Format.day(now, calendar: calendar),
                                    timeZoneIdentifier: calendar.timeZone.identifier,
                                    updatedAt: now.timeIntervalSince1970,
                                    worked: 3 * 3600, target: 8 * 3600,
                                    state: "work", isPaused: false)
    }

    func testFixedWindowStartsAtConfiguredTimeAndExcludesItsEnd() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 9 * 60 + 15,
                                            endRule: .time, endMinute: 18 * 60)
        let start = date("2026-09-15T09:15:00-07:00")
        let end = date("2026-09-15T18:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: start.addingTimeInterval(-1)),
                                     now: start.addingTimeInterval(-1)))
        XCTAssertEqual(schedule.window(for: snapshot(at: start), now: start),
                       DateInterval(start: start, end: end))
        XCTAssertNotNil(schedule.window(for: snapshot(at: end.addingTimeInterval(-1)),
                                        now: end.addingTimeInterval(-1)))
        XCTAssertNil(schedule.window(for: snapshot(at: end), now: end))
    }

    func testWindowUsesMacTimeZoneAndCanContinueBeyondOneActivityLifetime() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 9 * 60, endRule: .midnight)
        let now = date("2026-09-16T03:00:00Z") // 8 p.m. on the Mac's previous date.
        let window = schedule.window(for: snapshot(at: now), now: now)
        XCTAssertEqual(window, DateInterval(start: date("2026-09-15T09:00:00-07:00"),
                                            end: date("2026-09-16T00:00:00-07:00")))
        XCTAssertGreaterThan(window!.duration, LiveActivitySchedule.maximumActivityDuration)
        XCTAssertEqual(LiveActivitySchedule.maximumActivityDuration, 8 * 3600)
    }

    func testExistingSavedScheduleDefaultsToEveryDay() throws {
        let data = Data("""
        {"enabled":true,"startMinute":540,"endRule":"targetReached","endMinute":1080}
        """.utf8)
        let schedule = try JSONDecoder().decode(LiveActivitySchedule.self, from: data)
        XCTAssertEqual(schedule, LiveActivitySchedule(enabled: true))
        let sunday = date("2026-09-20T12:00:00-07:00")
        XCTAssertNotNil(schedule.window(for: snapshot(at: sunday), now: sunday))
    }

    func testWeekdayOvernightScheduleRoundTrips() throws {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .time, endMinute: 2 * 60, days: .weekdays)
        XCTAssertEqual(try JSONDecoder().decode(LiveActivitySchedule.self,
                                                from: JSONEncoder().encode(schedule)), schedule)
    }

    func testWeekdayWindowStartsMondayAtSevenAndContinuesUntilTuesdayAtTwo() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .time, endMinute: 2 * 60, days: .weekdays)
        let start = date("2026-09-14T07:00:00-07:00")
        let end = date("2026-09-15T02:00:00-07:00")
        let expected = DateInterval(start: start, end: end)
        let before = start.addingTimeInterval(-1)
        let overnight = date("2026-09-15T01:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: before), now: before))
        XCTAssertEqual(schedule.window(for: snapshot(at: start), now: start), expected)
        XCTAssertEqual(schedule.window(for: snapshot(at: overnight), now: overnight), expected)
        XCTAssertFalse(schedule.shouldEndCurrentActivity(for: snapshot(at: overnight), now: overnight))
        XCTAssertNil(schedule.window(for: snapshot(at: end), now: end))
        XCTAssertTrue(schedule.shouldEndCurrentActivity(for: snapshot(at: end), now: end))
        XCTAssertEqual(expected.duration, 19 * 3600)
    }

    func testWeekdayWindowIncludesFridayNightAndEarlySaturdayButNoWeekendStarts() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .time, endMinute: 2 * 60, days: .weekdays)
        let fridayNight = date("2026-09-18T23:00:00-07:00")
        let saturdayEarly = date("2026-09-19T01:00:00-07:00")
        let expected = DateInterval(start: date("2026-09-18T07:00:00-07:00"),
                                    end: date("2026-09-19T02:00:00-07:00"))
        XCTAssertEqual(schedule.window(for: snapshot(at: fridayNight), now: fridayNight), expected)
        XCTAssertEqual(schedule.window(for: snapshot(at: saturdayEarly), now: saturdayEarly), expected)
        let saturdayEnd = date("2026-09-19T02:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: saturdayEnd), now: saturdayEnd))
        let saturdayDay = date("2026-09-19T12:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: saturdayDay), now: saturdayDay))
        let sundayEarly = date("2026-09-20T01:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: sundayEarly), now: sundayEarly))
        let sundayDay = date("2026-09-20T12:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: sundayDay), now: sundayDay))
        let mondayEarly = date("2026-09-21T01:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: mondayEarly), now: mondayEarly))
    }

    func testOvernightWindowRequiresFreshProgressForTheCurrentCalendarDay() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .time, endMinute: 2 * 60, days: .weekdays)
        let midnight = date("2026-09-15T00:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: midnight.addingTimeInterval(-1)), now: midnight))
        XCTAssertEqual(schedule.window(for: snapshot(at: midnight), now: midnight),
                       DateInterval(start: date("2026-09-14T07:00:00-07:00"),
                                    end: date("2026-09-15T02:00:00-07:00")))
        XCTAssertNil(schedule.window(for: snapshot(at: midnight), now: midnight.addingTimeInterval(300)))
    }

    func testWeekdayMidnightAndTargetRulesDoNotCarryIntoSaturday() {
        let saturday = date("2026-09-19T01:00:00-07:00")
        let progress = snapshot(at: saturday)
        let midnight = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .midnight, days: .weekdays)
        XCTAssertNil(midnight.window(for: progress, now: saturday))
        let target = LiveActivitySchedule(enabled: true, startMinute: 7 * 60, days: .weekdays)
        XCTAssertNil(target.window(for: progress, now: saturday))
    }

    func testPreviousDaySnapshotCannotStartNextDaysWindow() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 0, endRule: .midnight)
        let midnight = date("2026-09-16T00:00:00-07:00")
        XCTAssertNil(schedule.window(for: snapshot(at: midnight.addingTimeInterval(-1)), now: midnight))
        XCTAssertEqual(schedule.window(for: snapshot(at: midnight), now: midnight),
                       DateInterval(start: midnight, end: date("2026-09-17T00:00:00-07:00")))
    }

    func testTargetRuleStopsRenewalAtGoalButKeepsCurrentActivityForOvertime() {
        let schedule = LiveActivitySchedule(enabled: true)
        let now = date("2026-09-15T12:00:00-07:00")
        var progress = snapshot(at: now)
        XCTAssertNotNil(schedule.window(for: progress, now: now))
        XCTAssertFalse(schedule.shouldEndCurrentActivity(for: progress, now: now))
        progress.worked = progress.target
        XCTAssertNil(schedule.window(for: progress, now: now))
        XCTAssertNotNil(schedule.activeWindow(for: progress, now: now))
        XCTAssertFalse(schedule.shouldEndCurrentActivity(for: progress, now: now))
        progress.worked += 1
        XCTAssertNil(schedule.window(for: progress, now: now))
        XCTAssertFalse(schedule.shouldEndCurrentActivity(for: progress, now: now))
    }

    func testTargetRuleStillEndsCurrentActivityOnDaysWithoutATarget() {
        let schedule = LiveActivitySchedule(enabled: true)
        let now = date("2026-09-15T12:00:00-07:00")
        var progress = snapshot(at: now)
        progress.target = 0
        progress.worked = 0
        XCTAssertNil(schedule.window(for: progress, now: now))
        XCTAssertTrue(schedule.shouldEndCurrentActivity(for: progress, now: now))
    }

    func testFixedCutoffEndsCurrentActivityEvenInOvertime() {
        let schedule = LiveActivitySchedule(enabled: true, endRule: .time, endMinute: 18 * 60)
        let beforeEnd = date("2026-09-15T17:59:59-07:00")
        var progress = snapshot(at: beforeEnd)
        progress.worked = progress.target + 3600
        XCTAssertFalse(schedule.shouldEndCurrentActivity(for: progress, now: beforeEnd))
        XCTAssertTrue(schedule.shouldEndCurrentActivity(for: progress, now: beforeEnd.addingTimeInterval(1)))
    }

    func testMidnightStillEndsCurrentActivity() {
        let schedule = LiveActivitySchedule(enabled: true, endRule: .midnight)
        let beforeMidnight = date("2026-09-15T23:59:59-07:00")
        let progress = snapshot(at: beforeMidnight)
        XCTAssertFalse(schedule.shouldEndCurrentActivity(for: progress, now: beforeMidnight))
        XCTAssertTrue(schedule.shouldEndCurrentActivity(for: progress, now: beforeMidnight.addingTimeInterval(1)))
    }

    func testDisabledScheduleLeavesCurrentActivityRunning() {
        let now = date("2026-09-15T12:00:00-07:00")
        let progress = snapshot(at: now)
        XCTAssertFalse(LiveActivitySchedule().shouldEndCurrentActivity(for: progress, now: now))
    }

    func testInvalidOrStaleInputsStillEndCurrentAutomaticActivity() {
        let now = date("2026-09-15T12:00:00-07:00")
        let progress = snapshot(at: now)
        XCTAssertTrue(LiveActivitySchedule(enabled: true, startMinute: -1)
            .shouldEndCurrentActivity(for: progress, now: now))
        XCTAssertTrue(LiveActivitySchedule(enabled: true, endRule: .time, endMinute: 540)
            .shouldEndCurrentActivity(for: progress, now: now))
        XCTAssertTrue(LiveActivitySchedule(enabled: true)
            .shouldEndCurrentActivity(for: progress, now: now.addingTimeInterval(300)))
        var invalid = progress
        invalid.target = .infinity
        XCTAssertTrue(LiveActivitySchedule(enabled: true).shouldEndCurrentActivity(for: invalid, now: now))
    }

    func testFixedEndRulesKeepShowingProgressAfterGoalIsReached() {
        let now = date("2026-09-15T12:00:00-07:00")
        var progress = snapshot(at: now)
        progress.worked = progress.target + 3600
        XCTAssertNotNil(LiveActivitySchedule(enabled: true, endRule: .midnight)
            .window(for: progress, now: now))
        XCTAssertNotNil(LiveActivitySchedule(enabled: true, endRule: .time)
            .window(for: progress, now: now))
    }

    func testDisabledInvalidAndStaleInputsDoNotScheduleActivities() {
        let now = date("2026-09-15T12:00:00-07:00")
        let progress = snapshot(at: now)
        XCTAssertNil(LiveActivitySchedule().window(for: progress, now: now))
        XCTAssertNil(LiveActivitySchedule(enabled: true, startMinute: -1).window(for: progress, now: now))
        XCTAssertNil(LiveActivitySchedule(enabled: true, startMinute: 1440).window(for: progress, now: now))
        XCTAssertNil(LiveActivitySchedule(enabled: true, endRule: .time, endMinute: 1440)
            .window(for: progress, now: now))
        XCTAssertNil(LiveActivitySchedule(enabled: true, endRule: .time, endMinute: 540)
            .window(for: progress, now: now))
        XCTAssertNil(LiveActivitySchedule(enabled: true, endRule: .time, endMinute: -1)
            .window(for: progress, now: now))
        XCTAssertNil(LiveActivitySchedule(enabled: true).window(for: progress, now: now.addingTimeInterval(300)))
        var invalid = progress
        invalid.target = .infinity
        XCTAssertNil(LiveActivitySchedule(enabled: true).window(for: invalid, now: now))
    }

    func testSpringForwardMovesSkippedStartToNextValidTime() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 2 * 60 + 30,
                                            endRule: .midnight)
        let now = date("2026-03-08T03:00:00-07:00")
        XCTAssertEqual(schedule.window(for: snapshot(at: now), now: now),
                       DateInterval(start: now, end: date("2026-03-09T00:00:00-07:00")))
        let before = date("2026-03-08T01:59:59-08:00")
        XCTAssertNil(schedule.window(for: snapshot(at: before), now: before))
    }

    func testFallBackUsesFirstOccurrenceAndPreservesActualDayLength() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 90, endRule: .midnight)
        let first = date("2026-11-01T01:30:00-07:00")
        let second = date("2026-11-01T01:30:00-08:00")
        let expected = DateInterval(start: first, end: date("2026-11-02T00:00:00-08:00"))
        XCTAssertEqual(schedule.window(for: snapshot(at: first), now: first), expected)
        XCTAssertEqual(schedule.window(for: snapshot(at: second), now: second), expected)
        XCTAssertEqual(expected.duration, 23.5 * 3600)
    }

    func testSpringForwardFixedEndResolvesToNextValidTime() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 0,
                                            endRule: .time, endMinute: 150)
        let now = date("2026-03-08T01:59:00-08:00")
        XCTAssertEqual(schedule.window(for: snapshot(at: now), now: now)?.end,
                       date("2026-03-08T03:00:00-07:00"))
    }

    func testOvernightSpringForwardWindowUsesCalendarDatesAndResolvesMissingEndTime() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .time, endMinute: 2 * 60)
        let beforeEnd = date("2026-03-08T01:59:59-08:00")
        let end = date("2026-03-08T03:00:00-07:00")
        let expected = DateInterval(start: date("2026-03-07T07:00:00-08:00"), end: end)
        XCTAssertEqual(schedule.window(for: snapshot(at: beforeEnd), now: beforeEnd), expected)
        XCTAssertNil(schedule.window(for: snapshot(at: end), now: end))
    }

    func testOvernightFallBackWindowIncludesBothOccurrencesBeforeTwoAM() {
        let schedule = LiveActivitySchedule(enabled: true, startMinute: 7 * 60,
                                            endRule: .time, endMinute: 2 * 60)
        let first = date("2026-11-01T01:45:00-07:00")
        let second = date("2026-11-01T01:45:00-08:00")
        let end = date("2026-11-01T02:00:00-08:00")
        let expected = DateInterval(start: date("2026-10-31T07:00:00-07:00"), end: end)
        XCTAssertEqual(schedule.window(for: snapshot(at: first), now: first), expected)
        XCTAssertEqual(schedule.window(for: snapshot(at: second), now: second), expected)
        XCTAssertNil(schedule.window(for: snapshot(at: end), now: end))
        XCTAssertEqual(expected.duration, 20 * 3600)
    }

    private func registration(at now: Date) -> LiveActivityStartRegistration {
        LiveActivityStartRegistration(deviceID: deviceID, token: String(repeating: "ab", count: 32),
                                      environment: "sandbox", updatedAt: now.timeIntervalSince1970)
    }

    func testStartRegistrationAcceptsBothEnvironmentsAndRoundTripsPauseState() throws {
        let now = date("2026-09-15T12:00:00-07:00")
        var registration = registration(at: now)
        XCTAssertTrue(registration.isValid(at: now))
        XCTAssertFalse(registration.isPaused(at: now))
        registration.environment = "production"
        registration.pausedUntil = now.addingTimeInterval(3600).timeIntervalSince1970
        XCTAssertTrue(registration.isValid(at: now))
        XCTAssertTrue(registration.isPaused(at: now))
        XCTAssertFalse(registration.isPaused(at: now.addingTimeInterval(3600)))
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityStartRegistration.self,
                                                from: JSONEncoder().encode(registration)), registration)
    }

    func testStartRegistrationRejectsInvalidDeviceTokenAndEnvironment() {
        let now = date("2026-09-15T12:00:00-07:00")
        var invalid = registration(at: now)
        invalid.deviceID = "not-a-device-uuid"
        XCTAssertFalse(invalid.isValid(at: now))
        invalid = registration(at: now)
        invalid.environment = "development"
        XCTAssertFalse(invalid.isValid(at: now))
        for token in ["", "ab", String(repeating: "a", count: 33),
                      String(repeating: "a", count: 514), String(repeating: "gg", count: 32),
                      String(repeating: "ａ", count: 64)] {
            invalid = registration(at: now)
            invalid.token = token
            XCTAssertFalse(invalid.isValid(at: now))
        }
    }

    func testStartRegistrationExpiresAfterThirtyDaysAndAllowsOneMinuteClockSkew() {
        let now = date("2026-09-15T12:00:00-07:00")
        let registration = registration(at: now)
        XCTAssertTrue(registration.isValid(at: now.addingTimeInterval(30 * 24 * 3600)))
        XCTAssertFalse(registration.isValid(at: now.addingTimeInterval(30 * 24 * 3600 + 1)))
        XCTAssertTrue(registration.isValid(at: now.addingTimeInterval(-60)))
        XCTAssertFalse(registration.isValid(at: now.addingTimeInterval(-61)))
    }

    func testStartRegistrationRejectsNonFiniteAndNegativeDates() {
        let now = date("2026-09-15T12:00:00-07:00")
        for timestamp in [TimeInterval.nan, .infinity, -.infinity, -1] {
            var invalid = registration(at: now)
            invalid.updatedAt = timestamp
            XCTAssertFalse(invalid.isValid(at: now))
            invalid = registration(at: now)
            invalid.pausedUntil = timestamp
            XCTAssertFalse(invalid.isValid(at: now))
        }
    }

    func testExistingActivityRegistrationDecodesWithoutAutomaticRoutingFields() throws {
        let data = Data("""
        {"id":"activity-1","token":"abababababababababababababababababababababababababababababababab",
         "environment":"sandbox","day":"2026-09-15","expiresAt":1789516800}
        """.utf8)
        let registration = try JSONDecoder().decode(LiveActivityRegistration.self, from: data)
        XCTAssertTrue(registration.isWellFormed)
        XCTAssertNil(registration.deviceID)
        XCTAssertNil(registration.automatic)
        XCTAssertNil(registration.startRequestID)
    }

    func testAutomaticActivityRegistrationRoundTripsRoutingFields() throws {
        let registration = LiveActivityRegistration(id: "activity-1", token: String(repeating: "ab", count: 32),
                                                     environment: "sandbox", day: "2026-09-15",
                                                     expiresAt: 1789516800, deviceID: deviceID,
                                                     automatic: true, startRequestID: "request-1")
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityRegistration.self,
                                                from: JSONEncoder().encode(registration)), registration)
    }

    func testStartPayloadUsesExactActivityKitEnvelopeAndSharedSnapshot() throws {
        let now = date("2026-09-15T12:00:00-07:00")
        let progress = snapshot(at: now)
        let expiry = now.addingTimeInterval(LiveActivitySchedule.maximumActivityDuration)
        let payload = LiveActivityStartPayload(snapshot: progress, deviceID: deviceID,
                                              requestID: "request-1", expiresAt: expiry, now: now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["aps"])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(Set(aps.keys), ["timestamp", "event", "content-state", "stale-date", "attributes-type",
                                      "attributes", "alert", "input-push-token"])
        XCTAssertEqual(aps["event"] as? String, "start")
        XCTAssertEqual(aps["timestamp"] as? Int, Int(now.timeIntervalSince1970))
        XCTAssertEqual(aps["stale-date"] as? Int, Int(progress.staleDate.timeIntervalSince1970))
        XCTAssertEqual(aps["attributes-type"] as? String, "WorkActivityAttributes")
        XCTAssertEqual(aps["input-push-token"] as? Int, 1)
        let attributes = try XCTUnwrap(aps["attributes"] as? [String: Any])
        XCTAssertEqual(Set(attributes.keys), ["day", "expiresAt", "deviceID", "automatic", "startRequestID"])
        XCTAssertEqual(attributes["day"] as? String, progress.day)
        XCTAssertEqual(attributes["expiresAt"] as? Double, expiry.timeIntervalSince1970)
        XCTAssertEqual(attributes["deviceID"] as? String, deviceID)
        XCTAssertEqual(attributes["automatic"] as? Bool, true)
        XCTAssertEqual(attributes["startRequestID"] as? String, "request-1")
        let alert = try XCTUnwrap(aps["alert"] as? [String: String])
        XCTAssertEqual(alert, ["title": "Sundial", "body": "Your workday progress is ready."])
        let content = try XCTUnwrap(aps["content-state"] as? [String: Any])
        XCTAssertEqual(try JSONDecoder().decode(WorkProgressSnapshot.self,
                                                from: JSONSerialization.data(withJSONObject: content)), progress)
    }

    func testExplicitRestoreMarksReplacementSoDelayedEndCannotRemoveTheNewActivity() throws {
        let now = date("2026-09-15T12:00:00-07:00")
        let payload = LiveActivityStartPayload(snapshot: snapshot(at: now), deviceID: deviceID,
            requestID: "restore-1", expiresAt: now.addingTimeInterval(3600), now: now,
            replacesExisting: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        let attributes = try XCTUnwrap(aps["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["replacesExisting"] as? Bool, true)
        XCTAssertEqual(attributes["automatic"] as? Bool, true)
        XCTAssertEqual(attributes["startRequestID"] as? String, "restore-1")
    }
}
