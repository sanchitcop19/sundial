import Foundation

/// Reminder choices survive restarts without changing the recorded work history.
public struct BreakReminderState: Codable, Equatable, Sendable {
    public private(set) var lastRemindedAt: Date?
    public private(set) var snoozedUntil: Date?
    public private(set) var skippedAt: Date?

    public init() {}

    /// Snooze may postpone a reminder, but cannot shorten the minimum spacing.
    public var quietUntil: Date? {
        [lastRemindedAt?.addingTimeInterval(Breaks.repeatAfter), snoozedUntil]
            .compactMap { $0 }.max()
    }

    public mutating func recordReminder(at now: Date) {
        lastRemindedAt = now
    }

    public mutating func snooze(at now: Date) {
        snoozedUntil = now.addingTimeInterval(Breaks.snooze)
    }

    public mutating func clearSnooze() {
        snoozedUntil = nil
    }

    /// Skip this owed break and begin counting a fresh work interval.
    public mutating func skip(at now: Date) {
        skippedAt = now
        snoozedUntil = nil
    }

    /// Only the reminder clock resets; daily totals retain all the actual work.
    public func segmentsSinceSkip(_ segments: [Segment]) -> [Segment] {
        guard let skippedAt else { return segments }
        return segments.compactMap { segment in
            guard segment.end > skippedAt else { return nil }
            var clipped = segment
            clipped.start = max(segment.start, skippedAt)
            return clipped
        }
    }
}
