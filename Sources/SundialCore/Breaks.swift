import Foundation

/// Where a break reminder stands.
public struct BreakStatus: Equatable, Sendable {
    /// Work since the last real break.
    ///
    /// Not wall clock: idle time, personal time and the stretch you spent
    /// making coffee are all excluded, because they are all already known. A
    /// setting of twenty-five minutes therefore means twenty-five minutes of
    /// actual work, which is the thing a plain kitchen timer cannot promise.
    public var workedStraight: TimeInterval
    /// A break is owed. Stays true while the reminder is snoozed, so the menu
    /// bar can keep saying so quietly.
    public var owed: Bool
    /// Say something now. False while you are already away from the machine,
    /// in a call, or inside a snooze.
    public var due: Bool
    /// Work still to go before one is owed. Zero once it is.
    public var toGo: TimeInterval
    /// Why nothing was said, when something otherwise would have been.
    public var heldBack: String?

    public init(workedStraight: TimeInterval, owed: Bool, due: Bool,
                toGo: TimeInterval, heldBack: String?) {
        self.workedStraight = workedStraight; self.owed = owed; self.due = due
        self.toGo = toGo; self.heldBack = heldBack
    }
}

public enum Breaks {
    /// How long a manual snooze lasts.
    public static let snooze: TimeInterval = 20 * 60
    /// How long the app waits before mentioning it again by itself. Long
    /// enough not to nag, short enough to still be a reminder.
    public static let repeatAfter: TimeInterval = 20 * 60
    /// A glance at a work app need not erase a break. This is a total allowance
    /// across the break, not a fresh allowance for every switch of app.
    public static let interruptionTolerance: TimeInterval = 15

    /// Counts today's work since the last real break.
    ///
    /// A break contains at least the configured duration of away, personal or
    /// unclassified time, allowing a few seconds of work-app activity within it.
    /// Those work seconds do not help reach the break length. Sustained work
    /// interrupts the break; short breaks neither reset nor add to work time.
    ///
    /// Only today's segments are in hand, so working through midnight starts
    /// the count again there. That errs towards reminding late rather than
    /// interrupting someone who has just sat down.
    public static func status(segments: [Segment], now: Date, settings: Settings,
                              snoozedUntil: Date? = nil, inCall: Bool = false,
                              currentState: TimeCategory = .work) -> BreakStatus {
        guard settings.breakReminders, settings.workBeforeBreak > 0 else {
            return BreakStatus(workedStraight: 0, owed: false, due: false,
                               toGo: settings.workBeforeBreak, heldBack: nil)
        }
        let worked = progress(segments: segments, breakLength: settings.breakLength).worked
        let owed = worked >= settings.workBeforeBreak
        var heldBack: String?
        if owed {
            if let until = snoozedUntil, until > now {
                heldBack = "reminder snoozed"
            } else if currentState == .away {
                heldBack = "already away from the machine"
            } else if inCall {
                heldBack = "in a call"
            }
        }
        return BreakStatus(workedStraight: worked, owed: owed,
                           due: owed && heldBack == nil,
                           toGo: max(0, settings.workBeforeBreak - worked),
                           heldBack: heldBack)
    }

    /// Shared by the owed reminder and completion alert, so they always agree
    /// on whether a break happened. Classification and daily totals stay intact.
    fileprivate static func progress(segments: [Segment], breakLength: TimeInterval)
        -> (worked: TimeInterval, completedBreak: Span?) {
        var worked: TimeInterval = 0
        var rest: TimeInterval = 0
        var interruptions: TimeInterval = 0
        var windowStart = 0
        var previousEnd: Date?
        var completedBreak: Span?

        for (index, segment) in segments.enumerated() {
            // Unknown time cannot join two otherwise separate breaks. Allow the
            // classifier's sub-millisecond rounding at segment boundaries.
            if let previousEnd, abs(segment.start.timeIntervalSince(previousEnd)) > 0.001 {
                windowStart = index
                rest = 0; interruptions = 0
            }
            previousEnd = segment.end
            if segment.state == .work {
                worked += segment.duration
                interruptions += segment.duration
            } else {
                rest += segment.duration
            }

            // Keep the latest candidate window within the work allowance. Move
            // its start past the oldest interruption, retaining any later rest.
            // Earlier completed breaks stay credited even if this window fails.
            while windowStart <= index,
                  interruptions > interruptionTolerance || segments[windowStart].state == .work {
                let first = segments[windowStart]
                if first.state == .work { interruptions -= first.duration }
                else { rest -= first.duration }
                windowStart += 1
            }
            if segment.state != .work, rest >= breakLength, windowStart <= index {
                worked = 0
                completedBreak = Span(segments[windowStart].start, segment.end)
            }
        }
        return (worked, completedBreak)
    }
}

/// Watches live samples for the end of an owed break. Historical classification
/// alone must never produce a notification when the app starts or a rule changes.
public struct BreakCompletionTracker: Sendable {
    private var awaitingBreakSince: Date?
    private var lastUpdate: Date?

    public init() {}

    public mutating func reset() {
        awaitingBreakSince = nil
        lastUpdate = nil
    }

    /// Returns true once, when an observed work cycle gets a full break.
    /// Long sampling gaps discard the alert rather than announcing an old break
    /// on wake. Calls also suppress completion, without saving an alert for later.
    public mutating func update(segments: [Segment], now: Date, settings: Settings,
                                inCall: Bool = false) -> Bool {
        if let lastUpdate, now < lastUpdate
            || now.timeIntervalSince(lastUpdate) > settings.maxSampleGap {
            reset()
        }
        lastUpdate = now
        guard settings.breakReminders, settings.breakLength > 0, settings.workBeforeBreak > 0 else {
            awaitingBreakSince = nil
            return false
        }

        let status = Breaks.status(segments: segments, now: now, settings: settings)
        if segments.last?.state == .work, status.owed, awaitingBreakSince == nil {
            awaitingBreakSince = now
        }
        guard let awaitingBreakSince,
              let completed = Breaks.progress(segments: segments,
                                               breakLength: settings.breakLength).completedBreak,
              completed.end > awaitingBreakSince, completed.end <= now,
              now.timeIntervalSince(completed.end) <= settings.maxSampleGap else { return false }
        self.awaitingBreakSince = nil
        return !inCall
    }
}
