import SwiftUI
import SundialCore

/// The queue of time no rule could place. Working through it is how the app
/// gets accurate, so it is a first-class screen rather than a warning badge.
struct ReviewView: View {
    @EnvironmentObject var engine: Engine
    @State private var correcting: Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: engine.reviewItems.isEmpty
                          ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundStyle(engine.reviewItems.isEmpty ? Color.green : Color.orange)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.reviewItems.filter(\.isActionable).isEmpty
                             ? "Everything today has a rule"
                             : "\(engine.reviewItems.filter(\.isActionable).count) thing"
                               + "\(engine.reviewItems.filter(\.isActionable).count == 1 ? "" : "s") need a decision")
                            .font(.system(size: 19, weight: .semibold))
                        Text(engine.reviewItems.isEmpty
                             ? "Unclassified time shows up here as soon as it appears."
                             : "\(Format.duration(engine.totals.unclassified)) is unaccounted for. "
                             + "Deciding once teaches the rule for good.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            let actionable = engine.reviewItems.filter(\.isActionable)
            let blind = engine.reviewItems.filter { !$0.isActionable }

            if !actionable.isEmpty {
                Card(title: "Biggest first") {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(actionable) { item in row(item) }
                        }
                    }
                }
            }

            // Time recorded before Accessibility was granted can never be
            // classified - the detail was never captured - so it is explained
            // rather than dressed up as something a rule could fix.
            if !blind.isEmpty {
                Card(title: "Cannot be classified") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Format.duration(blind.reduce(0) { $0 + $1.seconds })) was recorded "
                             + "before Accessibility was granted. Only the app name was visible, "
                             + "so no rule can place it. New time is unaffected.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(blind) { item in
                            HStack {
                                Text(item.snapshot.appName).font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(Format.duration(item.seconds))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        if engine.needsAccessibility {
                            Button("Grant Accessibility…") { Signals.requestAccessibility() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.canvas)
        .sheet(item: $correcting) { snap in
            CorrectionView(snapshot: snap, currentState: .unclassified) { correcting = nil }
                .environmentObject(engine)
        }
    }

    private func row(_ item: ReviewItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.snapshot.summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(Format.duration(item.seconds)) · seen \(item.occurrences)× · "
                     + "\(Format.clock(item.firstSeen))–\(Format.clock(item.lastSeen))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // One tap for the obvious call, the sheet for anything subtler.
            Button("Work") { quick(item, .work) }.controlSize(.small)
            Button("Personal") { quick(item, .personal) }.controlSize(.small)
            Button("Choose…") { correcting = item.snapshot }.controlSize(.small)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The quick buttons pick the most natural scope: the site, the workspace,
    /// the project, or failing those the app.
    private func quick(_ item: ReviewItem, _ outcome: Outcome) {
        let ladder = Suggestions.build(for: item.snapshot)
        let choice = ladder.first { $0.scope == .site }
            ?? ladder.first { $0.scope == .workspace }
            ?? ladder.first { $0.scope == .project }
            ?? ladder.first { $0.scope == .app }
        guard let choice else { return }
        engine.add(choice.rule(outcome: outcome))
    }
}
