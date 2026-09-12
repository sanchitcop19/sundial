import Foundation

/// Splits classified time into hour-of-day buckets and derives day and range
/// statistics.
///
/// Everything here is computed from segments, which are themselves derived from
/// the raw record, so statistics move when the rules move. A rule fixed today
/// corrects last month's charts as well.
public enum Analytics {
    /// Divides a span across the local hours it covers.
    ///
    /// Hour boundaries come from the calendar rather than from arithmetic, so a
    /// daylight-saving change produces a 23- or 25-hour day rather than a
    /// silently shifted one.
    public static func splitByHour(start: Date, end: Date,
                                   calendar: Calendar = .current) -> [(hour: Int, seconds: TimeInterval)] {
        guard end > start else { return [] }
        var out: [(Int, TimeInterval)] = []
        var cursor = start
        var guardrail = 0
        while cursor < end, guardrail < 48 {
            guardrail += 1
            let hour = calendar.component(.hour, from: cursor)
            let next = calendar.nextDate(after: cursor,
                                         matching: DateComponents(minute: 0, second: 0),
                                         matchingPolicy: .nextTime) ?? end
            let stop = min(next, end)
            out.append((hour, stop.timeIntervalSince(cursor)))
            cursor = stop
        }
        return out
    }

    /// Seconds per hour of the day, index 0...23, for segments in one state.
    public static func hourBuckets(_ segments: [Segment], state: TimeCategory,
                                   calendar: Calendar = .current) -> [TimeInterval] {
        var buckets = [TimeInterval](repeating: 0, count: 24)
        for s in segments where s.state == state {
            for piece in splitByHour(start: s.start, end: s.end, calendar: calendar) {
                buckets[piece.hour] += piece.seconds
            }
        }
        return buckets
    }
}

/// One day, summarised.
public struct DayStats: Sendable, Equatable, Identifiable {
    public var id: String { day }
    public var day: String
    public var date: Date
    public var totals: Totals
    public var workByHour: [TimeInterval]
    public var personalByHour: [TimeInterval]
    /// First and last non-away moment: the outer edges of the working day.
    public var firstActivity: Date?
    public var lastActivity: Date?
    /// Observed work time in the longest focus block, excluding brief pauses
    /// and time entered by hand.
    public var longestFocus: TimeInterval
    public var focusBlocks: Int
    /// How often the thing being worked on changed. High numbers mean a
    /// fragmented day even when the total looks healthy.
    public var contextSwitches: Int
    /// Time with a microphone or camera live, i.e. in a call.
    public var callSeconds: TimeInterval

    public var work: TimeInterval { totals.work }

    /// Wall-clock time between starting and stopping, including every break.
    public var span: TimeInterval {
        guard let f = firstActivity, let l = lastActivity else { return 0 }
        return max(0, l.timeIntervalSince(f))
    }

    /// What share of the working day was actually work.
    public var density: Double { span > 0 ? min(1, totals.work / span) : 0 }

    /// Decided with the same calendar the day was computed in. Using the
    /// process default here would let a timezone offset move a Saturday.
    public var isWeekend: Bool

    public static func compute(day: String, segments: [Segment], presence: PresenceLog,
                               calendar: Calendar = .current,
                               focusTolerance: TimeInterval = 120) -> DayStats {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let date = f.date(from: day) ?? segments.first?.start ?? Date()

        let active = segments.filter { $0.state == .work || $0.state == .personal }
        let (longest, blocks) = focusRuns(segments, tolerance: focusTolerance)

        var switches = 0
        var lastKey: String?
        for s in segments where s.state == .work {
            let key = s.snapshot?.groupingKey ?? "-"
            if let lastKey, lastKey != key { switches += 1 }
            lastKey = key
        }

        return DayStats(
            day: day, date: date,
            totals: Totals.compute(segments),
            workByHour: Analytics.hourBuckets(segments, state: .work, calendar: calendar),
            personalByHour: Analytics.hourBuckets(segments, state: .personal, calendar: calendar),
            firstActivity: active.map(\.start).min(),
            lastActivity: active.map(\.end).max(),
            longestFocus: longest, focusBlocks: blocks,
            contextSwitches: switches,
            callSeconds: presence.call.reduce(0) { $0 + $1.duration },
            isWeekend: [1, 7].contains(calendar.component(.weekday, from: date)))
    }

