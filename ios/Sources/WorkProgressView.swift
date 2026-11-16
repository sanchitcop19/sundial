import SwiftUI
import SundialCore
import UniformTypeIdentifiers

enum MobileTheme {
    static let accent = Color(red: 33 / 255, green: 206 / 255, blue: 153 / 255)
    static let overtime = Color(red: 1, green: 107 / 255, blue: 107 / 255)
    static let motion = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

struct WorkProgressSection: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var activity: LiveActivityController
    @State private var choosingFolder = false

    var body: some View {
        Section {
            if let progress = library.progress {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    progressCard(progress, now: context.date)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Waiting for Mac summary", systemImage: "laptopcomputer")
                        .font(.headline)
                    if let folder = library.folder {
                        Text("Selected folder: \(folder.lastPathComponent)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Choose iCloud Drive → Sundial, or the shared backup folder used by your Mac. "
                         + "Enable Sync work progress to iPhone on your Mac to create its summary.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Choose shared folder…") { choosingFolder = true }
                }
            }
            if let status = library.progressStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Daily work target") }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { library.connect(to: folder) }
        }

        Section {
            if activity.isRunning {
                Button {
                    Task { await activity.stop() }
                } label: {
                    Label("Stop Live Activity", systemImage: "stop.circle")
                }
                .disabled(activity.isBusy)
            } else {
                Button {
                    Task { await activity.start() }
                } label: {
                    Label("Start Live Activity", systemImage: "livephoto")
                }
                .disabled(activity.isBusy)
            }
            if let status = activity.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text(activity.automaticStartStatus)
                .font(.caption).foregroundStyle(.secondary)
            if let recovery = activity.recoveryAction {
                Button(recovery == .restart ? "Restart Live Activity" : "Retry sync") {
                    Task { await activity.recoverConnection() }
                }
                .disabled(activity.isBusy)
            }
        } header: { Text("Lock Screen & Dynamic Island") }
        footer: {
            Text("Open the app to refresh from your shared folder. For updates while your phone is locked, "
                 + "enable Live Activity push on your Mac. Choose weekdays and start/end times there, "
                 + "including an end time after midnight. Sundial renews the activity after 8 hours. "
                 + "Your Mac must be awake and connected; iOS may delay delivery. "
                 + "Stop Live Activity pauses automatic starts for the rest of the scheduled session.")
        }
    }

    private func progressCard(_ progress: WorkProgressSnapshot, now: Date) -> some View {
        let stale = progress.isStale(at: now)
        let zone = TimeZone(identifier: progress.timeZoneIdentifier) ?? .current
        let accent = progress.isOverTarget ? MobileTheme.overtime : MobileTheme.accent
        let balance = progress.isOverTarget
            ? "+\(WorkProgressPresentation.compact(progress.overtime))"
            : WorkProgressPresentation.compact(progress.remaining, roundingUp: true)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                metric("Worked", value: WorkProgressPresentation.compact(progress.worked))
                Spacer(minLength: 0)
                metric(progress.isOverTarget ? "Over target" : "Remaining",
                       value: progress.target > 0 ? balance : "—",
                       color: progress.target > 0 ? accent : .primary)
            }
            ProgressView(value: progress.target > 0 ? min(max(progress.worked, 0), progress.target) : 0,
                         total: max(progress.target, 1))
                .tint(accent)
            HStack {
                Text("Target \(WorkProgressPresentation.compact(progress.target))")
                Spacer()
                if progress.target <= 0 {
                    Text("No target today")
                } else if progress.isOverTarget {
                    Label("Over target", systemImage: "arrow.up.right")
                        .foregroundStyle(accent)
                } else if progress.remaining == 0 {
                    Text("Target reached").foregroundStyle(MobileTheme.accent)
                }
            }
            .font(.caption).monospacedDigit()
            .foregroundStyle(.secondary)

            if let worked = progress.weeklyWorked, let target = progress.weeklyTarget {
                HStack {
                    Text("This week")
                    Spacer()
                    Text("\(WorkProgressPresentation.compact(worked)) / \(WorkProgressPresentation.compact(target))")
                        .monospacedDigit()
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(WorkProgressPresentation.status(progress, stale: stale),
                      systemImage: stale ? "clock.badge.exclamationmark" : "checkmark.icloud")
                Text("Mac day \(progress.day) · \(zone.identifier)")
                Text("Updated \(WorkProgressPresentation.updatedTime(progress))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .animation(MobileTheme.motion, value: progress.remaining == 0)
        .animation(MobileTheme.motion, value: progress.isOverTarget)
    }

    private func metric(_ label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
    }
}
