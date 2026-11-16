import Foundation

/// Whole days spent away from work.
///
/// A day off is not a slow day. Marked days carry no daily target, shrink the
/// weekly goal in proportion, and are left out of every average. Work recorded
/// on one is still work: it counts in totals and toward the week.
public struct OutOfOffice: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd`, in the calendar the day was recorded under.
    public private(set) var days: Set<String>

    /// Longest span one `add` accepts, so a mistyped year cannot fill the file.
    public static let maxRangeDays = 366

    public init(days: Set<String> = []) {
        self.days = days.filter(OutOfOffice.isDayKey)
    }

    private enum CodingKeys: String, CodingKey { case days }

    /// Lenient: a hand-edited entry that is not a date is dropped, not fatal.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String].self, forKey: .days)) ?? nil
        self.init(days: Set(raw ?? []))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(days.sorted(), forKey: .days)
    }

    public var isEmpty: Bool { days.isEmpty }

    public func contains(_ day: String) -> Bool { days.contains(day) }

    public func contains(_ date: Date, calendar: Calendar = StatsPeriod.calendar) -> Bool {
        days.contains(Format.day(date, calendar: calendar))
    }

    // MARK: - Editing

    /// Marks every day from `first` through `last`, inclusive and in either
    /// order. Returns how many days were newly marked.
    @discardableResult
    public mutating func add(from first: Date, through last: Date,
                             calendar: Calendar = StatsPeriod.calendar) -> Int {
        let before = days.count
        days.formUnion(OutOfOffice.dayKeys(from: first, through: last, calendar: calendar))
        return days.count - before
    }

    @discardableResult
    public mutating func remove(from first: Date, through last: Date,
                                calendar: Calendar = StatsPeriod.calendar) -> Int {
        let before = days.count
        days.subtract(OutOfOffice.dayKeys(from: first, through: last, calendar: calendar))
        return before - days.count
    }

    @discardableResult
    public mutating func remove(days removed: [String]) -> Int {
        let before = days.count
        days.subtract(removed)
        return before - days.count
    }

    static func dayKeys(from first: Date, through last: Date, calendar: Calendar) -> [String] {
        let lower = calendar.startOfDay(for: min(first, last))
        let upper = calendar.startOfDay(for: max(first, last))
        var keys: [String] = []
        var cursor = lower
        while cursor <= upper, keys.count < maxRangeDays {
            keys.append(Format.day(cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    // MARK: - Grouping

    /// A run of consecutive marked days, for listing.
    public struct Run: Sendable, Equatable, Identifiable {
        public var id: String { first }
        public let first: String
        public let last: String
        public let days: [String]
        public var count: Int { days.count }
    }

    /// Consecutive marked days joined into runs, oldest first.
    public func runs(calendar: Calendar = StatsPeriod.calendar) -> [Run] {
        var out: [Run] = []
        var current: [String] = []
        var previous: Date?
        for key in days.sorted() {
            guard let date = OutOfOffice.date(of: key, calendar: calendar) else { continue }
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: date) {
                current.append(key)
            } else {
                if let first = current.first, let last = current.last {
                    out.append(Run(first: first, last: last, days: current))
                }
                current = [key]
            }
            previous = date
        }
        if let first = current.first, let last = current.last {
            out.append(Run(first: first, last: last, days: current))
        }
        return out
    }

    /// Start of the day named by a `yyyy-MM-dd` key.
    public static func date(of key: String, calendar: Calendar = StatsPeriod.calendar) -> Date? {
        guard isDayKey(key) else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        // A date that rolled over (02-30 becoming 03-02) is not the day named.
        return date.flatMap { Format.day($0, calendar: calendar) == key ? $0 : nil }
    }

    static func isDayKey(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else { return false }
        return scalars.enumerated().allSatisfy { i, s in
            i == 4 || i == 7 || (s.value >= 48 && s.value <= 57)
        }
    }

    // MARK: - Attendance

    /// How much of a week was spent at work: planned days minus the ones
    /// marked out of office.
    public struct Attendance: Sendable, Equatable {
        public let planned: Int
        public let away: Int
        public var present: Int { planned - away }
        /// 1 for an ordinary week, 0 when every planned day was away.
        public var fraction: Double { planned > 0 ? Double(present) / Double(planned) : 1 }
    }

    /// Only planned days count: marking a Saturday off in a Monday–Friday week
    /// does not make that week any shorter.
    public func attendance(of week: DateInterval, includeWeekends: Bool,
                           calendar: Calendar = StatsPeriod.calendar) -> Attendance {
        var planned = 0, away = 0
        var cursor = week.start
        while cursor < week.end {
            if WorkTarget.isPlannedDay(cursor, includeWeekends: includeWeekends, calendar: calendar) {
                planned += 1
                if contains(cursor, calendar: calendar) { away += 1 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return Attendance(planned: planned, away: away)
    }
}

public extension Store {
    var outOfOfficeURL: URL { root.appendingPathComponent("out-of-office.json") }

    func loadOutOfOffice() -> OutOfOffice {
        guard let data = try? Data(contentsOf: outOfOfficeURL),
              let value = try? JSONDecoder().decode(OutOfOffice.self, from: data)
        else { return OutOfOffice() }
        return value
    }

    func save(_ outOfOffice: OutOfOffice) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(outOfOffice) else { return }
        try? data.write(to: outOfOfficeURL, options: .atomic)
    }
}
