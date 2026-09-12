import SwiftUI
import UniformTypeIdentifiers
import SundialCore

extension TimeCategory {
    var color: Color {
        switch self {
        case .work:         return Color(red: 0.20, green: 0.65, blue: 0.42)
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
            Text("Sundial on your Mac backs its record up to a cloud folder. "
                 + "Point this app at the same folder and you can see your day and "
                 + "work through the review queue from here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Text("Usually iCloud Drive › Sundial")
                .font(.footnote).foregroundStyle(.tertiary)
            Button("Choose folder…") { picking = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let s = library.status {
                Text(s).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 28)
            }
            Spacer()
            Text("Your phone cannot see which app you are using — iOS has no such API. "
                 + "This shows the Mac's record and tracks phone work you start yourself.")
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
                } header: { Text(library.day) }

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

/// Phone work is user-started by necessity, and the app says so rather than
/// implying it was measured.
struct SessionView: View {
    @EnvironmentObject var library: Library
    @State private var label = "Phone"
    @State private var outcome: Outcome = .work
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                if let s = library.activeSession {
                    Section {
                        VStack(spacing: 8) {
                            Text(Format.duration(now.timeIntervalSince(s.start)))
                                .font(.system(size: 44, weight: .light, design: .rounded))
                                .monospacedDigit()
                            Text("\(s.label) · \(s.outcome.label)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        Button("Stop and send to Mac", role: .destructive) { library.stopSession() }
                    }
                } else {
                    Section("What are you doing?") {
                        TextField("Label", text: $label)
                        Picker("Counts as", selection: $outcome) {
                            ForEach(Outcome.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented)
                        Button("Start") { library.startSession(label: label, outcome: outcome) }
                            .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Text("iOS gives no app any way to see which other app you are using, so "
                         + "phone time has to be started by you. It is recorded as your own "
                         + "entry, never presented as something measured.")
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
            .navigationTitle("Session")
            .onReceive(tick) { now = $0 }
        }
    }
}
