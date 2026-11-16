import ActivityKit
import SwiftUI
import WidgetKit
import SundialCore

@main
struct SundialWidgets: WidgetBundle {
    var body: some Widget { activity }

    private var activity: some Widget {
        // WidgetBundleBuilder has no if/else branch; erase both availability paths.
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildOptional(
                WidgetBundleBuilder.buildLimitedAvailability(WorkLiveActivity()))
        } else {
            return WidgetBundleBuilder.buildOptional(
                WidgetBundleBuilder.buildLimitedAvailability(LegacyWorkLiveActivity()))
        }
    }
}

private enum ActivityPalette {
    static let background = Color(red: 17 / 255, green: 19 / 255, blue: 23 / 255)
    static let text = Color.white.opacity(0.96)
    static let secondary = Color(white: 0.68)
    static let mint = Color(red: 33 / 255, green: 206 / 255, blue: 153 / 255)
    static let quietMint = Color(red: 123 / 255, green: 184 / 255, blue: 166 / 255)
    static let overtime = Color(red: 1, green: 107 / 255, blue: 107 / 255)
    static let breakAccent = Color(red: 242 / 255, green: 190 / 255, blue: 100 / 255)
    static let breakBackground = Color(red: 34 / 255, green: 29 / 255, blue: 23 / 255)

    static func accent(for snapshot: WorkProgressSnapshot, isStale: Bool) -> Color {
        if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) { return breakAccent }
        return snapshot.isOverTarget ? overtime : mint
    }
}

@available(iOS 18.0, *)
struct WorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        LegacyWorkLiveActivity().body.supplementalActivityFamilies([.small, .medium])
    }
}

struct LegacyWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkActivityAttributes.self) { context in
            Group {
                if #available(iOS 18.0, *) {
                    AdaptiveWorkActivityContent(snapshot: context.state, isStale: context.isStale)
                } else {
                    WorkActivityCard(snapshot: context.state, isStale: context.isStale)
                }
            }
            .activityBackgroundTint(WorkProgressPresentation.showsActiveBreak(context.state, stale: context.isStale)
                ? ActivityPalette.breakBackground : ActivityPalette.background)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "sundial://progress"))
            .environment(\.colorScheme, .dark)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if WorkProgressPresentation.showsActiveBreak(context.state, stale: context.isStale) {
                        WorkActivityBreakMetric(snapshot: context.state)
                    } else {
                        WorkActivityMetric(title: "Worked", seconds: context.state.worked)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkActivityBalance(snapshot: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    WorkActivityStateIcon(snapshot: context.state, isStale: context.isStale)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if WorkProgressPresentation.showsActiveBreak(context.state, stale: context.isStale) {
                            Text("\(WorkProgressPresentation.compact(context.state.worked)) worked today")
                                .font(.caption2).foregroundStyle(ActivityPalette.secondary)
                        }
                        WorkProgressPill(snapshot: context.state, isStale: context.isStale)
                    }
                }
            } compactLeading: {
                remainingIcon(context.state, isStale: context.isStale)
                    .font(.caption2.weight(.semibold))
            } compactTrailing: {
                remaining(context.state, isStale: context.isStale)
            } minimal: {
                HStack(spacing: 2) {
                    remainingIcon(context.state, isStale: context.isStale)
                        .font(.system(size: 8, weight: .semibold))
                    remaining(context.state, isStale: context.isStale, minimal: true)
                }
            }
            .widgetURL(URL(string: "sundial://progress"))
            .keylineTint(WorkProgressPresentation.showsActiveBreak(context.state, stale: context.isStale)
                ? ActivityPalette.breakAccent.opacity(0.6)
                : context.state.isOverTarget ? ActivityPalette.overtime.opacity(0.6) : .white.opacity(0.2))
        }
    }

    private func remaining(_ snapshot: WorkProgressSnapshot, isStale: Bool,
                           minimal: Bool = false) -> some View {
        Group {
            if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) {
                WorkActivityBreakCountdown(snapshot: snapshot)
                    .frame(width: minimal ? 30 : 40)
                    .foregroundStyle(ActivityPalette.breakAccent)
            } else {
                Text(balanceText(snapshot))
                    .foregroundStyle(snapshot.target > 0 ? ActivityPalette.accent(for: snapshot, isStale: isStale) : ActivityPalette.secondary)
                    .accessibilityLabel(balanceAccessibilityLabel(snapshot))
            }
        }
            .font(.system(size: minimal ? 10 : 12, weight: .medium).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityHint(activityStatus(snapshot, isStale: isStale))
    }

    @ViewBuilder
    private func remainingIcon(_ snapshot: WorkProgressSnapshot, isStale: Bool) -> some View {
        if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) {
            Image(systemName: "cup.and.saucer.fill")
                .foregroundStyle(ActivityPalette.breakAccent)
                .accessibilityHidden(true)
        } else if snapshot.target > 0 {
            Image(systemName: isStale ? "clock" : snapshot.isPaused ? "pause.fill"
                  : snapshot.isOverTarget ? "arrow.up" : snapshot.remaining == 0 ? "checkmark" : "hourglass")
                .foregroundStyle(isStale || snapshot.isPaused
                    ? ActivityPalette.secondary : ActivityPalette.accent(for: snapshot, isStale: isStale))
                .accessibilityHidden(true)
        }
    }
}

