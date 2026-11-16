import ActivityKit
import Foundation
import SundialCore

struct WorkActivityAttributes: ActivityAttributes {
    typealias ContentState = WorkProgressSnapshot

    var day: String
    var expiresAt: TimeInterval
    var deviceID: String? = nil
    var automatic: Bool? = nil
    var startRequestID: String? = nil
    var replacesExisting: Bool? = nil
}

enum WorkProgressPresentation {
    static func compact(_ seconds: TimeInterval, roundingUp: Bool = false) -> String {
        Format.hoursMinutes(seconds, roundingUp: roundingUp)
    }

    static func dayEnd(for snapshot: WorkProgressSnapshot) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
        return calendar.dateInterval(of: .day,
            for: Date(timeIntervalSince1970: snapshot.updatedAt))?.end
            ?? Date(timeIntervalSince1970: snapshot.updatedAt + 86_400)
    }

    static func staleDate(for snapshot: WorkProgressSnapshot) -> Date {
        snapshot.staleDate
    }

    static func updatedTime(_ snapshot: WorkProgressSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier)
        formatter.dateFormat = "h:mm a z"
        return formatter.string(from: Date(timeIntervalSince1970: snapshot.updatedAt))
    }

    static func status(_ snapshot: WorkProgressSnapshot, stale: Bool) -> String {
        if stale { return "Update delayed · last known totals" }
        if snapshot.isPaused { return "Tracking paused" }
        if showsActiveBreak(snapshot, stale: stale) {
            return snapshot.breakPausedRemaining != nil ? "Break paused" : "On a break"
        }
        switch snapshot.state {
        case "work": return "Working"
        case "away": return "Away from Mac"
        case "personal": return "Personal time"
        default: return "Synced from Mac"
        }
    }

    static func showsActiveBreak(_ snapshot: WorkProgressSnapshot, stale: Bool) -> Bool {
        !stale && !snapshot.isStale() && snapshot.hasActiveBreak
    }
}
