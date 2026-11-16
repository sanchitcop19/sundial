import Foundation

/// Reminder choices survive restarts without changing the recorded work history.
public struct BreakReminderState: Codable, Equatable, Sendable {
    public private(set) var lastRemindedAt: Date?
    public private(set) var snoozedUntil: Date?
    public private(set) var skippedAt: Date?
    public private(set) var activeBreak: Span?
    public private(set) var completedBreakAt: Date?

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

    /// Only an explicit Start action creates a timed break. Repeated actions
    /// cannot extend a break that is already running.
    public mutating func start(at now: Date, length: TimeInterval) {
        guard activeBreak == nil, now.timeIntervalSince1970.isFinite,
              length.isFinite, length > 0, length <= 24 * 3600 else { return }
        activeBreak = Span(now, now.addingTimeInterval(length))
        snoozedUntil = nil
    }

    /// Keep the original deadline as the new work-cycle boundary even if the
    /// app notices completion later, such as when the computer wakes.
    @discardableResult
    public mutating func finishBreak(at now: Date) -> Span? {
        guard let activeBreak, now >= activeBreak.end else { return nil }
        completedBreakAt = activeBreak.end
        self.activeBreak = nil
        snoozedUntil = nil
        return activeBreak
    }

    public mutating func cancelBreak() {
        activeBreak = nil
    }

    /// Skip this owed break and begin counting a fresh work interval.
    public mutating func skip(at now: Date) {
        skippedAt = now
        snoozedUntil = nil
    }

    /// Only the reminder clock resets; daily totals retain all the actual work.
    public func segmentsSinceSkip(_ segments: [Segment]) -> [Segment] {
        guard let boundary = [skippedAt, completedBreakAt].compactMap({ $0 }).max()
            else { return segments }
        return segments.compactMap { segment in
            guard segment.end > boundary else { return nil }
            var clipped = segment
            clipped.start = max(segment.start, boundary)
            return clipped
        }
    }
}