    /// A focus block allows pauses of at most `tolerance`, but counts only
    /// work time. Measure the whole gap between work segments: one break can
    /// contain many short personal/away segments or gaps in the record.
    /// Manual entries contribute to totals, but cannot establish or bridge
    /// observed focus, since a daily total may be entered as a single span.
    static func focusRuns(_ segments: [Segment],
                          tolerance: TimeInterval) -> (longest: TimeInterval, count: Int) {
        var longest: TimeInterval = 0
        var count = 0
        var workInRun: TimeInterval = 0
        var lastWorkEnd: Date?

        func closeRun() {
            guard workInRun > 0 else { return }
            count += 1
            longest = max(longest, workInRun)
            workInRun = 0
        }

        for s in segments where s.duration > 0 {
            if s.manual {
                closeRun()
                lastWorkEnd = nil
                continue
            }
            guard s.state == .work else { continue }
            if let lastWorkEnd, s.start.timeIntervalSince(lastWorkEnd) > max(0, tolerance) {
                closeRun()
            }
            workInRun += s.duration
            lastWorkEnd = s.end
        }
        closeRun()
        return (longest, count)
    }

    public init(day: String, date: Date, totals: Totals, workByHour: [TimeInterval],
                personalByHour: [TimeInterval], firstActivity: Date?, lastActivity: Date?,
                longestFocus: TimeInterval, focusBlocks: Int, contextSwitches: Int,
                callSeconds: TimeInterval, isWeekend: Bool = false) {
        self.day = day; self.date = date; self.totals = totals
        self.workByHour = workByHour; self.personalByHour = personalByHour
        self.firstActivity = firstActivity; self.lastActivity = lastActivity
        self.longestFocus = longestFocus; self.focusBlocks = focusBlocks
        self.contextSwitches = contextSwitches; self.callSeconds = callSeconds
        self.isWeekend = isWeekend
    }
}

/// Several days, summarised together.
public struct RangeStats: Sendable, Equatable {
    public var days: [DayStats]
    /// Where work time went, biggest first.
    public var contexts: [(key: String, detail: String, seconds: TimeInterval)]
    /// The day still in progress. Excluded from anything describing a typical
    /// day, since a partial day would drag every average down.
    public var today: String?

    public static func == (a: RangeStats, b: RangeStats) -> Bool {
        a.days == b.days && a.contexts.map(\.key) == b.contexts.map(\.key)
    }

    public var totalWork: TimeInterval { days.reduce(0) { $0 + $1.totals.work } }
    public var totalPersonal: TimeInterval { days.reduce(0) { $0 + $1.totals.personal } }
    public var totalUnclassified: TimeInterval { days.reduce(0) { $0 + $1.totals.unclassified } }

    /// Days with real work on them. Averaging over untracked days would make
    /// every holiday look like a slow week.
    public var activeDays: [DayStats] { days.filter { $0.totals.work > 60 } }

    /// Active days that have actually finished.
    public var completedActiveDays: [DayStats] { activeDays.filter { $0.day != today } }

    /// Averages describe a finished day, so today is left out. Zero means there
    /// is not a complete day in the range yet, which the UI says rather than
    /// printing a misleading number.
    public var averageWorkPerActiveDay: TimeInterval {
        let d = completedActiveDays
        guard !d.isEmpty else { return 0 }
        return d.reduce(0) { $0 + $1.totals.work } / Double(d.count)
    }

    /// Work per hour of the day, summed across the range.
    public var workByHour: [TimeInterval] {
        var out = [TimeInterval](repeating: 0, count: 24)
        for d in days { for h in 0..<24 { out[h] += d.workByHour[h] } }
        return out
    }

    public var busiestHour: Int? {
        let b = workByHour
        guard let m = b.max(), m > 0 else { return nil }
        return b.firstIndex(of: m)
    }

    /// The window most work happens in: the shortest run of hours holding 80%
    /// of it. More honest than "9 to 5" guesses.
    public var coreHours: ClosedRange<Int>? {
        let b = workByHour
        let total = b.reduce(0, +)
        guard total > 0 else { return nil }
        var best: ClosedRange<Int>?
        for start in 0..<24 {
            var sum: TimeInterval = 0
            for end in start..<24 {
                sum += b[end]
                if sum >= total * 0.8 {
                    let candidate = start...end
                    if best == nil || candidate.count < best!.count { best = candidate }
                    break
                }
            }
        }
        return best
    }

