import AppKit
import SwiftUI
import ServiceManagement
import SundialCore
import UserNotifications

// MARK: - Command line

let args = CommandLine.arguments

if args.count > 1, args[1] == "--report" || args[1] == "--daily" {
    let store = Store()
    let rules = store.loadRules() ?? RuleSet()
    let settings = store.loadSettings()
    if args[1] == "--daily" {
        let rows = store.loadDaily()
        print("date        work      personal  away      unclassified")
        for r in rows {
            func c(_ v: TimeInterval) -> String {
                Format.duration(v).padding(toLength: 10, withPad: " ", startingAt: 0)
            }
            print("\(r.date)  \(c(r.work))\(c(r.personal))\(c(r.away))\(c(r.unclassified))")
        }
        print("\nTotal work over \(rows.count) day(s): "
              + Format.duration(rows.reduce(0) { $0 + $1.work }))
        print("CSV: \(store.dailyCSVURL.path)")
    } else {
        let day = args.count > 2 ? args[2] : Format.day(Date())
        let segs = store.segments(for: day, rules: rules, settings: settings)
        let t = Totals.compute(segs)
        print("Sundial — \(day)")
        for c in TimeCategory.allCases {
            print("  \(c.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + Format.duration(t.byState[c] ?? 0))
        }
        let review = ReviewItem.build(from: segs)
        let actionable = review.filter(\.isActionable)
        if !actionable.isEmpty {
            print("\nNeeds a rule")
            for r in actionable.prefix(10) {
                print("  \(Format.duration(r.seconds).padding(toLength: 9, withPad: " ", startingAt: 0))"
                      + r.snapshot.summary)
            }
        }
        let blind = review.filter { !$0.isActionable }
        if !blind.isEmpty {
            let total = blind.reduce(0) { $0 + $1.seconds }
            print("\nCannot be classified (\(Format.duration(total)))")
            print("  Recorded before Accessibility was granted; only the app name was visible.")
            for r in blind.prefix(5) {
                print("  \(Format.duration(r.seconds).padding(toLength: 9, withPad: " ", startingAt: 0))"
                      + r.snapshot.appName)
            }
        }
    }
    exit(0)
}

if args.count > 1, args[1] == "--rebuild" {
    let store = Store()
    let rows = store.rebuildDaily(rules: store.loadRules() ?? RuleSet(),
                                  settings: store.loadSettings())
    print("Recalculated \(rows.count) day(s) from the raw record.")
    exit(0)
}

// One-shot migration from the earlier WorkClock tracker.
if args.count > 1, args[1] == "--import-workclock" {
    let store = Store()
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let source = home.appendingPathComponent(".local/share/workclock")
    let config = home.appendingPathComponent(".config/workclock/config.json")
    guard FileManager.default.fileExists(atPath: source.path) else {
        print("Nothing to import: \(source.path) does not exist.")
        exit(0)
    }
    // Project names are resolved to real folders so imported editor time can be
    // matched by path rules rather than by name alone.
    var index: [String: String] = [:]
    for root in EnvironmentScanner.codeRoots(home: home) {
        index[(root.path as NSString).lastPathComponent] = root.path
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for k in kids where !k.hasPrefix(".") {
                index[k] = (root.path as NSString).appendingPathComponent(k)
            }
        }
    }
    let r = WorkClockImport.run(sourceRoot: source, configURL: config,
                                store: store, projectIndex: index)
    print("Imported \(r.days) day(s), \(r.observations) stretches, "
          + "\(Format.duration(r.imported)) of activity.")
    print("Translated \(r.rules) rule(s) from the old configuration.")
    if r.skippedOverlapping > 0 {
        print("Skipped \(r.skippedOverlapping) stretch(es) already covered by Sundial.")
    }
    let rows = store.rebuildDaily(rules: store.loadRules() ?? RuleSet(),
                                  settings: store.loadSettings())
    print("Recalculated \(rows.count) day(s).")
    exit(0)
}