private func balanceText(_ snapshot: WorkProgressSnapshot) -> String {
    if snapshot.target <= 0 { return "—" }
    if snapshot.isOverTarget { return "+" + WorkProgressPresentation.compact(snapshot.overtime) }
    return WorkProgressPresentation.compact(snapshot.remaining, roundingUp: true)
}

private func balanceAccessibilityLabel(_ snapshot: WorkProgressSnapshot) -> String {
    if snapshot.target <= 0 { return "No daily target" }
    if snapshot.isOverTarget { return "Extra time worked: \(Format.duration(snapshot.overtime))" }
    return "Remaining \(Format.duration(snapshot.remaining))"
}

private func activityStatus(_ snapshot: WorkProgressSnapshot, isStale: Bool) -> String {
    if isStale || snapshot.isPaused || WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) {
        return WorkProgressPresentation.status(snapshot, stale: isStale)
    }
    if snapshot.target <= 0 { return "No target today" }
    if snapshot.isOverTarget { return "Daily target reached · extra time" }
    if snapshot.remaining == 0 { return "Target reached" }
    return WorkProgressPresentation.status(snapshot, stale: false)
}

private struct WorkActivityStateIcon: View {
    let snapshot: WorkProgressSnapshot
    let isStale: Bool

    private var symbol: String {
        if isStale { return "wifi.exclamationmark" }
        if snapshot.isPaused { return "pause.fill" }
        if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) { return "cup.and.saucer.fill" }
        switch snapshot.state {
        case "work": return "laptopcomputer"
        case "away": return "figure.walk"
        case "personal": return "person.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale)
                ? ActivityPalette.breakAccent : !isStale && !snapshot.isPaused && snapshot.state == "work"
                    ? ActivityPalette.accent(for: snapshot, isStale: isStale) : ActivityPalette.secondary)
            .accessibilityLabel(WorkProgressPresentation.status(snapshot, stale: isStale))
    }
}

private struct WorkActivityCard: View {
    let snapshot: WorkProgressSnapshot
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Sundial", systemImage: "sun.max.fill")
                    .font(.caption.weight(.semibold))
                if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) {
                    Text("· \(WorkProgressPresentation.compact(snapshot.worked)) worked")
                        .font(.caption)
                }
                Spacer()
                WorkActivityStateIcon(snapshot: snapshot, isStale: isStale)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(ActivityPalette.secondary)
            HStack(alignment: .firstTextBaseline) {
                if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) {
                    WorkActivityBreakMetric(snapshot: snapshot)
                } else {
                    WorkActivityMetric(title: "Worked", seconds: snapshot.worked)
                }
                Spacer()
                WorkActivityBalance(snapshot: snapshot, isStale: isStale)
            }
            WorkProgressPill(snapshot: snapshot, isStale: isStale)
        }
        .padding(16)
    }
}

private struct WorkActivityBreakMetric: View {
    let snapshot: WorkProgressSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.breakPausedRemaining != nil ? "Break paused" : "On a break")
                .font(.caption).foregroundStyle(ActivityPalette.breakAccent)
            WorkActivityBreakCountdown(snapshot: snapshot)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(ActivityPalette.breakAccent)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

private struct WorkActivityBreakCountdown: View {
    let snapshot: WorkProgressSnapshot

