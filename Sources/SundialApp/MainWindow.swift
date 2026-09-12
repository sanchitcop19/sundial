import SwiftUI
import SundialCore

struct MainWindow: View {
    @EnvironmentObject var engine: Engine
    @State private var tab = Tab.today
    @State private var showSetup = false

    enum Tab: String, CaseIterable {
        case today = "Today", stats = "Stats", review = "Review", rules = "Rules", settings = "Settings"
        var icon: String {
            switch self {
            case .today:    return "chart.bar.fill"
            case .stats:    return "chart.xyaxis.line"
            case .review:   return "questionmark.circle.fill"
            case .rules:    return "line.3.horizontal.decrease"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.hairline)
            Group {
                switch tab {
                case .today:    TodayView()
                case .stats:    StatsView()
                case .review:   ReviewView()
                case .rules:    RulesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .frame(minWidth: 720, minHeight: 580)
        .sheet(isPresented: $showSetup) {
            OnboardingView { showSetup = false }.environmentObject(engine)
        }
        .onAppear { if !engine.isSetUp { showSetup = true } }
    }

    /// The live state lives at the top of the sidebar rather than inside a tab,
    /// so it is answered before anything is clicked.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(state.gradient).frame(width: 9, height: 9)
                    Text(engine.isPaused ? "Paused" : state.label)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                Text(Format.duration(engine.totals.work))
                    .font(Theme.figure(27)).monospacedDigit()
                SectionLabel("today")
            }
            .padding(.horizontal, 14).padding(.top, 38).padding(.bottom, 18)

            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    HStack(spacing: 9) {
                        Image(systemName: t.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 15)
                        Text(t.rawValue).font(.system(size: 12.5, weight: .medium))
                        Spacer(minLength: 4)
                        if t == .review, unreviewed > 0 {
                            Text("\(unreviewed)")
                                .font(Theme.figure(10, .bold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Theme.unclassified).foregroundStyle(.black)
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(tab == t ? Theme.surface : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 12)

            if engine.needsAccessibility {
                Label("Accessibility off", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.unclassified)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .frame(width: 168)
        .background(Theme.sidebar)
    }

    private var state: TimeCategory { engine.isPaused ? .away : engine.currentState }
    private var unreviewed: Int { engine.reviewItems.filter(\.isActionable).count }
}