// Launch at login, without needing the settings window.
if args.count > 1, args[1] == "--login-item" {
    let on = args.count > 2 ? (args[2] == "on") : true
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("Launch at login: \(on ? "enabled" : "disabled")")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Which rule decides a given thing, and what else would have matched.
//   --why app=com.microsoft.VSCode project=~/repos/personal/sundial
//   --why host=github.com profile=Work
if args.count > 1, args[1] == "--why" {
    let store = Store()
    let rules = store.loadRules() ?? RuleSet()
    var f: [String: String] = [:]
    for pair in args.dropFirst(2) {
        let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
        if bits.count == 2 { f[bits[0].lowercased()] = bits[1] }
    }
    guard !f.isEmpty else {
        print("usage: --why app=<bundle id> [project=<path>] [host=<host>] "
              + "[profile=<name>] [workspace=<name>] [title=<text>]")
        exit(2)
    }
    let path = f["project"].map { ($0 as NSString).expandingTildeInPath }
    let snapshot = Snapshot(
        bundleId: f["app"] ?? "", appName: f["app"] ?? "?", windowTitle: f["title"],
        host: f["host"], browserProfile: f["profile"], workspace: f["workspace"],
        projectName: path.map { ($0 as NSString).lastPathComponent }, projectPath: path)

    print("Deciding: \(snapshot.summary)")
    let matches = rules.rules.filter { $0.matches(snapshot) }
    if let winner = matches.first(where: \.enabled) {
        print("  → \(winner.outcome.label.uppercased())  by “\(winner.name)”")
        print("    \(winner.conditions.map(\.describe).joined(separator: " and "))")
    } else {
        print("  → UNCLASSIFIED. No enabled rule matches, so it goes to Review.")
    }
    let others = matches.dropFirst(matches.first(where: \.enabled) == nil ? 0 : 1)
    if !others.isEmpty {
        print("  Also matched, but lower down:")
        for r in others.prefix(6) {
            print("    \(r.enabled ? " " : "×") \(r.outcome.label.lowercased().padding(toLength: 9, withPad: " ", startingAt: 0))"
                  + "\(r.name)\(r.enabled ? "" : "  (disabled)")")
        }
    }
    exit(0)
}

// Why a break has or has not been suggested. Diagnostics, because "it did not
// prompt me" has several possible causes and guessing between them is no fun.
if args.count > 1, args[1] == "--breaks" {
    let store = Store()
    let rules = store.loadRules() ?? RuleSet()
    let settings = store.loadSettings()
    let day = args.count > 2 ? args[2] : Format.day(Date())
    let segs = store.segments(for: day, rules: rules, settings: settings)
    let reminderState = day == Format.day(Date()) ? store.loadBreakReminderState() : BreakReminderState()
    let status = Breaks.status(segments: reminderState.segmentsSinceSkip(segs), now: Date(),
                              settings: settings, snoozedUntil: reminderState.quietUntil,
                              currentState: segs.last?.state ?? .away)

    print("Breaks on \(day)")
    print("  Reminders        \(settings.breakReminders ? "on" : "off")")
    print("  A break is due   after \(Format.duration(settings.workBeforeBreak)) of work")
    print("  A break means    \(Format.duration(settings.breakLength)) away from work")
    print("  Worked straight  \(Format.duration(status.workedStraight))"
          + (status.owed ? "  — a break is owed" : "  (\(Format.duration(status.toGo)) to go)"))
    if let held = status.heldBack { print("  Held back        \(held)") }

    // The longest run the day ever managed, which is the number that says
    // whether the threshold is reachable at all.
    var best: TimeInterval = 0, run: TimeInterval = 0, gap: TimeInterval = 0
    var brokenBy: [TimeInterval] = []
    for seg in segs {
        if seg.state == .work { run += seg.duration; gap = 0 }
        else {
            gap += seg.duration
            if gap >= settings.breakLength {
                if run > 0 { brokenBy.append(run) }
                best = max(best, run); run = 0
            }
        }
    }
    best = max(best, run)
    print("  Longest run      \(Format.duration(best)) of work without a "
          + "\(Format.duration(settings.breakLength)) break")
    if !brokenBy.isEmpty {
        let runs = brokenBy.sorted(by: >).prefix(5).map(Format.duration).joined(separator: ", ")
        print("  Runs today       \(runs)")
    }

    let sem = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { s in
        let word: String
        switch s.authorizationStatus {
        case .authorized:    word = "allowed"
        case .denied:        word = "REFUSED — nothing can be delivered"
        case .notDetermined: word = "never asked yet"
        case .provisional:   word = "provisional"
        default:             word = "\(s.authorizationStatus.rawValue)"
        }
        print("  Notifications    \(word)")
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 3)
    exit(0)
}

// Time the tracker could not see: a meeting away from the desk, a call taken on
// a phone, a day on someone else's machine.
//   --add-time "2026-09-02 14:00" 90m [work|personal|away] ["note"]
//   --added [day]        --remove-time <id> [day]
if args.count > 1, args[1] == "--add-time" || args[1] == "--added"
    || args[1] == "--remove-time" {
    let store = Store()
    let rules = store.loadRules() ?? RuleSet()
    let settings = store.loadSettings()

    /// Accepts "2026-09-02 14:00", "14:00" for today, or "yesterday 09:30".
    func parseStart(_ text: String) -> Date? {
        let f = DateFormatter()
        f.calendar = .current; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        var text = text.trimmingCharacters(in: .whitespaces)
        var base = Date()
        if text.lowercased().hasPrefix("yesterday") {
            base = Calendar.current.date(byAdding: .day, value: -1, to: base) ?? base
            text = String(text.dropFirst("yesterday".count)).trimmingCharacters(in: .whitespaces)
        }
        if text.contains(" ") || text.contains("-") {
            for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                f.dateFormat = format
                if let d = f.date(from: text) { return d }
            }
            return nil
        }
        f.dateFormat = "HH:mm"
        guard let clock = f.date(from: text) else { return nil }
        let hm = Calendar.current.dateComponents([.hour, .minute], from: clock)
        return Calendar.current.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0,
                                     second: 0, of: base)
    }

    /// "90m", "1h30m", "2h", "45" (minutes).
    func parseLength(_ text: String) -> TimeInterval? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let plain = Double(t) { return plain * 60 }
        var total: Double = 0, number = ""
        var sawUnit = false
        for ch in t {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let value = Double(number) else { return nil }
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            default: return nil
            }
            sawUnit = true
            number = ""
        }
        if let trailing = Double(number), !trailing.isZero { total += trailing * 60 }
        return sawUnit ? total : nil
    }

    if args[1] == "--added" {
        let day = args.count > 2 ? args[2] : Format.day(Date())
        let entries = store.loadManual(day: day)
        if entries.isEmpty { print("Nothing added by hand on \(day).") }
        for e in entries {
            print("\(e.id.uuidString.prefix(8))  \(Format.clock(e.start))–\(Format.clock(e.end))"
                  + "  \(Format.duration(e.duration).padding(toLength: 8, withPad: " ", startingAt: 0))"
                  + "  \(e.category.label)\(e.note.isEmpty ? "" : "  \(e.note)")")
        }
        exit(0)
    }

    if args[1] == "--remove-time" {
        guard args.count > 2 else { print("usage: --remove-time <id> [day]"); exit(2) }
        let day = args.count > 3 ? args[3] : Format.day(Date())
        let prefix = args[2].lowercased()
        let entries = store.loadManual(day: day)
        let keep = entries.filter { !$0.id.uuidString.lowercased().hasPrefix(prefix) }
        if keep.count == entries.count { print("No entry starting \(prefix) on \(day)."); exit(1) }
        store.saveManual(keep, day: day)
        store.rebuildDaily(rules: rules, settings: settings)
        print("Removed \(entries.count - keep.count) entr\(entries.count - keep.count == 1 ? "y" : "ies").")
        exit(0)
    }

    guard args.count > 3, let start = parseStart(args[2]), let length = parseLength(args[3]) else {
        print("usage: --add-time \"2026-09-02 14:00\" 90m [work|personal|away] [\"note\"]")
        exit(2)
    }
    let category = TimeCategory(rawValue: args.count > 4 ? args[4].lowercased() : "work") ?? .work
    let note = args.count > 5 ? args[5] : ""
    let entry = ManualEntry(start: start, end: start.addingTimeInterval(length),
                            category: category, note: note)
    if let problem = Manual.problem(with: entry, existing: []) { print(problem); exit(1) }

    for (day, piece) in Manual.split(entry) {
        var onThatDay = store.loadManual(day: day)
        if let problem = Manual.problem(with: piece, existing: onThatDay) {
            print("\(day): \(problem)"); exit(1)
        }
        onThatDay.append(piece)
        store.saveManual(onThatDay, day: day)
        print("Added \(Format.duration(piece.duration)) of \(piece.category.label.lowercased())"
              + " on \(day), \(Format.clock(piece.start))–\(Format.clock(piece.end)).")
    }
    store.rebuildDaily(rules: rules, settings: settings)
    exit(0)
}

