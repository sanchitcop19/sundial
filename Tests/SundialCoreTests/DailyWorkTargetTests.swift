import XCTest
@testable import SundialCore

final class DailyWorkTargetTests: XCTestCase {
    func testExistingSettingsGainEightHourTargetAndKeepPreferences() throws {
        let json = """
        {
          "idleThreshold": 240, "callIdleThreshold": 1800,
          "maxSampleGap": 45, "sampleInterval": 10,
          "minDisplaySegment": 30, "beatPeriod": 2,
          "breakReminders": false, "workBeforeBreak": 2400, "breakLength": 600,
          "backupTo": ["icloud"], "backupInterval": 1800, "backupObservations": true
        }
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let expected = Settings(idleThreshold: 240, callIdleThreshold: 1800,
                                maxSampleGap: 45, sampleInterval: 10,
                                minDisplaySegment: 30, beatPeriod: 2,
                                breakReminders: false, workBeforeBreak: 2400,
                                breakLength: 600, backupTo: ["icloud"],
                                backupInterval: 1800, backupObservations: true)
        XCTAssertEqual(settings, expected)
        XCTAssertEqual(settings.dailyWorkTarget, 8 * 3600)
        XCTAssertEqual(Settings.default.dailyWorkTarget, 8 * 3600)
        XCTAssertFalse(settings.smartWorkTargetEnabled)
        XCTAssertEqual(settings.weeklyWorkTarget, 40 * 3600)
        XCTAssertFalse(settings.includeWeekendsInWorkTarget)
    }

    func testStoredWeeklyTargetStaysWithinSettingsRange() throws {
        for (stored, expected) in [(0.0, 3600.0), (700_000.0, 604_800.0), (126_000.0, 126_000.0)] {
            let json = "{\"weeklyWorkTarget\": \(stored)}"
            let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.weeklyWorkTarget, expected)
        }
    }

    func testExistingDailyTargetMigratesWithSmartModeOff() throws {
        let json = #"{"dailyWorkTarget": 27000, "idleThreshold": 300}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.dailyWorkTarget, 7.5 * 3600)
        XCTAssertEqual(settings.idleThreshold, 300)
        XCTAssertFalse(settings.smartWorkTargetEnabled)
        XCTAssertEqual(settings.weeklyWorkTarget, 40 * 3600)
        XCTAssertFalse(settings.includeWeekendsInWorkTarget)
    }

    func testStoredTargetStaysWithinSettingsRange() throws {
        for (stored, expected) in [(0.0, 900.0), (100_000.0, 86_400.0), (27_000.0, 27_000.0)] {
            let json = "{\"dailyWorkTarget\": \(stored)}"
            let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.dailyWorkTarget, expected)
        }
    }

    func testRemainingWorkRespondsToProgressAndChangedTarget() {
        var settings = Settings.default
        XCTAssertEqual(settings.workRemaining(after: 0), 8 * 3600)
        XCTAssertEqual(settings.workRemaining(after: -60), 8 * 3600)
        XCTAssertEqual(settings.workRemaining(after: 6 * 3600), 2 * 3600)
        XCTAssertEqual(settings.workRemaining(after: 8 * 3600), 0)
        XCTAssertEqual(settings.workRemaining(after: 9 * 3600), 0)

        settings.dailyWorkTarget = 7.5 * 3600
        XCTAssertEqual(settings.workRemaining(after: 6 * 3600), 1.5 * 3600)
    }

    func testHoursMinutesShowsOnlyCompletedMinutesOfWork() {
        XCTAssertEqual(Format.hoursMinutes(0), "0:00")
        XCTAssertEqual(Format.hoursMinutes(-60), "0:00")
        XCTAssertEqual(Format.hoursMinutes(59), "0:00")
        XCTAssertEqual(Format.hoursMinutes(59.9), "0:00")
        XCTAssertEqual(Format.hoursMinutes(60), "0:01")
        XCTAssertEqual(Format.hoursMinutes(7 * 3600 + 59 * 60 + 59), "7:59")
        XCTAssertEqual(Format.hoursMinutes(8 * 3600), "8:00")
    }

    func testRemainingMinutesRoundUpUntilTargetIsReached() {
        let settings = Settings.default
        for secondsLeft in [59.0, 1.0, 0.1] {
            let remaining = settings.workRemaining(after: settings.dailyWorkTarget - secondsLeft)
            XCTAssertEqual(Format.hoursMinutes(remaining, roundingUp: true), "0:01")
        }
        XCTAssertEqual(Format.hoursMinutes(60, roundingUp: true), "0:01")
        XCTAssertEqual(Format.hoursMinutes(61, roundingUp: true), "0:02")
        XCTAssertEqual(Format.hoursMinutes(settings.workRemaining(after: 8 * 3600),
                                          roundingUp: true), "0:00")
    }
}
