import Foundation

/// A stretch of time entered by hand, for work the tracker could not see: a
/// meeting away from the desk, a call taken on a phone, a day spent on someone
/// else's machine.
///
/// Deliberately kept beside the observations rather than mixed into them. The
/// raw record stays a record of what was actually on screen, an entry made by
/// hand stays visibly made by hand, and because nobody observed it, editing a
/// rule later does not re-decide it.
public struct ManualEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var category: TimeCategory
    public var note: String

    public init(id: UUID = UUID(), start: Date, end: Date,
                category: TimeCategory = .work, note: String = "") {
        self.id = id; self.start = start; self.end = end
        self.category = category; self.note = note
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public var reason: String {
        note.isEmpty ? "Added by hand" : "Added by hand: \(note)"
    }
}

public enum Manual {
    /// One entry cannot be longer than a day, because a day is where the files
    /// divide. Anything longer is split before it gets here.
    public static let maxLength: TimeInterval = 24 * 3600

    /// Why this entry cannot be added, in a sentence, or nil if it can be.
    ///
    /// Returned as words rather than an error case because every one of these
    /// is something to show the person typing, not something to catch.
    public static func problem(with entry: ManualEntry, existing: [ManualEntry],
                               now: Date = Date()) -> String? {
        if entry.category == .unclassified {
            return "Added time has to be work, personal or away."
        }
        if entry.end <= entry.start {
            return "The end has to come after the start."
        }
        if entry.duration > maxLength {
            return "One entry cannot be longer than a day."
        }
        if entry.end > now.addingTimeInterval(60) {
            return "That is in the future."
        }
        for other in existing where other.id != entry.id {
            if entry.start < other.end && other.start < entry.end {
                return "That overlaps time already added by hand "
                    + "(\(Format.clock(other.start))–\(Format.clock(other.end)))."
            }
        }
        return nil
    }

    /// Splits an entry at midnight, so each day's file stands alone the way
    /// every other record here does.
    public static func split(_ entry: ManualEntry,
                             calendar: Calendar = .current) -> [(day: String, entry: ManualEntry)] {
        guard entry.end > entry.start else { return [] }
        var out: [(String, ManualEntry)] = []
        var cursor = entry.start
        // Bounded rather than while(true): a corrupt date must not spin here.
        for _ in 0..<400 {
            guard cursor < entry.end else { break }
            let dayStart = calendar.startOfDay(for: cursor)
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? entry.end
            let piece = ManualEntry(id: out.isEmpty ? entry.id : UUID(),
                                    start: cursor, end: min(next, entry.end),
                                    category: entry.category, note: entry.note)
            out.append((Format.day(cursor, calendar: calendar), piece))
            cursor = next
        }
        return out
    }

    /// Lays entries over the derived timeline.
    ///
    /// Recorded time underneath an entry is trimmed away rather than left in
    /// place: saying "I was in a meeting from two until three" has to mean the
    /// hour counts once, not that an hour of work is added on top of whatever
    /// the screen happened to show.
    public static func apply(_ entries: [ManualEntry], to segments: [Segment]) -> [Segment] {
        guard !entries.isEmpty else { return segments }
        var kept: [Segment] = []
        for segment in segments {
            var pieces = [segment]
            for entry in entries {
                pieces = pieces.flatMap { cut($0, around: entry) }
            }
            kept += pieces
        }
        kept += entries.map {
            Segment(start: $0.start, end: $0.end, state: $0.category,
                    reason: $0.reason, manual: true)
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// The parts of a segment left uncovered by an entry: none, one, or the
    /// two ends of it.
    private static func cut(_ s: Segment, around e: ManualEntry) -> [Segment] {
        guard s.end > e.start, e.end > s.start else { return [s] }
        var out: [Segment] = []
        if s.start < e.start {
            var head = s; head.end = e.start
            if head.duration > 0 { out.append(head) }
        }
        if s.end > e.end {
            var tail = s; tail.start = e.end
            if tail.duration > 0 { out.append(tail) }
        }
        return out
    }
}
