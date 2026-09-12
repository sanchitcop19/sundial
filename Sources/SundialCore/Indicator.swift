import Foundation

/// Whether time is still being earned, as distinct from what it counts as.
///
/// The two answer different questions, and the gap between them is exactly
/// where a status icon can mislead: a stretch stays `work` for the whole of the
/// idle grace period, so a dot that looks identical the moment you stop typing
/// claims someone is at the keyboard when nobody is.
public enum Liveness: String, Sendable, Equatable {
    /// Input just now, or a call in progress. The clock is running.
    case active
    /// Quiet, but not long enough to be counted away yet.
    case still
    /// Nothing is being counted: idle past the threshold, locked, or asleep.
    case dormant
    /// Tracking is switched off.
    case paused
}

/// How the status icon should look at one moment.
public struct LiveIndicator: Equatable, Sendable {
    public var liveness: Liveness
    /// Only work pulses. The menu bar shows the work total, so a beating dot
    /// next to a number that is not moving would be a lie.
    public var pulses: Bool
    /// Fades towards `Indicator.dimmest` as the away cutoff approaches, so
    /// "about to stop counting" is visible before it happens.
    public var alpha: Double
    /// How long until this stretch stops counting. Nil unless the clock is
    /// running down.
    public var awayIn: TimeInterval?
    /// One short line for the menu and the tooltip.
    public var note: String?

    public init(liveness: Liveness, pulses: Bool, alpha: Double,
                awayIn: TimeInterval? = nil, note: String? = nil) {
        self.liveness = liveness; self.pulses = pulses; self.alpha = alpha
        self.awayIn = awayIn; self.note = note
    }
}

public enum Indicator {
    /// Silence longer than this is worth showing, well before it changes the
    /// verdict. Short enough to catch a pause, long enough that reading a
    /// paragraph does not dim the icon.
    public static let quietAfter: TimeInterval = 20
    /// How faint the icon gets just before the away cutoff.
    public static let dimmest = 0.4
    /// How faint the dot goes at the bottom of the beat.
    public static let pulseFloor = 0.3
    /// How often the dot's opacity is stepped while it pulses.
    ///
    /// The dot is drawn as a layer, so a step changes an opacity and rasterises
    /// nothing. That is around a tenth of the price of redrawing the menu bar
    /// item - which is what pays for a rate like this. Twenty-four is smooth to
    /// the eye without pretending a status icon deserves the display's full
    /// refresh rate.
    public static let beatFrameRate: Double = 24

    public static func current(state: TimeCategory, idleSeconds: TimeInterval,
                               inCall: Bool, isPaused: Bool,
                               settings: Settings) -> LiveIndicator {
        if isPaused {
            return LiveIndicator(liveness: .paused, pulses: false, alpha: 1, note: "Paused")
        }
        if state == .away {
            return LiveIndicator(liveness: .dormant, pulses: false, alpha: 1)
        }
        let threshold = inCall ? settings.callIdleThreshold : settings.idleThreshold
        let quiet = min(quietAfter, threshold / 2)
        let idle = max(0, idleSeconds)

        if idle < quiet {
            return LiveIndicator(liveness: .active, pulses: state == .work, alpha: 1,
                                 note: inCall ? "In a call" : nil)
        }
        if idle < threshold {
            // A call is its own evidence of presence, so the icon keeps beating
            // through a meeting nobody is typing in - only dimmer, because that
            // window does eventually run out too.
            let span = max(threshold - quiet, 1)
            let fade = min(1, (idle - quiet) / span)
            let left = max(0, threshold - idle)
            return LiveIndicator(
                liveness: inCall ? .active : .still,
                pulses: inCall && state == .work,
                alpha: 1 - (1 - dimmest) * fade,
                awayIn: left,
                note: (inCall ? "In a call, quiet for " : "Quiet for ")
                    + Format.duration(idle) + " — away in " + Format.duration(left))
        }
        // Past the cutoff but the category has not caught up yet: the verdict is
        // only recomputed on a sample, and brightening back up for those few
        // seconds would undo the whole fade.
        return LiveIndicator(liveness: .dormant, pulses: false, alpha: dimmest)
    }

    /// A straight ramp down and back: full, to the floor, and up again.
    ///
    /// Deliberately not eased. A cosine lingers at the top and the bottom, and
    /// on something this small that dwell is what reads as sluggish - the dot
    /// looks stuck rather than alive. A constant rate keeps it always moving,
    /// and costs nothing extra now that a step is only an opacity.
    public static func pulseAlpha(at t: TimeInterval,
                                  period: TimeInterval = Settings.default.beatPeriod,
                                  low: Double = pulseFloor) -> Double {
        guard period > 0 else { return 1 }
        let u = phase(at: t, period: period) / period
        return low + (1 - low) * abs(2 * u - 1)
    }

    private static func phase(at t: TimeInterval, period: TimeInterval) -> TimeInterval {
        let p = t.truncatingRemainder(dividingBy: period)
        return p < 0 ? p + period : p
    }
}
