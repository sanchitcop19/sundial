import SwiftUI
import UniformTypeIdentifiers
import SundialCore

extension TimeCategory {
    var color: Color {
        switch self {
        case .work:         return MobileTheme.accent
        case .personal:     return Color(red: 0.35, green: 0.52, blue: 0.85)
        case .away:         return Color.secondary.opacity(0.35)
        case .unclassified: return Color(red: 0.92, green: 0.58, blue: 0.16)
        }
    }
}

/// First run: point the app at the folder the Mac backs up to.
struct ConnectView: View {
    @EnvironmentObject var library: Library
    @State private var picking = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("Connect to your Mac").font(.title2.weight(.semibold))
            Text("In Sundial on your Mac, enable Sync work progress to iPhone. "
                 + "Your Mac creates a Sundial folder in iCloud Drive. Choose that existing folder here to see hours worked and remaining, "
                 + "then start a Live Activity for your Lock Screen.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Text("Use the same cloud storage account on both devices.")
                .font(.footnote).foregroundStyle(.tertiary)
            Button("Choose folder…") { picking = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let s = library.status {
                Text(s).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 28)
            }
            Spacer()
            Text("The progress summary contains totals, not activity titles. "
                 + "You can also sync the raw record from your Mac to review activities here.")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.bottom, 12)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.connect(to: url) }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        NavigationStack {
            List {
                WorkProgressSection()
                if library.hasDetail || !library.daily.isEmpty {
                Section {
                    ForEach(TimeCategory.allCases, id: \.self) { c in
                        let v = library.totals.byState[c] ?? 0
                        if v > 0 || c == .work {
                            HStack {
                                Circle().fill(c.color).frame(width: 10, height: 10)
                                Text(c.label)
                                Spacer()
                                Text(Format.duration(v)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Record · \(library.day)") }
                }

                if let s = library.status {
                    Section { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }

                if !library.daily.isEmpty {
                    Section("Recent days") {
                        ForEach(library.daily.suffix(7).reversed(), id: \.date) { d in
                            HStack {
                                Text(d.date).monospacedDigit()
                                Spacer()
                                Text(Format.duration(d.work)).monospacedDigit()
                                    .foregroundStyle(TimeCategory.work.color)
                            }
                            .font(.callout)
                        }
                    }
                }

                if library.hasDetail {
                    Section("Stretches") {
                        ForEach(library.segments.reversed().prefix(40)) { seg in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(seg.state.color).frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(seg.snapshot?.summary ?? seg.state.label)
                                        .font(.callout).lineLimit(1)
                                    Text("\(Format.clock(seg.start))–\(Format.clock(seg.end))")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Spacer()
                                Text(Format.duration(seg.duration))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .refreshable { library.refresh() }
            .toolbar {
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }
}

/// The review queue is the best thing to do on a phone: short decisions, done
/// anywhere, and each one teaches the Mac a rule for good.
struct MobileReviewView: View {
    @EnvironmentObject var library: Library
    @State private var choosing: ReviewItem?

    var body: some View {
        NavigationStack {
            Group {
                if !library.hasDetail {
                    ContentUnavailableView("No detailed record",
                        systemImage: "questionmark.folder",
                        description: Text("Turn on “Include the raw record” in the Mac app's "
                                          + "backup settings to review time from here."))
                } else if library.reviewItems.filter(\.isActionable).isEmpty
                            && library.reviewItems.isEmpty {
                    ContentUnavailableView("Nothing to decide", systemImage: "checkmark.circle",
                        description: Text("Every stretch today matches a rule."))
                } else {
                    List {
                        let blind = library.reviewItems.filter { !$0.isActionable }
                        if !blind.isEmpty {
                            Section("Cannot be classified") {
                                Text("\(Format.duration(blind.reduce(0) { $0 + $1.seconds })) was "
                                     + "recorded before Accessibility was granted on the Mac. Only "
                                     + "the app name was visible, so no rule can place it.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(library.reviewItems.filter(\.isActionable)) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.snapshot.summary).font(.callout.weight(.medium))
                                Text("\(Format.duration(item.seconds)) · seen \(item.occurrences)×")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Work") { quick(item, .work) }
                                        .buttonStyle(.bordered).tint(TimeCategory.work.color)
                                    Button("Personal") { quick(item, .personal) }
                                        .buttonStyle(.bordered).tint(TimeCategory.personal.color)
                                    Spacer()
                                    Button("Scope…") { choosing = item }.buttonStyle(.bordered)
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Review")
            .refreshable { library.refresh() }
            .sheet(item: $choosing) { item in
                ScopeSheet(snapshot: item.snapshot) { rule in
                    library.add(rule); choosing = nil
                } onCancel: { choosing = nil }
            }
        }
    }

    private func quick(_ item: ReviewItem, _ outcome: Outcome) {
        let ladder = Suggestions.build(for: item.snapshot)
        let choice = ladder.first { $0.scope == .site }
            ?? ladder.first { $0.scope == .workspace }
            ?? ladder.first { $0.scope == .project }
            ?? ladder.first { $0.scope == .app }
        guard let choice else { return }
        library.add(choice.rule(outcome: outcome))
    }
}

/// The same scope ladder the Mac offers, so a decision made here is exactly the
/// decision that would have been made there.
struct ScopeSheet: View {
    let snapshot: Snapshot
    var onAdd: (Rule) -> Void
    var onCancel: () -> Void

    @State private var outcome: Outcome = .personal
    @State private var selected: Suggestion?

    private var suggestions: [Suggestion] { Suggestions.build(for: snapshot) }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(snapshot.summary).font(.callout) }
                Section("This is") {
                    Picker("", selection: $outcome) {
                        ForEach(Outcome.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Section("Apply to") {
                    ForEach(suggestions) { s in
                        Button {
                            selected = s
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: selected?.id == s.id
                                      ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.callout)
                                    Text(s.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add rule") {
                        if let s = selected { onAdd(s.rule(outcome: outcome)) }
                    }.disabled(selected == nil)
                }
            }
            .onAppear { selected = suggestions.first { $0.scope == .site } ?? suggestions.first }
        }
    }
}

/// Phone time is entered explicitly because iOS cannot observe other apps.
struct DurationEntryView: View {
    @EnvironmentObject var library: Library
    @State private var label = "Phone"
    @State private var outcome: Outcome = .work
    @State private var hours = 0
    @State private var minutes = 30

    private var duration: TimeInterval {
        TimeInterval((hours * 60 + minutes) * 60)
    }

    private var canSend: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && duration > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add phone time") {
                    TextField("Label", text: $label)
                    Picker("Counts as", selection: $outcome) {
                        ForEach(Outcome.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Duration") {
                        HStack(spacing: 6) {
                            Picker("Hours", selection: $hours) {
                                ForEach(0...23, id: \.self) { value in
                                    Text("\(value) hr").tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)

                            Picker("Minutes", selection: $minutes) {
                                ForEach(0...59, id: \.self) { value in
                                    Text("\(value) min").tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    Button {
                        library.sendDuration(label: label, outcome: outcome, duration: duration)
                    } label: {
                        Label("Send to Mac", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                }

                Section {
                    if let running = library.timer {
                        VStack(spacing: 4) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Format.clockDuration(running.elapsed(at: context.date)))
                                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                            Text("\(running.label) · counts as \(running.outcome.label.lowercased())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)

                        Button {
                            library.stopTimer()
                        } label: {
                            Label("Stop and send to Mac", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Discard timer", role: .destructive) { library.discardTimer() }
                    } else {
                        Button {
                            library.startTimer(label: label, outcome: outcome)
                        } label: {
                            Label("Start timer", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Timer")
                } footer: {
                    Text(library.timer == nil
                         ? "Uses the label and type above. Nothing is sent until you stop it."
                         : "Keeps running if you close the app.")
                }
                .animation(MobileTheme.motion, value: library.timer)

                if let status = library.durationStatus {
                    Section {
                        Label(status.message, systemImage: status.systemImage)
                            .font(.callout)
                            .foregroundStyle(status.isFailure ? Color.orange : MobileTheme.accent)
                    }
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }

                Section {
                    Text("iOS gives no app any way to see which other app you are using, so "
                         + "phone time has to be entered by you. The duration ends when you "
                         + "tap Send and is never presented as something Sundial measured.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Connection") {
                    if let f = library.folder {
                        LabeledContent("Folder", value: f.lastPathComponent)
                    }
                    if library.pendingCount > 0 {
                        LabeledContent("Waiting for the Mac", value: "\(library.pendingCount)")
                    }
                    Button("Disconnect", role: .destructive) { library.disconnect() }
                }
            }
            .navigationTitle("Add Time")
            .animation(MobileTheme.motion, value: library.durationStatus)
        }
    }
}
