import SwiftUI
import ServiceManagement
import SundialCore

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var backupMessage: String?

    private var available: [String] { CloudMirror.available() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: "Permissions") {
                    VStack(alignment: .leading, spacing: 8) {
                        permissionRow(
                            granted: !engine.needsAccessibility,
                            title: "Accessibility",
                            detail: "Reads the title of the active window. Without it, browser tabs "
                                  + "and editor projects cannot be told apart.",
                            action: { Signals.requestAccessibility() })
                        if let p = engine.browserProblem {
                            permissionRow(granted: false, title: "Browser access", detail: p,
                                          action: {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                            })
                        }
                    }
                }

                Card(title: "Accuracy") {
                    VStack(alignment: .leading, spacing: 10) {
                        slider("Count as away after",
                               value: Binding(get: { engine.settings.idleThreshold },
                                              set: { engine.settings.idleThreshold = $0 }),
                               range: 30...900, step: 30,
                               help: "Silence this long means nobody is at the machine. This is "
                                   + "what stops an unattended agent or a long build being counted.")
                        slider("Away during a call after",
                               value: Binding(get: { engine.settings.callIdleThreshold },
                                              set: { engine.settings.callIdleThreshold = $0 }),
                               range: 300...7200, step: 300,
                               help: "While the microphone or camera is in use you are treated as "
                                   + "present, because sitting still in a meeting is still working.")
                        slider("Menu bar beat",
                               value: Binding(get: { engine.settings.beatPeriod },
                                              set: { engine.settings.beatPeriod = $0 }),
                               range: 0.4...2, step: 0.05,
                               format: { String(format: "%.2gs", $0) },
                               help: "How long one pulse of the dot takes while work is being "
                                   + "counted. The dot is drawn as a layer rather than as text, "
                                   + "so a smooth fade here costs about 1% of a core.")
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, on in
                                try? on ? SMAppService.mainApp.register()
                                        : SMAppService.mainApp.unregister()
                            }
                    }
                }

                Card(title: "Breaks") {
                    VStack(alignment: .leading, spacing: 10) {
                        if engine.notificationsRefused {
                            permissionRow(
                                granted: false,
                                title: "Notifications",
                                detail: "Turned off for Sundial, so break reminders appear as a "
                                      + "small panel instead. The menu bar marks a break as owed "
                                      + "either way.",
                                action: {
                                    NSWorkspace.shared.open(URL(string:
                                        "x-apple.systempreferences:com.apple.preference.notifications")!)
                                })
                        }
                        Toggle("Remind me to take a break", isOn: Binding(
                            get: { engine.settings.breakReminders },
                            set: { engine.settings.breakReminders = $0 }))
                        if engine.settings.breakReminders {
                            slider("After this much work",
                                   value: Binding(get: { engine.settings.workBeforeBreak },
                                                  set: { engine.settings.workBeforeBreak = $0 }),
                                   range: 300...7200, step: 300,
                                   help: "Counted as work, not as time at the desk. Idle time, "
                                       + "personal time and meetings do not add to it, so this is "
                                       + "a real hour of work rather than an hour on the clock.")
                            slider("A break means being away for",
                                   value: Binding(get: { engine.settings.breakLength },
                                                  set: { engine.settings.breakLength = $0 }),
                                   range: 60...1800, step: 60,
                                   help: "Step away for this long and the count starts again. "
                                       + "After a break is due, Sundial also notifies you when "
                                       + "your break is over. Brief work-app glances (up to "
                                       + "15 seconds total) pause the break timer instead of "
                                       + "starting it over.")
                            Text(engine.breakStatus.owed
                                 ? "Break due after \(Format.duration(engine.breakStatus.workedStraight)) of work."
                                 : "\(Format.duration(engine.breakStatus.toGo)) of work to go.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                Card(title: "Backup") {
                    VStack(alignment: .leading, spacing: 8) {
                        if available.isEmpty {
                            Text("No cloud folder found on this Mac.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(available, id: \.self) { token in
                            Toggle(CloudMirror.label(token), isOn: Binding(
                                get: { engine.settings.backupTo.contains(token) },
                                set: { on in
                                    var list = engine.settings.backupTo
                                    if on { if !list.contains(token) { list.append(token) } }
                                    else { list.removeAll { $0 == token } }
                                    engine.settings.backupTo = list
                                }))
                        }
                        Toggle("Include the raw record, not just daily totals", isOn: Binding(
                            get: { engine.settings.backupObservations },
                            set: { engine.settings.backupObservations = $0 }))
                        HStack {
                            Button("Back up now") {
                                let r = engine.backupNow()
                                backupMessage = r.destinations.isEmpty
                                    ? (r.errors.first ?? "Nothing configured")
                                    : "Copied to \(r.destinations.count) place\(r.destinations.count == 1 ? "" : "s")"
                            }.controlSize(.small)
                            Button("Reveal data folder") {
                                NSWorkspace.shared.selectFile(
                                    engine.store.dailyCSVURL.path,
                                    inFileViewerRootedAtPath: engine.store.root.path)
                            }.controlSize(.small)
                            if let m = backupMessage {
                                Text(m).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(engine.backupErrors, id: \.self) { e in
                            Text("⚠︎ \(e)").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                }

                Card(title: "Data") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What was on screen is recorded; what it means is worked out from the "
                             + "rules every time. That is why changing a rule also fixes the past.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(engine.store.root.path)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        Button("Recalculate every day from the raw record") {
                            engine.rebuildAllDays()
                        }.controlSize(.small)
                    }
                }
            }
            .padding(16)
        .background(Theme.canvas)
        }
    }

    private func permissionRow(granted: Bool, title: String, detail: String,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Fix", action: action).controlSize(.small) }
        }
    }

    private func slider(_ label: String, value: Binding<TimeInterval>,
                        range: ClosedRange<Double>, step: Double,
                        format: (TimeInterval) -> String = { Format.duration($0) },
                        help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            Text(help).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
