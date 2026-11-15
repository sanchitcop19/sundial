import SwiftUI
import SundialCore

/// Marking days as paid time off. A day off never counts against an average;
/// any work done on one still counts, so it can only help.
struct TimeOffView: View {
    @EnvironmentObject var engine: Engine
    /// Closed by the caller, the way the add-time sheet is.
    var done: () -> Void

    @State private var from = Date()
    @State private var through = Date()
    @State private var days: Set<String> = []

    private let calendar = StatsPeriod.calendar

    private var picked: [String] { TimeOff.weekdays(from: from, through: through, calendar: calendar) }
    private var newDays: [String] { picked.filter { !days.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Time off").font(.system(size: 15, weight: .semibold))
            Text("Days off are left out of your daily and weekly averages, so taking one "
                 + "never makes a week look short. Anything you work on a day off still "
                 + "counts, as a bonus on top.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("From").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    DatePicker("", selection: $from, displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("Through").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    DatePicker("", selection: $through, in: from...,
                               displayedComponents: .date).labelsHidden()
                }
            }

            HStack {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    days.formUnion(picked)
                    engine.setTimeOff(days)
                }
                .disabled(newDays.isEmpty)
            }

            if !days.isEmpty {
                Divider()
                Text("DAYS OFF")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .tracking(0.6)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(TimeOff.runs(days, calendar: calendar).reversed()) { run in
                            HStack(spacing: 8) {
                                Circle().fill(Theme.personal).frame(width: 8, height: 8)
                                Text(label(run)).font(.system(size: 11)).monospacedDigit()
                                Text(run.count == 1 ? "1 day" : "\(run.count) days")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Remove") {
                                    days.subtract(run.days)
                                    engine.setTimeOff(days)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { days = engine.timeOffDays() }
        .onChange(of: from) { _, new in if through < new { through = new } }
    }

    private var summary: String {
        if picked.isEmpty { return "Only a weekend: nothing to add." }
        let n = newDays.count
        if n == 0 { return "Already marked." }
        return "Adds \(n) weekday\(n == 1 ? "" : "s"). Weekends are skipped."
    }

    private func label(_ run: TimeOff.Run) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        func text(_ day: String) -> String {
            TimeOff.date(day, calendar: calendar).map(f.string(from:)) ?? day
        }
        return run.count == 1 ? text(run.first) : "\(text(run.first)) – \(text(run.last))"
    }
}
