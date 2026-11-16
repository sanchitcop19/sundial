import SwiftUI
import UniformTypeIdentifiers
import SundialCore

struct PhoneSyncSettingsView: View {
    @ObservedObject var sync: PhoneSync
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var error: String?

    var body: some View {
        Card(title: "iPhone Live Activity") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sync work progress to iPhone", isOn: $sync.enabled)
                Text("On iPhone, choose iCloud Drive → Sundial. This Mac shares hours and targets "
                     + "there about every minute while totals change, or every three minutes when unchanged; "
                     + "the phone summary contains no app names or window titles. "
                     + "If iCloud Drive is unavailable on this Mac, select a shared backup folder "
                     + "below and open that folder on iPhone.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if sync.enabled {
                    if #available(macOS 26, *) {
                        Toggle("Use Live Activity in menu bar when active", isOn: $sync.preferLiveActivity)
                        Text("Shows a small progress ring while your iPhone reports an active Live Activity. "
                             + "The ring stays available if mirroring disappears; click it for your hours and controls.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(sync.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    if sync.hasPushKey {
                        Button(sync.isRestartingLiveActivity ? "Restoring Live Activity…" : "Restore Live Activity now") {
                            sync.restartLiveActivity()
                        }
                        .controlSize(.small)
                        .disabled(sync.isRestartingLiveActivity)
                    }
                    Toggle("Start and renew automatically each day", isOn: $sync.dailySchedule.enabled)
                    if sync.dailySchedule.enabled {
                        Picker("Repeat", selection: $sync.dailySchedule.days) {
                            Text("Every day").tag(LiveActivitySchedule.Days.everyDay)
                            Text("Weekdays (Mon–Fri)").tag(LiveActivitySchedule.Days.weekdays)
                        }
                        DatePicker("Start at", selection: clockTime($sync.dailySchedule.startMinute),
                                   displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                        Picker("Renew until", selection: $sync.dailySchedule.endRule) {
                            Text("Daily target reached").tag(LiveActivitySchedule.EndRule.targetReached)
                            Text("Midnight").tag(LiveActivitySchedule.EndRule.midnight)
                            Text("A set time").tag(LiveActivitySchedule.EndRule.time)
                        }
                        if sync.dailySchedule.endRule == .time {
                            DatePicker("End at", selection: clockTime($sync.dailySchedule.endMinute),
                                       displayedComponents: .hourAndMinute)
                                .datePickerStyle(.field)
                            if sync.dailySchedule.endMinute == sync.dailySchedule.startMinute {
                                Text("Choose different start and end times.")
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            } else if sync.dailySchedule.endMinute < sync.dailySchedule.startMinute {
                                Text(sync.dailySchedule.days == .weekdays
                                     ? "Ends the following morning. Friday’s activity continues into Saturday."
                                     : "Ends the following morning.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if sync.dailySchedule.endRule == .targetReached {
                            Text("At your target, automatic starts and renewals stop. The current activity "
                                 + "keeps showing any overtime until it expires.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text("Uses this Mac’s local time. Keep the Mac awake and Sundial running, "
                             + "with an Apple push key connected. If the Mac wakes late, it starts then.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Apple limits each activity to 8 hours. Sundial starts a replacement when it expires; "
                             + "each start shows a notification. Totals reset at midnight. "
                             + "Stop on iPhone pauses automatic starts until the scheduled window ends.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(sync.hasPushKey ? "Replace Apple push key" : "Set up updates while iPhone is locked") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Import an Apple APNs authentication key to let this Mac send Live Activity "
                                 + "updates directly through Apple. The key stays in this Mac's Keychain.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            TextField("Key ID", text: $keyID)
                            TextField("Team ID", text: $teamID)
                            Button("Import APNs .p8 key…", action: importKey).controlSize(.small)
                            Text("Without a push key, reopen the iPhone app to refresh its Live Activity. "
                                 + "Cloud-folder delivery and Apple's push scheduling can add delay.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
                        }.padding(.top, 6)
                    }.font(.system(size: 11))
                }
            }
        }
    }

    private func clockTime(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            let calendar = Calendar.current
            return calendar.date(bySettingHour: minutes.wrappedValue / 60,
                minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.message = "Choose the APNs authentication key downloaded from your Apple Developer account."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try sync.configureKey(file: url, keyID: keyID, teamID: teamID)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