    var body: some View {
        Group {
            if let deadline = snapshot.breakEndsAt {
                let start = Date(timeIntervalSince1970: snapshot.updatedAt)
                let end = Date(timeIntervalSince1970: max(snapshot.updatedAt, deadline))
                Text(timerInterval: start...end, countsDown: true, showsHours: false)
            } else {
                let seconds = Int(ceil(snapshot.breakRemaining() ?? 0))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.leading)
        .accessibilityHint("Break time remaining")
    }
}

private struct WorkActivityMetric: View {
    let title: String
    let seconds: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(ActivityPalette.secondary)
            Text(WorkProgressPresentation.compact(seconds))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(ActivityPalette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

private struct WorkActivityBalance: View {
    let snapshot: WorkProgressSnapshot
    let isStale: Bool

    private var duringBreak: Bool {
        WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.isOverTarget ? "Extra time" : snapshot.target > 0
                ? (duringBreak ? "Work remaining" : "Remaining") : "No target")
                .font(.caption)
                .foregroundStyle(snapshot.isOverTarget
                    ? ActivityPalette.accent(for: snapshot, isStale: isStale) : ActivityPalette.secondary)
            Text(balanceText(snapshot))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(snapshot.target > 0
                    ? ActivityPalette.accent(for: snapshot, isStale: isStale) : ActivityPalette.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(balanceAccessibilityLabel(snapshot))
    }
}

@available(iOS 18.0, *)
private struct AdaptiveWorkActivityContent: View {
    let snapshot: WorkProgressSnapshot
    let isStale: Bool
    @SwiftUI.Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            WatchWorkActivityCard(snapshot: snapshot, isStale: isStale)
        case .medium:
            WorkActivityCard(snapshot: snapshot, isStale: isStale)
        @unknown default:
            WorkActivityCard(snapshot: snapshot, isStale: isStale)
        }
    }
}

private struct WatchWorkActivityCard: View {
    let snapshot: WorkProgressSnapshot
    let isStale: Bool
    @SwiftUI.Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(ActivityPalette.accent(for: snapshot, isStale: isStale))
                Text("Sundial").fontWeight(.semibold)
                Spacer(minLength: 2)
                WorkActivityStateIcon(snapshot: snapshot, isStale: isStale)
            }
            .font(.system(size: 10)).foregroundStyle(ActivityPalette.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) {
                    WorkActivityBreakMetric(snapshot: snapshot)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.isOverTarget ? "Extra time" : snapshot.target > 0 ? "Remaining" : "No target")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(snapshot.isOverTarget ? ActivityPalette.overtime : ActivityPalette.secondary)
                        Text(balanceText(snapshot))
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(snapshot.target > 0
                                ? ActivityPalette.accent(for: snapshot, isStale: isStale) : ActivityPalette.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(balanceAccessibilityLabel(snapshot))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Worked").font(.system(size: 11))
                        .foregroundStyle(ActivityPalette.secondary)
                    Text(WorkProgressPresentation.compact(snapshot.worked))
                        .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(ActivityPalette.text)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Worked \(Format.duration(snapshot.worked))")
            }
            WorkProgressPill(snapshot: snapshot, isStale: isStale, markerSize: 14)
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .padding(12)
        .opacity(isLuminanceReduced ? 0.75 : 1)
        .accessibilityHint(activityStatus(snapshot, isStale: isStale))
    }
}

private struct WorkProgressPill: View {
    let snapshot: WorkProgressSnapshot
    let isStale: Bool
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let motion = Animation.spring(response: 0.32, dampingFraction: 0.86)
    var markerSize: CGFloat = 18

    private var fraction: Double {
        guard snapshot.target.isFinite, snapshot.target > 0, snapshot.worked.isFinite else { return 0 }
        return min(1, max(0, snapshot.worked / snapshot.target))
    }

    private var progressColor: Color {
        if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) { return ActivityPalette.breakAccent }
        if snapshot.isOverTarget { return ActivityPalette.overtime }
        return isStale || snapshot.isPaused ? ActivityPalette.quietMint : ActivityPalette.mint
    }

    private var marker: String {
        if isStale { return "clock" }
        if snapshot.isPaused { return "pause.fill" }
        if WorkProgressPresentation.showsActiveBreak(snapshot, stale: isStale) { return "cup.and.saucer.fill" }
        if snapshot.isOverTarget { return "arrow.up" }
        return fraction == 1 ? "checkmark" : "sun.max.fill"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                    .frame(height: 8)
                Capsule().fill(progressColor)
                    .frame(width: max(0, geometry.size.width * fraction), height: 8)
                if snapshot.target > 0 {
                    Circle().fill(progressColor)
                        .overlay {
                            Image(systemName: marker)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(red: 0.04, green: 0.07, blue: 0.06))
                        }
                        .overlay { Circle().stroke(.black.opacity(0.35), lineWidth: 1) }
                        .frame(width: markerSize, height: markerSize)
                        .offset(x: max(0, geometry.size.width - markerSize) * fraction)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? nil : Self.motion, value: fraction)
        }
        .frame(height: markerSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily work progress")
        .accessibilityValue(snapshot.target > 0
            ? "\(Int(fraction * 100)) percent. \(Format.duration(snapshot.worked)) worked of \(Format.duration(snapshot.target)) target."
            : "No target today. \(Format.duration(snapshot.worked)) worked.")
        .accessibilityHint(isStale ? "Last confirmed totals; update delayed."
                           : snapshot.isPaused ? "Tracking is paused." : "")
    }
}
