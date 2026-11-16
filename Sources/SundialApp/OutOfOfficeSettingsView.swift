import SwiftUI
import SundialCore

/// Days away from work, for holidays and leave. They get no daily target, make
/// the weekly goal proportionally smaller, and stay out of every average.
struct OutOfOfficeSettingsView: View {
    @EnvironmentObject var engine: Engine
    @State private var first = Date()
    @State private var last = Date()

    private var calendar: Calendar { StatsPeriod.calendar }
    private var runs: [OutOfOffice.Run] { engine.outOfOffice.runs(calendar: calendar).reversed() }

    var body: some View {
        Card(title: "Out of office") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Days off have no daily target, shrink the weekly goal to match, and are "
                     + "left out of averages. Work you record on them still counts in your totals.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    DatePicker("From", selection: $first, displayedComponents: .date)
                        .onChange(of: first) { _, new in if last < new { last = new } }
                    DatePicker("To", selection: $last, in: first..., displayedComponents: .date)
                    Button("Add") { engine.markOutOfOffice(true, from: first, through: last) }
                        .controlSize(.small)
                }
                .font(.system(size: 12))
                if runs.isEmpty {
                    Text("No days marked.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(runs) { run in
                    HStack {
                        Text(label(run)).font(.system(size: 12)).monospacedDigit()
                        Text("\(run.count) day\(run.count == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button { engine.removeOutOfOffice(run) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Remove these days")
                    }
                }
            }
        }
    }

    private func label(_ run: OutOfOffice.Run) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted,
                                     locale: .current, calendar: calendar, timeZone: calendar.timeZone)
        guard let from = OutOfOffice.date(of: run.first, calendar: calendar),
              let to = OutOfOffice.date(of: run.last, calendar: calendar) else { return run.first }
        return run.count == 1 ? from.formatted(style)
            : "\(from.formatted(style)) – \(to.formatted(style))"
    }
}
