import SwiftUI
import SundialCore

struct TodayView: View {
    @EnvironmentObject var engine: Engine
    @State private var selection: Segment?
    @State private var correcting: Snapshot?
    @State private var addingTime = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                if let s = selection { inspector(for: s) } else { nowCard }
                stretches
            }
            .padding(16)
        }
        .background(Theme.canvas)
        .sheet(item: $correcting) { snap in
            CorrectionView(snapshot: snap, currentState: selection?.state) { correcting = nil }
                .environmentObject(engine)
        }
        .sheet(isPresented: $addingTime) {
            AddTimeView { addingTime = false }.environmentObject(engine)
        }
    }

    /// The number first, everything else in service of it.
    private var hero: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        SectionLabel("worked today")
                        Text(Format.duration(engine.totals.work))
                            .font(Theme.hero).monospacedDigit()
                            .foregroundStyle(Theme.work)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(engine.day)
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Add time…") { addingTime = true }.controlSize(.small)
                    }
                }
                if engine.breakStatus.owed {
                    Label("Break due after \(Format.duration(engine.breakStatus.workedStraight)) of work",
                          systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.personal)
                }
                TotalsRow(totals: engine.totals)
                TimelineBar(segments: engine.displaySegments, selection: $selection)
            }
        }
    }

    private var nowCard: some View {
        Card {
            HStack(spacing: 11) {
                Circle().fill(engine.currentState.gradient).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Right now: \(engine.currentState.label)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(engine.currentReason)
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let snap = engine.currentSnapshot {
                    Button("Fix this…") { correcting = snap }.controlSize(.small)
                }
            }
        }
    }

    private var stretches: some View {
        Card(title: "Today’s stretches") {
            if engine.displaySegments.isEmpty {
                Text("Nothing recorded yet. Keep working and this fills in.")
                    .font(Theme.body).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(engine.displaySegments.reversed()) { seg in
                        SegmentRow(segment: seg, selected: selection?.start == seg.start)
                            .onTapGesture { selection = selection?.start == seg.start ? nil : seg }
                    }
                }
            }
        }
    }

    private func inspector(for seg: Segment) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Circle().fill(seg.state.gradient).frame(width: 11, height: 11)
                    Text(seg.state.label).font(Theme.title)
                    Text("\(Format.clock(seg.start))–\(Format.clock(seg.end)) · \(Format.duration(seg.duration))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Clear") { selection = nil }.controlSize(.small)
                }
                if let snap = seg.snapshot {
                    Text(snap.summary).font(Theme.body)
                    if let u = snap.url {
                        Text(u).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Text(seg.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                if let snap = seg.snapshot {
                    HStack {
                        Button("This is wrong — fix it…") { correcting = snap }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                        if let rid = seg.ruleId {
                            Button("Remove the rule that did this") { engine.remove(ruleId: rid) }
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

extension Snapshot: Identifiable {
    public var id: String { groupingKey + (url ?? "") + (windowTitle ?? "") }
}
