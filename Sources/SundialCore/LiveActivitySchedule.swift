import Foundation

/// Daily automatic activity hours, interpreted in the Mac's time zone.
public struct LiveActivitySchedule: Codable, Equatable, Sendable {
    public enum EndRule: String, Codable, Sendable {
        case targetReached
        case midnight
        case time
    }

    public enum Days: String, Codable, Sendable {
        case everyDay
        case weekdays
    }

    public static let maximumActivityDuration: TimeInterval = 8 * 3600
    public var enabled: Bool
    public var startMinute: Int
    public var endRule: EndRule
    public var endMinute: Int
    public var days: Days

    public init(enabled: Bool = false, startMinute: Int = 540,
                endRule: EndRule = .targetReached, endMinute: Int = 1080,
                days: Days = .everyDay) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endRule = endRule
        self.endMinute = endMinute
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, startMinute, endRule, endMinute, days
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        startMinute = try values.decode(Int.self, forKey: .startMinute)
        endRule = try values.decode(EndRule.self, forKey: .endRule)
        endMinute = try values.decode(Int.self, forKey: .endMinute)
        days = try values.decodeIfPresent(Days.self, forKey: .days) ?? .everyDay
    }

    public func window(for snapshot: WorkProgressSnapshot, now: Date = Date()) -> DateInterval? {
        if endRule == .targetReached, snapshot.target <= 0 || snapshot.remaining <= 0 { return nil }
        return activeWindow(for: snapshot, now: now)
    }

    public func shouldEndCurrentActivity(for snapshot: WorkProgressSnapshot, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if endRule == .targetReached, snapshot.target <= 0 { return true }
        // Reaching the target stops renewal; the current activity can still show overtime.
        return activeWindow(for: snapshot, now: now) == nil
    }

    /// The current scheduled hours, including an overnight window that started yesterday.
    /// Reaching the work target does not shorten this window.
    public func activeWindow(for snapshot: WorkProgressSnapshot, now: Date = Date()) -> DateInterval? {
        guard enabled, (0..<1440).contains(startMinute), !snapshot.isStale(at: now),
              let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let today = calendar.dateInterval(of: .day, for: now),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today.start) else { return nil }
        if endRule == .time, !(0..<1440).contains(endMinute) || endMinute == startMinute { return nil }

        // Weekday eligibility belongs to the start date: Friday can run into Saturday.
        for anchor in [today.start, yesterday] {
            if days == .weekdays, !(2...6).contains(calendar.component(.weekday, from: anchor)) { continue }
            guard let day = calendar.dateInterval(of: .day, for: anchor),
                  let start = time(startMinute, on: day.start, calendar: calendar) else { continue }
            let end: Date
            if endRule == .time {
                let endDay = endMinute < startMinute ? day.end : day.start
                guard let fixedEnd = time(endMinute, on: endDay, calendar: calendar) else { continue }
                end = fixedEnd
            } else {
                end = day.end
            }
            if start < end, now >= start, now < end { return DateInterval(start: start, end: end) }
        }
        return nil
    }

    private func time(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        // Calendar resolves a missing spring-forward time to the next valid time.
        // The first occurrence of a repeated fall-back time starts the day's window.
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                      of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}

/// A device's push-to-start destination, kept separate from activity update tokens.
public struct LiveActivityStartRegistration: Codable, Equatable, Sendable {
    public static let directoryName = "live-activity-devices"
    public var deviceID: String
    public var token: String
    public var environment: String
    public var updatedAt: TimeInterval
    public var pausedUntil: TimeInterval?

    public init(deviceID: String, token: String, environment: String,
                updatedAt: TimeInterval, pausedUntil: TimeInterval? = nil) {
        self.deviceID = deviceID
        self.token = token
        self.environment = environment
        self.updatedAt = updatedAt
        self.pausedUntil = pausedUntil
    }

    public func isValid(at now: Date = Date()) -> Bool {
        let timestamp = now.timeIntervalSince1970
        return UUID(uuidString: deviceID) != nil
            && (32...512).contains(token.count) && token.count.isMultiple(of: 2)
            && token.allSatisfy { $0.isASCII && $0.isHexDigit }
            && ["sandbox", "production"].contains(environment)
            && timestamp.isFinite && updatedAt.isFinite && updatedAt >= 0
            && updatedAt <= timestamp + 60 && updatedAt >= timestamp - 30 * 24 * 3600
            && (pausedUntil.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    public func isPaused(at now: Date = Date()) -> Bool {
        pausedUntil.map { $0 > now.timeIntervalSince1970 } ?? false
    }
}

/// ActivityKit's push-to-start envelope requests an update token for the new activity.
public struct LiveActivityStartPayload: Encodable {
    public let aps: Content

    public struct Content: Encodable {
        let timestamp: Int
        let event = "start"
        let contentState: WorkProgressSnapshot
        let staleDate: Int
        let attributesType = "WorkActivityAttributes"
        let attributes: Attributes
        let alert = Alert()
        let inputPushToken = 1

        enum CodingKeys: String, CodingKey {
            case timestamp, event, attributes, alert
            case contentState = "content-state"
            case staleDate = "stale-date"
            case attributesType = "attributes-type"
            case inputPushToken = "input-push-token"
        }
    }

    public struct Attributes: Encodable {
        let day: String
        let expiresAt: TimeInterval
        let deviceID: String
        let automatic = true
        let startRequestID: String
        let replacesExisting: Bool?
    }

    public struct Alert: Encodable {
        let title = "Sundial"
        let body = "Your workday progress is ready."
    }

    public init(snapshot: WorkProgressSnapshot, deviceID: String, requestID: String,
                expiresAt: Date, now: Date = Date(), replacesExisting: Bool? = nil) {
        aps = Content(timestamp: Int(now.timeIntervalSince1970), contentState: snapshot,
                      staleDate: Int(snapshot.staleDate.timeIntervalSince1970),
                      attributes: Attributes(day: snapshot.day,
                                             expiresAt: expiresAt.timeIntervalSince1970,
                                             deviceID: deviceID, startRequestID: requestID,
                                             replacesExisting: replacesExisting))
    }
}
