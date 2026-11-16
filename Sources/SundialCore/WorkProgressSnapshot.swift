import Foundation

private func isValidDay(_ day: String) -> Bool {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: day) else { return false }
    return formatter.string(from: date) == day
}

/// A summary shared with the phone. It never contains window titles or raw activity.
/// Numeric Unix timestamps also work with ActivityKit's default JSON decoder.
public struct WorkProgressSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let fileName = "work-progress.json"
    public var day: String
    public var timeZoneIdentifier: String
    public var updatedAt: TimeInterval
    public var worked: TimeInterval
    public var target: TimeInterval
    public var weeklyWorked: TimeInterval?
    public var weeklyTarget: TimeInterval?
    public var state: String
    public var isPaused: Bool
    public var automaticActivityEnd: TimeInterval?
    /// Stable deadline lets the Live Activity count down without extra pushes.
    public var breakEndsAt: TimeInterval?
    /// Retained to decode summaries from older app versions.
    public var breakPausedRemaining: TimeInterval?

    public init(day: String, timeZoneIdentifier: String, updatedAt: TimeInterval,
                worked: TimeInterval, target: TimeInterval,
                weeklyWorked: TimeInterval? = nil, weeklyTarget: TimeInterval? = nil,
                state: String, isPaused: Bool, automaticActivityEnd: TimeInterval? = nil,
                breakEndsAt: TimeInterval? = nil, breakPausedRemaining: TimeInterval? = nil) {
        self.day = day; self.timeZoneIdentifier = timeZoneIdentifier; self.updatedAt = updatedAt
        self.worked = worked; self.target = target
        self.weeklyWorked = weeklyWorked; self.weeklyTarget = weeklyTarget
        self.state = state; self.isPaused = isPaused
        self.automaticActivityEnd = automaticActivityEnd
        self.breakEndsAt = breakEndsAt; self.breakPausedRemaining = breakPausedRemaining
    }

    public var remaining: TimeInterval { max(0, target - worked) }
    public var overtime: TimeInterval { target > 0 ? max(0, worked - target) : 0 }
    public var isOverTarget: Bool { target > 0 && worked > target }

    public var hasActiveBreak: Bool {
        !isPaused && (breakEndsAt != nil || breakPausedRemaining != nil)
    }

    public func breakRemaining(at now: Date = Date()) -> TimeInterval? {
        guard hasActiveBreak else { return nil }
        return breakEndsAt.map { max(0, $0 - now.timeIntervalSince1970) } ?? breakPausedRemaining
    }

    public mutating func updateBreak(_ status: BreakStatus) {
        breakEndsAt = nil
        breakPausedRemaining = nil
        guard !isPaused, let end = status.breakEndsAt?.timeIntervalSince1970,
              end.isFinite, end > updatedAt, end <= updatedAt + 24 * 3600 else { return }
        breakEndsAt = end
    }

    public var isValid: Bool {
        guard isValidDay(day), let timeZone = TimeZone(identifier: timeZoneIdentifier),
              updatedAt.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let updated = Date(timeIntervalSince1970: updatedAt)
        guard Format.day(updated, calendar: calendar) == day,
              let dayInterval = calendar.dateInterval(of: .day, for: updated) else { return false }
        calendar.firstWeekday = 2
        let weekInterval = StatsPeriod.week.interval(containing: updated, calendar: calendar)
        return worked <= dayInterval.duration
            && worked.isFinite && target.isFinite
            && worked >= 0 && target >= 0 && target <= 24 * 3600
            && (weeklyWorked.map { $0.isFinite && $0 >= 0 && $0 <= weekInterval.duration } ?? true)
            && (weeklyTarget.map { $0.isFinite && $0 >= 0 && $0 <= 168 * 3600 } ?? true)
            && (automaticActivityEnd.map { $0.isFinite && $0 >= updatedAt && $0 <= updatedAt + 26 * 3600 } ?? true)
            && (breakEndsAt.map { $0.isFinite && $0 >= updatedAt && $0 <= updatedAt + 24 * 3600 } ?? true)
            && (breakPausedRemaining.map { $0.isFinite && $0 > 0 && $0 <= 24 * 3600 } ?? true)
            && (breakEndsAt == nil || breakPausedRemaining == nil)
            && (!isPaused || (breakEndsAt == nil && breakPausedRemaining == nil))
            && TimeCategory(rawValue: state) != nil
    }

    public var staleDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let updated = Date(timeIntervalSince1970: updatedAt)
        let nextDay = calendar.date(byAdding: .day, value: 1,
                                    to: calendar.startOfDay(for: updated)) ?? updated
        return min(updated.addingTimeInterval(300), nextDay)
    }

    public func isStale(at now: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return !isValid || now >= staleDate || updatedAt > now.timeIntervalSince1970 + 60
            || Format.day(now, calendar: calendar) != day
    }

    public func automaticPauseDeadline(at now: Date = Date()) -> Date {
        if isValid, let automaticActivityEnd, automaticActivityEnd > now.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: automaticActivityEnd)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(24 * 3600)
    }
}

/// The phone leaves a short-lived ActivityKit destination in the chosen sync folder.
public struct LiveActivityRegistration: Codable, Equatable, Sendable {
    public var id: String
    public var token: String
    public var environment: String
    public var day: String
    public var expiresAt: TimeInterval
    public var deviceID: String?
    public var automatic: Bool?
    public var startRequestID: String?

    public init(id: String, token: String, environment: String, day: String,
                expiresAt: TimeInterval, deviceID: String? = nil,
                automatic: Bool? = nil, startRequestID: String? = nil) {
        self.id = id; self.token = token; self.environment = environment
        self.day = day; self.expiresAt = expiresAt
        self.deviceID = deviceID; self.automatic = automatic; self.startRequestID = startRequestID
    }

    public var isWellFormed: Bool {
        !id.isEmpty && (32...512).contains(token.count)
            && token.count.isMultiple(of: 2)
            && token.allSatisfy { $0.isASCII && $0.isHexDigit }
            && ["sandbox", "production"].contains(environment)
            && isValidDay(day) && expiresAt.isFinite
    }

    public func isValid(at now: Date) -> Bool {
        isWellFormed && expiresAt > now.timeIntervalSince1970
    }

    /// Automatic activities can span midnight; their content still uses today's totals.
    public func isCurrent(for snapshot: WorkProgressSnapshot, at now: Date) -> Bool {
        isValid(at: now) && (automatic == true || day == snapshot.day)
    }
}

/// The exact ActivityKit APNs envelope, shared with tests to guard the wire format.
public struct LiveActivityPushPayload: Encodable {
    public let aps: Content

    public struct Content: Encodable {
        let timestamp: Int
        let event: String
        let contentState: WorkProgressSnapshot
        let staleDate: Int
        let dismissalDate: Int?

        enum CodingKeys: String, CodingKey {
            case timestamp, event
            case contentState = "content-state"
            case staleDate = "stale-date"
            case dismissalDate = "dismissal-date"
        }
    }

    public init(snapshot: WorkProgressSnapshot, ending: Bool = false, now: Date = Date()) {
        aps = Content(timestamp: Int(now.timeIntervalSince1970), event: ending ? "end" : "update",
                      contentState: snapshot, staleDate: Int(snapshot.staleDate.timeIntervalSince1970),
                      dismissalDate: ending ? Int(now.timeIntervalSince1970) : nil)
    }
}