if args.count > 1, args[1] == "--stats" {
    guard args.count <= 3,
          let period = StatsPeriod(rawValue: args.count > 2 ? args[2].lowercased() : "week") else {
        FileHandle.standardError.write(Data(
            ("usage: Sundial --stats [week|month|quarter|year]\n"
             + "Statistics use the current calendar period; rolling day counts are not supported.\n").utf8))
        exit(2)
    }
    let store = Store()
    let now = Date()
    let calendar = StatsPeriod.calendar
    let interval = period.interval(containing: now, calendar: calendar)
    let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
    let s = store.stats(period: period, rules: store.loadRules() ?? RuleSet(),
                        settings: store.loadSettings(), calendar: calendar, now: now)
    print("Sundial — \(period.title) (\(Format.day(interval.start))–\(Format.day(lastDay)))")
    print("Through \(Format.day(now)) · \(s.days.count) recorded day(s)\n")
    guard !s.days.isEmpty else { print("No history in this calendar period."); exit(0) }

    func hourLabel(_ h: Int) -> String {
        h == 0 ? "12a" : (h == 12 ? "12p" : (h < 12 ? "\(h)a" : "\(h - 12)p"))
    }
    if period != .week {
        let weekly = s.weeklyWorkStats(period: period, now: now, calendar: calendar)
        if let average = weekly.averageWork {
            print("  Average week      \(Format.duration(average))"
                  + "  over \(weekly.completedWeeks) complete calendar week(s), current week excluded")
        } else {
            print("  Average week      —  (no complete weeks with records yet)")
        }
    }
    print("  Total work        \(Format.duration(s.totalWork))")
    if s.completedActiveDays.isEmpty {
        print("  Average day       —  (no complete day in this period yet)")
    } else {
        print("  Average day       \(Format.duration(s.averageWorkPerActiveDay))"
              + "  over \(s.completedActiveDays.count) complete day(s), today excluded")
    }
    print("  Longest focus     \(Format.duration(s.longestFocus))")
    if s.totalCallSeconds > 60 { print("  In calls          \(Format.duration(s.totalCallSeconds))") }
    if s.weekendWork > 60 { print("  Weekend work      \(Format.duration(s.weekendWork))") }
    if s.totalUnclassified > 60 {
        print("  Unclassified      \(Format.duration(s.totalUnclassified))")
    }
    if let core = s.coreHours {
        print("  Core hours        \(hourLabel(core.lowerBound))–\(hourLabel(core.upperBound + 1))"
              + "   outside: \(Format.duration(s.workOutside(core)))")
    }

    let byHour = s.workByHour
    let peak = max(1, byHour.max() ?? 1)
    print("\nWork by hour of day")
    for h in 0..<24 where byHour[h] > 0 {
        let bar = String(repeating: "█", count: max(1, Int((byHour[h] / peak) * 34)))
        print("  \(hourLabel(h).padding(toLength: 4, withPad: " ", startingAt: 0))"
              + "\(bar) \(Format.duration(byHour[h]))")
    }

    // Row prefix is "  yyyy-MM-dd" + weekend marker + an 8-wide total, so the
    // hour labels are indented to match the cells exactly.
    let rowPrefix = 2 + 10 + 1 + 1 + 8
    print("\nHour by hour" + String(repeating: " ", count: rowPrefix - 12)
          + (0..<24).map { $0 % 6 == 0 ? String(hourLabel($0).prefix(2)) : "  " }.joined())
    for d in s.days {
        let cells = d.workByHour.map { seconds -> String in
            switch seconds {
            case 0: return "·"
            case ..<600: return "░"
            case ..<1800: return "▒"
            case ..<3000: return "▓"
            default: return "█"
            }
        }.joined(separator: " ")
        let total = Format.duration(d.totals.work).padding(toLength: 8, withPad: " ", startingAt: 0)
        let marker = d.day == s.today ? "~" : (d.isWeekend ? "*" : " ")
        print("  \(d.day)\(marker) \(total)\(cells)")
    }

    if !s.contexts.isEmpty {
        print("\nWhere the work went")
        for c in s.contexts.prefix(10) {
            print("  \(Format.duration(c.seconds).padding(toLength: 9, withPad: " ", startingAt: 0))"
                  + c.detail)
        }
    }
    exit(0)
}

// MARK: - App

@MainActor var retainedDelegate: AppDelegate?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: Engine!
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Before the lock, which would otherwise create the folder itself and
        // leave a record written under the old name stranded beside it.
        Store.migrateLegacyRootIfNeeded()

        // One writer only: two trackers would both append observations.
        guard SingleInstance.acquire(at: Store.defaultRoot.appendingPathComponent("tracker.lock")) else {
            FileHandle.standardError.write(Data("Sundial is already running.\n".utf8))
            NSApp.terminate(nil)
            return
        }

        engine = Engine()
        menuBar = MenuBarController(engine: engine)
        // Tracking starts before the permission prompt, which can sit unanswered
        // for a long time; presence tracking is still correct meanwhile.
        engine.start()

        if !Signals.accessibilityGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Signals.requestAccessibility() }
        }
        if !engine.isSetUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.menuBar.open() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { engine?.shutdown() }

    /// Closing the window leaves the tracker running in the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar.open()
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.run()
}
