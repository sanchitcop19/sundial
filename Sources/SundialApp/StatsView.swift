import SwiftUI
import Charts
import SundialCore

/// History and patterns. Everything shown is recomputed from the raw record
/// under the current rules, so fixing a rule corrects the charts too.
struct StatsView: View {
    @EnvironmentObject var engine: Engine
    @State private var period: StatsPeriod = .year
    @State private var stats: RangeStats?
    @State private var loading = false
    @State private var requestedAt = Date()
    @State private var requestID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let s = stats, !s.days.isEmpty {
                    summary(s)
                    dailyChart(s)
                    hourChart(s)
                    heatmap(s)
                    rhythm(s)
                    contexts(s)
                } else if loading {
                    Card { ProgressView("Reading history…").frame(maxWidth: .infinity) }
                } else {
                    Card {
                        Text("No recorded activity \(period.title.lowercased()) yet.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.canvas)
        .onAppear(perform: reload)
        .onChange(of: period) { _, _ in reload() }
        .onChange(of: engine.day) { _, _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Stats").font(.system(size: 19, weight: .semibold))
            Spacer()
            ForEach(StatsPeriod.allCases, id: \.self) { choice in
                Button { period = choice } label: {
                    Text(choice.title)
                        .font(Theme.figure(11, .semibold)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(period == choice ? Theme.work : Theme.surface)
                        .foregroundStyle(period == choice ? Color.black : Color.secondary)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button { reload() } label: {
                if loading && stats != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 4)
        }
    }

    // MARK: - Panels

    private func summary(_ s: RangeStats) -> some View {
        let weekly = s.weeklyWorkStats(period: period, now: requestedAt)
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        SectionLabel(period == .week
                                     ? "hours worked this week" : "average weekly hours worked")
                        Text(period == .week ? Format.duration(s.totalWork)
                             : weekly.averageWork.map { Format.duration($0) } ?? "—")
                            .font(Theme.hero).monospacedDigit().foregroundStyle(Theme.work)
                        Text(periodDates + (period == .week ? " · so far" : ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if period != .week {
                            Text(weekly.completedWeeks == 0
                                 ? "No complete weeks with records yet"
                                 : "\(weekly.completedWeeks) complete week"
                                   + (weekly.completedWeeks == 1 ? "" : "s")
                                   + " · current week excluded")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if period != .week {
                        VStack(alignment: .trailing, spacing: 3) {
                            SectionLabel("total \(period.title.lowercased())")
                            Text(Format.duration(s.totalWork))
                                .font(Theme.figure(21)).monospacedDigit()
                            Text("so far").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().overlay(Theme.hairline)
                HStack(alignment: .top, spacing: 0) {
                    tiles(s)
                }
            }
        }
    }

    @ViewBuilder
    private func tiles(_ s: RangeStats) -> some View {
        Group {
            stat("Average day",
                     s.completedActiveDays.isEmpty ? "—" : Format.duration(s.averageWorkPerActiveDay),
                     sub: s.completedActiveDays.isEmpty
                          ? "no complete day yet"
                          : "\(s.completedActiveDays.count) complete day"
                            + "\(s.completedActiveDays.count == 1 ? "" : "s"), today excluded")
                stat("Longest focus", Format.duration(s.longestFocus),
                     sub: "tracked work, pauses excluded")
                if s.totalCallSeconds > 60 {
                    stat("In calls", Format.duration(s.totalCallSeconds),
                         sub: pct(s.totalCallSeconds, of: s.totalWork))
                }
                if s.totalUnclassified > 60 {
                    stat("Unclassified", Format.duration(s.totalUnclassified),
                         sub: pct(s.totalUnclassified, of: s.totalWork + s.totalUnclassified),
                         tint: Theme.unclassified)
                }
        }
    }

    private func stat(_ label: String, _ value: String, sub: String? = nil,
                      tint: Color = .primary) -> some View {
        StatTile(value: value, label: label, detail: sub, tint: tint, compact: true)
    }

    private func dailyChart(_ s: RangeStats) -> some View {
        Card(title: "Work per day") {
            // A categorical axis, not a time axis: days are discrete buckets, and
            // a continuous scale stretches a short range into absurdly wide bars.
            Chart(s.days) { d in
                BarMark(x: .value("Day", d.day),
                        y: .value("Hours", d.totals.work / 3600))
                    .foregroundStyle(d.day == s.today
                                     ? Theme.work.opacity(0.3)
                                     : (d.isWeekend
                                        ? Theme.work.opacity(0.5)
                                        : Theme.work))
                    .cornerRadius(4)
                if s.averageWorkPerActiveDay > 0 {
                    RuleMark(y: .value("Average", s.averageWorkPerActiveDay / 3600))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.primary.opacity(0.35))
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDays(s)) { v in
                    AxisValueLabel {
                        if let d = v.as(String.self) { Text(shortDay(d)).font(.system(size: 9)) }
                    }
                }
            }
            .chartYAxisLabel("hours")
            .frame(height: 150)
            Text("Weekends are paler, and today is paler still because it is not finished. "
                 + "The dashed line is the average of complete days.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func hourChart(_ s: RangeStats) -> some View {
        Card(title: "When you work") {
            Chart {
                ForEach(Array(s.workByHour.enumerated()), id: \.offset) { hour, seconds in
                    BarMark(x: .value("Hour", hour), y: .value("Hours", seconds / 3600))
                        .foregroundStyle(TimeCategory.work.gradient)
                        .cornerRadius(3)
                }
            }
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { v in
                    AxisValueLabel { if let h = v.as(Int.self) { Text(hourLabel(h)) } }
                    AxisGridLine()
                }
            }
            .chartYAxisLabel("hours")
            .frame(height: 130)
            if let core = s.coreHours {
                let outside = s.workOutside(core)
                Text("Most work happens between \(hourLabel(core.lowerBound)) and "
                     + "\(hourLabel(core.upperBound + 1)). "
                     + (outside > 60
                        ? "\(Format.duration(outside)) falls outside that."
                        : "Almost none falls outside that."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    /// Day by hour, so patterns like late evenings or slow Mondays are visible
    /// at a glance rather than inferred from totals.
    private func heatmap(_ s: RangeStats) -> some View {
        Card(title: "Hour by hour") {
            let peak = max(1, s.days.flatMap(\.workByHour).max() ?? 1)
            Chart {
                ForEach(s.days) { d in
                    ForEach(Array(d.workByHour.enumerated()), id: \.offset) { hour, seconds in
                        RectangleMark(
                            x: .value("Hour", hour),
                            y: .value("Day", d.day),
                            width: .ratio(1), height: .ratio(1))
                            .foregroundStyle(Theme.work
                                .opacity(seconds <= 0 ? 0.06 : 0.16 + 0.84 * (seconds / peak)))
                            .cornerRadius(2)
                    }
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { v in
                    AxisValueLabel { if let h = v.as(Int.self) { Text(hourLabel(h)) } }
                }
            }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading) { v in
                    AxisValueLabel {
                        if let d = v.as(String.self) { Text(String(d.suffix(5))).font(.system(size: 9)) }
                    }
                }
            }
            .frame(height: CGFloat(max(120, s.days.count * 16)))
            Text("Darker means more work in that hour. Each row is a day.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func rhythm(_ s: RangeStats) -> some View {
        Card(title: "Shape of the day") {
            let active = s.completedActiveDays
            let starts = active.compactMap(\.firstActivity)
            let ends = active.compactMap(\.lastActivity)
            let density = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.density } / Double(active.count)
            HStack(alignment: .top, spacing: 0) {
                if let m = median(starts) { stat("Typical start", Format.clock(m)) }
                if let m = median(ends) { stat("Typical finish", Format.clock(m)) }
                stat("Focused", active.isEmpty ? "—" : String(format: "%.0f%%", density * 100),
                     sub: "of a finished day")
                stat("Switches", String(format: "%.1f/h", s.averageSwitchesPerWorkHour),
                     sub: "changes of subject")
                if s.weekendWork > 60 {
                    stat("Weekend", Format.duration(s.weekendWork), tint: Theme.unclassified)
                }
            }
        }
    }

    private func contexts(_ s: RangeStats) -> some View {
        Card(title: "Where the work went") {
            if s.contexts.isEmpty {
                Text("No classified work in this range.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let peak = s.contexts.first?.seconds ?? 1
                VStack(spacing: 5) {
                    ForEach(s.contexts, id: \.key) { c in
                        HStack(spacing: 8) {
                            Text(c.detail).font(.system(size: 11)).lineLimit(1)
                                .frame(width: 190, alignment: .leading)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(TimeCategory.work.gradient)
                                    .frame(width: max(2, geo.size.width * (c.seconds / peak)))
                            }
                            .frame(height: 11)
                            Text(Format.duration(c.seconds))
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Thin the day labels so a quarter or year stays readable.
    private func axisDays(_ s: RangeStats) -> [String] {
        let stride = max(1, s.days.count / 10)
        return s.days.enumerated().filter { $0.offset % stride == 0 }.map(\.element.day)
    }

    private func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let m = Int(parts[1]) ?? 0
        return "\(months.indices.contains(m) ? months[m] : "")\u{00a0}\(Int(parts[2]) ?? 0)"
    }

    private func hourLabel(_ h: Int) -> String {
        let hour = h % 24
        if hour == 0 { return "12a" }
        if hour == 12 { return "12p" }
        return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }

    private func pct(_ part: TimeInterval, of whole: TimeInterval) -> String {
        guard whole > 0 else { return "" }
        return String(format: "%.0f%% of work", part / whole * 100)
    }

    /// Median rather than mean: one very late night should not move "typical".
    private func median(_ dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        let minutes = dates.map { d -> Int in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }.sorted()
        let mid = minutes[minutes.count / 2]
        return Calendar.current.date(bySettingHour: mid / 60, minute: mid % 60, second: 0, of: Date())
    }

    /// The last result for the period shows at once while a fresh one is read.
    private func reload() {
        loading = true
        let cached = engine.statsCache[period]
        stats = cached?.stats
        if let cached { requestedAt = cached.at }
        let id = UUID()
        requestID = id
        let now = Date()
        let requested = period
        engine.loadStats(period: requested, now: now) { result in
            engine.statsCache[requested] = (result, now)
            guard requestID == id else { return }
            requestedAt = now
            stats = result
            loading = false
        }
    }

    private var periodDates: String {
        let calendar = StatsPeriod.calendar
        let interval = period.interval(containing: requestedAt, calendar: calendar)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: interval.start, to: lastDay)
    }
}