    public var longestFocus: TimeInterval { days.map(\.longestFocus).max() ?? 0 }
    public var totalCallSeconds: TimeInterval { days.reduce(0) { $0 + $1.callSeconds } }

    public var weekendWork: TimeInterval {
        days.filter(\.isWeekend).reduce(0) { $0 + $1.totals.work }
    }

    /// Work outside the core hours - a plain read on how much spills into
    /// evenings and early mornings.
    public func workOutside(_ range: ClosedRange<Int>) -> TimeInterval {
        let b = workByHour
        return (0..<24).filter { !range.contains($0) }.reduce(0) { $0 + b[$1] }
    }

    public var averageSwitchesPerWorkHour: Double {
        let hours = totalWork / 3600
        guard hours > 0.1 else { return 0 }
        return Double(days.reduce(0) { $0 + $1.contextSwitches }) / hours
    }

    public static func compute(days: [DayStats],
                               contexts: [(key: String, detail: String, seconds: TimeInterval)],
                               today: String? = nil) -> RangeStats {
        RangeStats(days: days.sorted { $0.day < $1.day }, contexts: contexts, today: today)
    }

    /// Rolls up where work time went across many days.
    public static func contexts(from segmentsByDay: [[Segment]], limit: Int = 12)
        -> [(key: String, detail: String, seconds: TimeInterval)] {
        var acc: [String: (String, TimeInterval)] = [:]
        for segments in segmentsByDay {
            for s in segments where s.state == .work {
                guard let snap = s.snapshot else { continue }
                let key = snap.groupingKey
                let prev = acc[key]
                acc[key] = (prev?.0 ?? snap.summary, (prev?.1 ?? 0) + s.duration)
            }
        }
        return acc.map { (key: $0.key, detail: $0.value.0, seconds: $0.value.1) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit).map { $0 }
    }

    public init(days: [DayStats],
                contexts: [(key: String, detail: String, seconds: TimeInterval)],
                today: String? = nil) {
        self.days = days; self.contexts = contexts; self.today = today
    }
}

public extension Store {
    /// Classifies this calendar period through now under the current rules.
    /// Days with no record are skipped rather than counted as zero. A live day
    /// replaces its saved record so unflushed work is included exactly once.
    func stats(period: StatsPeriod = .week, rules: RuleSet, settings: Settings,
               calendar: Calendar = StatsPeriod.calendar, now: Date = Date(),
               currentDay: DayData? = nil) -> RangeStats {
        let classifier = Classifier(rules: rules, settings: settings)
        let interval = period.interval(containing: now, calendar: calendar)
        let firstDay = Format.day(interval.start, calendar: calendar)
        let today = Format.day(now, calendar: calendar)
        var available = Set(availableDays())
        if let currentDay { available.insert(currentDay.day) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        var stats: [DayStats] = []
        var segmentsByDay: [[Segment]] = []
        for day in available.sorted() where day >= firstDay && day <= today {
            let d = currentDay?.day == day ? currentDay! : load(day: day)
            guard !d.isEmpty,
                  let dayStart = formatter.date(from: day),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }
            let bounds = Span(max(interval.start, dayStart), min(now, dayEnd))
            guard bounds.duration > 0 else { continue }

            // Classify the recorded timeline before clipping: input just before
            // a boundary can still explain whether the user was present after it.
            let segs = Manual.apply(d.manual,
                                    to: classifier.classify(observations: d.observations,
                                                            presence: d.presence))
                .compactMap { segment -> Segment? in
                    guard let overlap = Span(segment.start, segment.end).intersection(bounds)
                    else { return nil }
                    var clipped = segment
                    clipped.start = overlap.start
                    clipped.end = overlap.end
                    return clipped
                }
            var presence = d.presence
            presence.call = PresenceLog.merge(presence.call, tolerance: 0)
                .compactMap { $0.intersection(bounds) }
            guard !segs.isEmpty || !presence.call.isEmpty else { continue }
            stats.append(DayStats.compute(day: day, segments: segs, presence: presence,
                                          calendar: calendar))
            segmentsByDay.append(segs)
        }
        return RangeStats.compute(days: stats,
                                  contexts: RangeStats.contexts(from: segmentsByDay),
                                  today: today)
    }
}
