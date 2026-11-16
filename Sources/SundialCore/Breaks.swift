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
    /// Countdown including any remaining snooze or reminder quiet period.
    public var nextBreakIn: TimeInterval
    /// Time remaining in the break the user explicitly started.
    /// Nil outside an active break; zero after the break has finished.
    public var breakRemaining: TimeInterval?
    public var breakEndsAt: Date?

    public init(workedStraight: TimeInterval, owed: Bool, due: Bool,
                toGo: TimeInterval, heldBack: String?, nextBreakIn: TimeInterval? = nil,
                breakRemaining: TimeInterval? = nil, breakEndsAt: Date? = nil) {
        self.workedStraight = workedStraight; self.owed = owed; self.due = due
        self.toGo = toGo; self.heldBack = heldBack
        self.nextBreakIn = nextBreakIn ?? toGo
        self.breakRemaining = breakRemaining
        self.breakEndsAt = breakEndsAt
    }

    public var countdownText: String {
        countdownText(after: 0, currentState: .work)
    }

    /// Smooth the display between samples without changing recorded progress.
    public func countdownText(after elapsed: TimeInterval, currentState: TimeCategory) -> String {
        let elapsed = max(0, elapsed)
        let workElapsed = currentState == .work ? elapsed : 0
        let remaining = breakRemaining.map { $0 - elapsed }
            ?? max(toGo - workElapsed, nextBreakIn - elapsed)
        guard remaining > 0 else {
            return breakRemaining == nil ? "Break due now" : "Break complete"
        }
        let seconds = Int(remaining.rounded(.up))
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return breakRemaining == nil ? "Next break in \(time)" : "Break ends in \(time)"
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
                              currentState: TimeCategory = .work,
                              activeBreak: Span? = nil) -> BreakStatus {
        guard settings.breakReminders, settings.workBeforeBreak > 0 else {
            return BreakStatus(workedStraight: 0, owed: false, due: false,
                               toGo: settings.workBeforeBreak, heldBack: nil)
        }
        let worked = progress(segments: segments, breakLength: settings.breakLength)
        let activeBreak = activeBreak.flatMap { span in
            span.start <= now && span.duration > 0 && span.duration <= 24 * 3600
                && span.end.timeIntervalSince1970.isFinite ? span : nil
        }
        let owed = activeBreak == nil && worked >= settings.workBeforeBreak
        let toGo = max(0, settings.workBeforeBreak - worked)
        let quietRemaining = max(0, snoozedUntil?.timeIntervalSince(now) ?? 0)
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
                           toGo: toGo, heldBack: heldBack,
                           nextBreakIn: max(toGo, quietRemaining),
                           breakRemaining: activeBreak.map { max(0, $0.end.timeIntervalSince(now)) },
                           breakEndsAt: activeBreak?.end)
    }

    /// Passive rest credits the reminder work clock without starting a timer
    /// or producing a completion alert. Recorded classification stays intact.
    private static func progress(segments: [Segment], breakLength: TimeInterval) -> TimeInterval {
        var worked: TimeInterval = 0
        var rest: TimeInterval = 0
        var interruptions: TimeInterval = 0
        var windowStart = 0
        var previousEnd: Date?

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
            }
        }
        return worked
    }
}

/// Only an explicitly started break can produce a completion notification.
/// Historical or missed completions stay silent when the app starts or wakes.
public struct BreakCompletionTracker: Sendable {
    private var observedBreak: Span?
    private var lastUpdate: Date?

    public init() {}

    public mutating func reset() {
        observedBreak = nil
        lastUpdate = nil
    }

    /// Returns true once, when an observed break reaches its fixed deadline.
    /// Long sampling gaps discard the alert rather than announcing an old break
    /// on wake. Calls also suppress completion, without saving an alert for later.
    public mutating func update(activeBreak: Span?, now: Date, settings: Settings,
                                inCall: Bool = false) -> Bool {
        defer {
            observedBreak = settings.breakReminders ? activeBreak : nil
            lastUpdate = now
        }
        guard settings.breakReminders, settings.breakLength > 0, settings.workBeforeBreak > 0,
              let activeBreak, observedBreak == activeBreak, let lastUpdate,
              now >= lastUpdate, now.timeIntervalSince(lastUpdate) <= settings.maxSampleGap,
              lastUpdate < activeBreak.end, now >= activeBreak.end else { return false }
        return !inCall
    }
}
