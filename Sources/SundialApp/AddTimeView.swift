import SwiftUI
import SundialCore

/// Adding time the tracker could not see, and taking it back out again.
struct AddTimeView: View {
    @EnvironmentObject var engine: Engine
    /// Closed by the caller, the way the correction sheet is.
    var done: () -> Void

    @State private var day = Date()
    @State private var startTime = Date()
    @State private var hours = 0
    @State private var minutes = 30
    @State private var category: TimeCategory = .work
    @State private var note = ""
    @State private var problem: String?

    /// The day is picked separately from the time of day, so the calendar and
    /// the clock do not fight over one control.
    private var start: Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: startTime)
        return cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0,
                        second: 0, of: day) ?? day
    }

    private var length: TimeInterval { TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60 }
    private var end: Date { start.addingTimeInterval(length) }
    private var entriesOnDay: [ManualEntry] { engine.manualEntries(on: Format.day(day)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add time").font(.system(size: 15, weight: .semibold))
            Text("For work the tracker could not see: a meeting away from the desk, a call on "
                 + "your phone, a day on another machine. Anything already recorded underneath "
                 + "is replaced, so nothing is counted twice.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Day").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    DatePicker("", selection: $day, in: ...Date(),
                               displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("From").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    DatePicker("", selection: $startTime,
                               displayedComponents: .hourAndMinute).labelsHidden()
                }
                GridRow {
                    Text("For").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        Stepper(value: $hours, in: 0...23) {
                            Text("\(hours)h").monospacedDigit().frame(width: 30, alignment: .leading)
                        }
                        Stepper(value: $minutes, in: 0...55, step: 5) {
                            Text("\(minutes)m").monospacedDigit().frame(width: 36, alignment: .leading)
                        }
                        Text("ends \(Format.clock(end))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Counts as").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    Picker("", selection: $category) {
                        ForEach([TimeCategory.work, .personal, .away], id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
                GridRow {
                    Text("Note").font(.system(size: 12)).gridColumnAlignment(.trailing)
                    TextField("optional, e.g. standup", text: $note).frame(width: 240)
                }
            }

            if let problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entriesOnDay.isEmpty {
                Divider()
                Text("ALREADY ADDED ON \(Format.day(day))")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .tracking(0.6)
                ForEach(entriesOnDay) { e in
                    HStack(spacing: 8) {
                        Circle().fill(e.category.color).frame(width: 8, height: 8)
                        Text("\(Format.clock(e.start))–\(Format.clock(e.end))")
                            .font(.system(size: 11)).monospacedDigit()
                        Text(Format.duration(e.duration))
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        if !e.note.isEmpty {
                            Text(e.note).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Remove") { engine.removeManual(id: e.id, day: Format.day(day)) }
                            .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    problem = engine.addManual(start: start, end: end, category: category,
                                               note: note.trimmingCharacters(in: .whitespaces))
                    if problem == nil { done() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(length <= 0)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
