import Foundation

/// Turns raw observations plus presence into classified segments.
///
/// Pure and total: same inputs, same output, no I/O and no clock. That is what
/// makes "change a rule and see the whole day re-decided" possible, and it
/// makes every behaviour here directly testable.
public struct Classifier: Sendable {
    public var rules: RuleSet
    public var settings: Settings

    public init(rules: RuleSet, settings: Settings = .default) {
        self.rules = rules
        self.settings = settings
    }

    public func classify(observations: [ObservationSpan], presence: PresenceLog,
                         within window: Span? = nil) -> [Segment] {
        let obs = observations.sorted { $0.start < $1.start }
        var presence = presence
        presence.normalise()

        guard let bounds = window ?? overallBounds(obs, presence) else { return [] }
        let cuts = boundaries(obs: obs, presence: presence, bounds: bounds)
        guard cuts.count > 1 else { return [] }

        var raw: [Segment] = []
        var judged: [Int: Segment] = [:]
        for i in 0..<(cuts.count - 1) {
            let a = cuts[i], b = cuts[i + 1]
            guard b > a else { continue }
            raw.append(decide(from: a, to: b, obs: obs, presence: presence, judged: &judged))
        }
        return coalesce(raw)
    }

    // MARK: - Decisions

    /// `judged` remembers the content verdict per observation: an observation
    /// spans many cuts, and matching it against every rule each time dominated.
    private func decide(from a: Date, to b: Date,
                        obs: [ObservationSpan], presence: PresenceLog,
                        judged: inout [Int: Segment]) -> Segment {
        // 1. Presence. Nothing on screen counts if nobody is there.
        if covers(presence.offline, a) {
            return Segment(start: a, end: b, state: .away,
                           reason: "Machine asleep or tracker not running")
        }
        if covers(presence.absent, a) {
            return Segment(start: a, end: b, state: .away,
                           reason: "Screen locked or display asleep")
        }
        let inCall = covers(presence.call, a)
        if !covers(presence.input, a) {
            let threshold = inCall ? settings.callIdleThreshold : settings.idleThreshold
            guard let lastInput = lastInputEnd(presence.input, before: a) else {
                return Segment(start: a, end: b, state: .away, reason: "No activity recorded yet")
            }
            let idleFor = a.timeIntervalSince(lastInput)
            if idleFor >= threshold {
                return Segment(start: a, end: b, state: .away,
                               reason: inCall
                                   ? "No input for \(Format.duration(idleFor)), even allowing for the call"
                                   : "No input for \(Format.duration(idleFor))")
            }
        }

        // 2. Content. Whatever was on screen, judged by the rules.
        guard let index = observationIndex(obs, at: a) else {
            return Segment(start: a, end: b, state: .away, reason: "Nothing recorded on screen")
        }
        if var known = judged[index] {
            known.start = a; known.end = b
            return known
        }
        let verdict = judge(obs[index].snapshot, from: a, to: b)
        judged[index] = verdict
        return verdict
    }

    private func judge(_ snap: Snapshot, from a: Date, to b: Date) -> Segment {
        if let rule = rules.match(snap) {
            return Segment(start: a, end: b, state: rule.outcome.state, snapshot: snap,
                           ruleId: rule.id, ruleName: rule.name,
                           reason: "Rule “\(rule.name)”: \(rule.describe)")
        }
        if !snap.detailAvailable {
            return Segment(start: a, end: b, state: .unclassified, snapshot: snap,
                           reason: "Only \(snap.appName) was visible — Accessibility was not "
                                 + "granted yet, so nothing inside the window was captured")
        }
        return Segment(start: a, end: b, state: .unclassified, snapshot: snap,
                       reason: "No rule matches \(snap.summary)")
    }

    /// Classifies a single snapshot as if someone were present. Used by the UI
    /// to preview a rule change, and to explain a decision.
    public func preview(_ snapshot: Snapshot) -> (state: TimeCategory, rule: Rule?) {
        if let r = rules.match(snapshot) { return (r.outcome.state, r) }
        return (.unclassified, nil)
    }

    // MARK: - Timeline mechanics

    private func overallBounds(_ obs: [ObservationSpan], _ p: PresenceLog) -> Span? {
        var starts = obs.map(\.start), ends = obs.map(\.end)
        for group in [p.input, p.absent, p.call, p.offline] {
            starts.append(contentsOf: group.map(\.start))
            ends.append(contentsOf: group.map(\.end))
        }
        guard let s = starts.min(), let e = ends.max(), e > s else { return nil }
        return Span(s, e)
    }

