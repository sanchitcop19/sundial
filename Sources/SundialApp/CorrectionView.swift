import SwiftUI
import SundialCore

/// The correction sheet: say what this really is, choose how widely it should
/// apply, and see what that does to time already recorded before committing.
///
/// Choosing the breadth is the hard part of writing a rule, so the ladder of
/// scopes is drafted for the user and every option is priced in advance.
struct CorrectionView: View {
    @EnvironmentObject var engine: Engine
    let snapshot: Snapshot
    /// What the segment is currently counted as, if anything.
    var currentState: TimeCategory?
    var onDone: () -> Void

    @State private var outcome: Outcome = .work
    @State private var selected: Suggestion?
    @State private var impact: Impact?
    @State private var computing = false

    private var suggestions: [Suggestion] { Suggestions.build(for: snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            outcomePicker
            scopeList
            impactBox
            Divider()
            buttons
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            // Default to the opposite of the current verdict: corrections exist
            // because something was wrong.
            outcome = currentState == .work ? .personal : .work
            selected = suggestions.first { $0.scope == .site }
                ?? suggestions.first { $0.scope == .workspace }
                ?? suggestions.first { $0.scope == .project }
                ?? suggestions.first
            recompute()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Correct this time").font(.system(size: 15, weight: .semibold))
            Text(snapshot.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            if let u = snapshot.url {
                Text(u).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private var outcomePicker: some View {
        HStack(spacing: 10) {
            Text("This is").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $outcome) {
                ForEach(Outcome.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            .onChange(of: outcome) { _, _ in recompute() }
        }
    }

    private var scopeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apply to").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(suggestions) { s in
                        Button {
                            selected = s
                            recompute()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: selected?.id == s.id
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected?.id == s.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title).font(.system(size: 12, weight: .medium))
                                    Text(s.detail).font(.system(size: 10))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    if let caution = s.caution {
                                        Label(caution, systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.unclassified)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 2)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 190)
        }
    }

    @ViewBuilder private var impactBox: some View {
        if let impact {
            let heavy = impact.reclassifiedFromDecided > 60
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: heavy ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    .foregroundStyle(heavy ? Color.orange : Color.secondary)
                Text(impact.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        } else if computing {
            ProgressView().controlSize(.small)
        }
    }

    private var buttons: some View {
        HStack {
            if let s = selected {
                Text("Rule: \(s.title)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
            Button("Add rule") {
                if let s = selected { engine.add(s.rule(outcome: outcome)) }
                onDone()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
    }

    private func recompute() {
        guard let s = selected else { impact = nil; return }
        computing = true
        let rule = s.rule(outcome: outcome)
        impact = engine.impact(ofAdding: rule)
        computing = false
    }
}
