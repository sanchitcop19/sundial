import Foundation

/// Days marked as paid time off.
///
/// Work done on a day off is a bonus. It counts in every total and lifts the
/// averages, but the day itself is never counted as one you were meant to
/// work, so a day off with nothing on it cannot pull an average down. A week
/// with three weekdays off is measured as two fifths of a week.
///
/// Kept as plain day strings, beside the record rather than in it: marking a
/// day off says nothing about what was on screen.
public enum TimeOff {
    /// Weekdays from one date through another, inclusive, as day strings.
    /// Weekends are left out because they are never workdays to begin with.
    public static func weekdays(from start: Date, through end: Date,
                                calendar: Calendar = .current) -> [String] {
        let first = calendar.startOfDay(for: min(start, end))
        let last = calendar.startOfDay(for: max(start, end))
        var out: [String] = []
        var cursor = first
        // Bounded: a wild range must not spin. Ten years is plenty.
        for _ in 0..<3700 {
            guard cursor <= last else { break }
            if !isWeekend(cursor, calendar: calendar) {
                out.append(Format.day(cursor, calendar: calendar))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    /// A stretch of consecutive weekdays off.
    public struct Run: Sendable, Equatable, Identifiable {
        public var days: [String]
        public var id: String { first }
        public var first: String { days[0] }
        public var last: String { days[days.count - 1] }
        public var count: Int { days.count }
    }

    /// Groups days off into runs, so a week away reads as one line. Days either
    /// side of a weekend belong to the same run.
    public static func runs(_ days: Set<String>, calendar: Calendar = .current) -> [Run] {
        var out: [Run] = []
        for day in days.sorted() {
            if let previous = out.last, nextWeekday(after: previous.last, calendar: calendar) == day {
                out[out.count - 1].days.append(day)
            } else {
                out.append(Run(days: [day]))
            }
        }
        return out
    }

    static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        [1, 7].contains(calendar.component(.weekday, from: date))
    }

    public static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.date(from: day)
    }

    private static func nextWeekday(after day: String, calendar: Calendar) -> String? {
        guard var cursor = date(day, calendar: calendar) else { return nil }
        for _ in 0..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
            if !isWeekend(cursor, calendar: calendar) { return Format.day(cursor, calendar: calendar) }
        }
        return nil
    }
}

public extension Store {
    var timeOffURL: URL { root.appendingPathComponent("time-off.json") }

    func loadTimeOff() -> Set<String> {
        guard let d = try? Data(contentsOf: timeOffURL),
              let days = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(days)
    }

    func save(timeOff days: Set<String>) {
        guard !days.isEmpty else {
            try? FileManager.default.removeItem(at: timeOffURL)
            return
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        guard let d = try? e.encode(days.sorted()) else { return }
        try? d.write(to: timeOffURL, options: .atomic)
    }
}
