import Foundation

/// A stopwatch for phone time. Only the start is stored: the duration is
/// worked out when it stops, so the timer needs no ticking and survives the
/// app being closed or killed while it runs.
public struct PhoneTimer: Codable, Equatable, Sendable {
    public var start: Date
    public var label: String
    public var outcome: Outcome

    public init(start: Date, label: String, outcome: Outcome) {
        self.start = start; self.label = label; self.outcome = outcome
    }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(start))
    }

    public enum Finish: Equatable, Sendable {
        case send(TimeInterval)
        case tooShort
        case tooLong
    }

    /// Whether what has run so far can be sent as one entry. Entries run from a
    /// minute to a day, so anything outside that is said out loud instead of
    /// being sent and silently dropped.
    public func finish(at now: Date = Date()) -> Finish {
        let seconds = elapsed(at: now)
        if seconds < Self.minimum { return .tooShort }
        if seconds > Manual.maxLength { return .tooLong }
        return .send(seconds)
    }

    public static let minimum: TimeInterval = 60
}