    /// Every instant where the answer could change: span edges, and the exact
    /// moments idleness begins for each threshold.
    private func boundaries(obs: [ObservationSpan], presence: PresenceLog, bounds: Span) -> [Date] {
        var set = Set<Date>([bounds.start, bounds.end])
        func add(_ d: Date) { if d > bounds.start && d < bounds.end { set.insert(d) } }

        for o in obs { add(o.start); add(o.end) }
        for group in [presence.absent, presence.call, presence.offline] {
            for s in group { add(s.start); add(s.end) }
        }
        for s in presence.input {
            add(s.start); add(s.end)
            // The moment silence becomes absence, under either threshold. Both
            // are added because a call can end while the user is already quiet.
            add(s.end.addingTimeInterval(settings.idleThreshold))
            add(s.end.addingTimeInterval(settings.callIdleThreshold))
        }
        return set.sorted()
    }

    private func covers(_ spans: [Span], _ d: Date) -> Bool {
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].end <= d { lo = mid + 1 }
            else if spans[mid].start > d { hi = mid - 1 }
            else { return true }
        }
        return false
    }

    private func lastInputEnd(_ spans: [Span], before d: Date) -> Date? {
        var lo = 0, hi = spans.count - 1, best: Date?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].end <= d { best = spans[mid].end; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return best
    }

    private func observationIndex(_ obs: [ObservationSpan], at d: Date) -> Int? {
        var lo = 0, hi = obs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if obs[mid].end <= d { lo = mid + 1 }
            else if obs[mid].start > d { hi = mid - 1 }
            else { return mid }
        }
        return nil
    }

    /// Joins neighbouring stretches that reached the same verdict for the same
    /// reason, so the timeline shows meaningful blocks rather than sample noise.
    private func coalesce(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segments {
            guard var last = out.last else { out.append(s); continue }
            let same = last.state == s.state
                && last.ruleId == s.ruleId
                && last.snapshot?.groupingKey == s.snapshot?.groupingKey
                && last.reason == s.reason
            if same, abs(last.end.timeIntervalSince(s.start)) < 0.001 {
                last.end = s.end
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out.filter { $0.duration > 0.001 }
    }
}

/// Totals over a set of segments.
public struct Totals: Sendable, Equatable {
    public var byState: [TimeCategory: TimeInterval] = [:]

    public var work: TimeInterval { byState[.work] ?? 0 }
    public var personal: TimeInterval { byState[.personal] ?? 0 }
    public var away: TimeInterval { byState[.away] ?? 0 }
    public var unclassified: TimeInterval { byState[.unclassified] ?? 0 }
    public var tracked: TimeInterval { work + personal + unclassified }

    public init() {}

    public static func compute(_ segments: [Segment]) -> Totals {
        var t = Totals()
        for s in segments { t.byState[s.state, default: 0] += s.duration }
        return t
    }
}

/// A group of equivalent snapshots that need a decision, ranked by how much
/// time they account for. This is the queue the review screen works through.
public struct ReviewItem: Sendable, Identifiable, Equatable {
    public var id: String { key }
    public var key: String
    public var snapshot: Snapshot
    public var seconds: TimeInterval
    public var occurrences: Int
    public var firstSeen: Date
    public var lastSeen: Date

    /// False when no rule could ever match, because the detail needed to write
    /// one was never captured. Offering scopes for these would be misleading.
    public var isActionable: Bool { snapshot.detailAvailable }

    public static func build(from segments: [Segment]) -> [ReviewItem] {
        var acc: [String: ReviewItem] = [:]
        for s in segments where s.state == .unclassified {
            guard let snap = s.snapshot else { continue }
            let key = snap.groupingKey
            if var existing = acc[key] {
                existing.seconds += s.duration
                existing.occurrences += 1
                existing.lastSeen = max(existing.lastSeen, s.end)
                acc[key] = existing
            } else {
                acc[key] = ReviewItem(key: key, snapshot: snap, seconds: s.duration,
                                      occurrences: 1, firstSeen: s.start, lastSeen: s.end)
            }
        }
        return acc.values.sorted { $0.seconds > $1.seconds }
    }
}
