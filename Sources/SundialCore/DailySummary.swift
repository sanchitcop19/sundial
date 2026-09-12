import Foundation

/// One row per day, for charting and export.
public struct DailySummary: Sendable, Equatable {
    public var date: String
    public var work: TimeInterval
    public var personal: TimeInterval
    public var away: TimeInterval
    public var unclassified: TimeInterval
    public var firstActivity: Date?
    public var lastActivity: Date?
    public var updatedAt: Date

    public init(date: String, work: TimeInterval = 0, personal: TimeInterval = 0,
                away: TimeInterval = 0, unclassified: TimeInterval = 0,
                firstActivity: Date? = nil, lastActivity: Date? = nil,
                updatedAt: Date = Date()) {
        self.date = date; self.work = work; self.personal = personal
        self.away = away; self.unclassified = unclassified
        self.firstActivity = firstActivity; self.lastActivity = lastActivity
        self.updatedAt = updatedAt
    }

    public static func compute(day: String, segments: [Segment], now: Date = Date()) -> DailySummary {
        let t = Totals.compute(segments)
        let active = segments.filter { $0.state == .work || $0.state == .personal }
        return DailySummary(date: day, work: t.work, personal: t.personal,
                            away: t.away, unclassified: t.unclassified,
                            firstActivity: active.map(\.start).min(),
                            lastActivity: active.map(\.end).max(),
                            updatedAt: now)
    }

    public static let csvHeader =
        "date,work_seconds,personal_seconds,away_seconds,unclassified_seconds,"
        + "work_hours,first_activity,last_activity,updated_at"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    public var csvRow: String {
        [date, String(Int(work.rounded())), String(Int(personal.rounded())),
         String(Int(away.rounded())), String(Int(unclassified.rounded())),
         Format.hours(work),
         firstActivity.map { DailySummary.iso.string(from: $0) } ?? "",
         lastActivity.map { DailySummary.iso.string(from: $0) } ?? "",
         DailySummary.iso.string(from: updatedAt)].joined(separator: ",")
    }

    public static func parse(row: String) -> DailySummary? {
        let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 9, f[0].count == 10, f[0] != "date" else { return nil }
        return DailySummary(date: f[0], work: Double(f[1]) ?? 0, personal: Double(f[2]) ?? 0,
                            away: Double(f[3]) ?? 0, unclassified: Double(f[4]) ?? 0,
                            firstActivity: f[6].isEmpty ? nil : iso.date(from: f[6]),
                            lastActivity: f[7].isEmpty ? nil : iso.date(from: f[7]),
                            updatedAt: iso.date(from: f[8]) ?? Date())
    }
}

public extension Store {
    func upsertDaily(_ summary: DailySummary) {
        Store.lockCSV()
        defer { Store.unlockCSV() }
        var rows: [String: String] = [:]
        if let text = try? String(contentsOf: dailyCSVURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let p = DailySummary.parse(row: String(line)) else { continue }
                rows[p.date] = String(line)
            }
        }
        rows[summary.date] = summary.csvRow
        let body = rows.keys.sorted().compactMap { rows[$0] }.joined(separator: "\n")
        try? (DailySummary.csvHeader + "\n" + body + "\n")
            .write(to: dailyCSVURL, atomically: true, encoding: .utf8)
    }

    func loadDaily() -> [DailySummary] {
        guard let text = try? String(contentsOf: dailyCSVURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { DailySummary.parse(row: String($0)) }
            .sorted { $0.date < $1.date }
    }

    /// Recomputes every day from raw observations under the current rules. This
    /// is what makes a rule fix apply to history, not just to today.
    @discardableResult
    func rebuildDaily(rules: RuleSet, settings: Settings, now: Date = Date()) -> [DailySummary] {
        let summaries = availableDays().map { day in
            DailySummary.compute(day: day,
                                 segments: segments(for: day, rules: rules, settings: settings),
                                 now: now)
        }
        Store.lockCSV()
        defer { Store.unlockCSV() }
        let body = summaries.map(\.csvRow).joined(separator: "\n")
        try? (DailySummary.csvHeader + "\n" + body + (body.isEmpty ? "" : "\n"))
            .write(to: dailyCSVURL, atomically: true, encoding: .utf8)
        return summaries
    }
}
