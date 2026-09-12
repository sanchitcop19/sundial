import AppKit
import Combine
import SundialCore

/// Owns tracking and everything the UI reads.
///
/// Observations are recorded raw; segments are recomputed from them whenever
/// the rules change, so a correction applies to the whole day rather than only
/// to what happens next.
@MainActor
final class Engine: ObservableObject {
    // Recorded
    @Published private(set) var day: String = Format.day(Date())
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var totals = Totals()
    @Published private(set) var reviewItems: [ReviewItem] = []
    @Published private(set) var currentSnapshot: Snapshot?
    @Published private(set) var currentState: TimeCategory = .away
    @Published private(set) var currentReason: String = "Starting up"

    // Configuration
    @Published var rules: RuleSet { didSet { store.save(rules); reclassify(); scheduleRebuild() } }
    @Published var settings: Settings { didSet { store.save(settings); reclassify() } }

    // Status
    @Published private(set) var isPaused = false
    @Published private(set) var needsAccessibility = false
    /// Mic or camera in use. Read by the menu bar, which treats a call as
    /// presence even when nobody is typing.
    @Published private(set) var inCall = false
    /// The system will not deliver notifications. Shown in Settings, because a
    /// reminder that cannot arrive is worth explaining.
    @Published private(set) var notificationsRefused = false
    @Published private(set) var breakStatus = BreakStatus(workedStraight: 0, owed: false,
                                                          due: false, toGo: 0, heldBack: nil)
    @Published private(set) var browserProblem: String?
    @Published private(set) var lastBackup: Date?
    @Published private(set) var backupErrors: [String] = []
    @Published private(set) var isSetUp: Bool

    let store: Store
    let browsers = BrowserReader()
    private var data: DayData
    private var open: ObservationSpan?
    private var timer: Timer?
    private var lastTick: Date?
    private var lastPresenceSave = Date.distantPast
    private var lastBackupAt = Date.distantPast
    private var lastDailyWrite = Date.distantPast
    private var undoStack: [(RuleSet, String)] = []
    private var projectIndex: [String: String] = [:]
    private var lastProjectScan = Date.distantPast
    private var workspaceCache: [pid_t: (String?, Date)] = [:]
    private var rebuildWork: DispatchWorkItem?
    private var followUpWork: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var breakReminderState: BreakReminderState
    private var breakCompletion = BreakCompletionTracker()
    private let reminders = Reminders()
    private let breakPanel = BreakPanel()

    init(store: Store = Store()) {
        self.store = store
        breakReminderState = store.loadBreakReminderState()
        let loaded = store.loadRules()
        let today = Format.day(Date())
        // Every stored property is set before any method runs; `data` in
        // particular must exist before recovery touches it.
        rules = loaded ?? RuleSet()
        settings = store.loadSettings()
        isSetUp = loaded != nil
        day = today
        data = store.load(day: today)

        if let recovered = store.recoverOpen() { data.observations.append(recovered) }
        noteOfflineSinceLastRun()
        reclassify()
    }

    // MARK: - Lifecycle

    func start() {
        needsAccessibility = !Signals.accessibilityGranted
        reminders.onSnooze = { [weak self] in self?.snoozeBreak() }
        reminders.onSkip = { [weak self] in self?.skipBreak() }
        reminders.onBreakDueDelivered = { [weak self] in self?.recordBreakReminder(at: Date()) }
        breakPanel.onSnooze = { [weak self] in self?.snoozeBreak() }
        breakPanel.onSkip = { [weak self] in self?.skipBreak() }
        // A refused notification must not mean a silent feature: the app shows
        // its own panel instead, and Settings explains why.
        reminders.onBlocked = { [weak self] reminder in
            guard let self else { return }
            self.notificationsRefused = self.reminders.refused
            if reminder.canSnooze { self.recordBreakReminder(at: Date()) }
            self.breakPanel.show(reminder)
        }
        reminders.refreshAuthorisation()
        observeActivation()
        timer?.invalidate()
        let t = Timer(timeInterval: settings.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = settings.sampleInterval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Switching app is the moment the answer most often changes, so it is
    /// sampled at once instead of waiting up to a full interval. A second
    /// sample shortly after catches the common "switch app, then switch tab"
    /// sequence without polling faster all day.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isPaused else { return }
                    self.tick()
                    self.followUpWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        Task { @MainActor in
                            guard let self, !self.isPaused else { return }
                            self.tick()
                        }
                    }
                    self.followUpWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
                }
            }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            resetBreakNotifications()
            closeOpenSpan(at: Date())
            flush()
        }
    }

    func shutdown() {
        resetBreakNotifications()
        if let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            activationObserver = nil
        }
        followUpWork?.cancel()
        closeOpenSpan(at: Date())
        store.saveOpen(nil)
        flush()
    }

    /// Time the tracker was not running is recorded, so a gap is never credited
    /// to whatever happened to be on screen when it stopped.
    private func noteOfflineSinceLastRun() {
        let ends = data.observations.map(\.end)
            + data.presence.input.map(\.end) + data.presence.absent.map(\.end)
        guard let last = ends.max() else { return }
        let now = Date()
        if now.timeIntervalSince(last) > settings.maxSampleGap {
            data.presence.offline.append(Span(last, now))
        }
    }

    // MARK: - Sampling

    private func tick() {
        rolloverIfNeeded()
        guard !isPaused else { return }
        let now = Date()

        if let last = lastTick, now.timeIntervalSince(last) > settings.maxSampleGap {
            closeOpenSpan(at: last)
            data.presence.offline.append(Span(last, now))
        }
        let windowStart = lastTick.map { max($0, now.addingTimeInterval(-settings.sampleInterval * 2)) }
            ?? now.addingTimeInterval(-settings.sampleInterval)
        lastTick = now

        // Presence
        let idle = Signals.idleSeconds()
        let lastInput = now.addingTimeInterval(-idle)
        if idle < settings.sampleInterval * 2 {
            data.presence.input.append(Span(lastInput, lastInput))
        }
        if Signals.absent { data.presence.absent.append(Span(windowStart, now)) }
        let call = Signals.inCall
        if call { data.presence.call.append(Span(windowStart, now)) }
        if call != inCall { inCall = call }

        // What is on screen
        let snapshot = observe()
        if let snapshot {
            if var o = open, o.snapshot == snapshot {
                o.end = now
                open = o
            } else {
                closeOpenSpan(at: now)
                open = ObservationSpan(start: now, end: now, snapshot: snapshot)
            }
        } else {
            closeOpenSpan(at: now)
        }
        currentSnapshot = snapshot

        if now.timeIntervalSince(lastPresenceSave) > 20 { flushPresence() }
        store.saveOpen(open)
        reclassify(preservingBreakProgress: true)
        updateBreakReminders(now: now)
        maybeBackup()
    }

    private func closeOpenSpan(at end: Date) {
        guard var o = open else { return }
        o.end = max(o.start, end)
        open = nil
        guard o.duration >= 0.5 else { return }
        data.observations.append(o)
        store.append(o)
    }

    private func flushPresence() {
        lastPresenceSave = Date()
        data.presence.normalise(tolerance: settings.sampleInterval * 1.5)
        store.savePresence(data.presence, day: day)
    }

    private func flush() {
        flushPresence()
        writeDaily()
        store.saveOpen(open)
    }

    private func rolloverIfNeeded() {
        let today = Format.day(Date())
        guard today != day else { return }
        closeOpenSpan(at: Date())
        flush()
        day = today
        data = store.load(day: today)
        reclassify()
    }

    // MARK: - Observation

    private func observe() -> Snapshot? {
        guard let app = Signals.frontmostApp() else { return nil }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? bundleId
        let title = Signals.windowTitle(pid: app.processIdentifier)
        // Without Accessibility the process name is all that can be seen, and
        // that is worth recording as a fact rather than as a mystery.
        let granted = Signals.accessibilityGranted
        if needsAccessibility == granted { needsAccessibility = !granted }
        var snap = Snapshot(bundleId: bundleId, appName: name, windowTitle: title,
                            detailAvailable: granted)

        if BrowserReader.isBrowser(bundleId) {
            if let r = browsers.read(app: app, windowTitle: title) {
                browserProblem = r.problem
                snap.windowTitle = r.title ?? title
                snap.browserProfile = r.profile
                if let u = r.url, let comps = URLComponents(string: u), let host = comps.host {
                    snap.url = u
                    snap.host = host
                    snap.urlPath = comps.path.isEmpty ? "/" : comps.path
                }
            }
        } else if let prefix = Catalogue.workspaceProbes[bundleId] {
            snap.workspace = cachedWorkspace(pid: app.processIdentifier, prefix: prefix)
        }

        if snap.host == nil, let title {
            if let (pname, ppath) = resolveProject(title: title) {
                snap.projectName = pname
                snap.projectPath = ppath
            } else if Catalogue.editors.contains(bundleId) {
                snap.projectName = unresolvedProjectName(title: title)
            }
        }
        return snap
    }

    private func cachedWorkspace(pid: pid_t, prefix: String) -> String? {
        if let c = workspaceCache[pid], Date().timeIntervalSince(c.1) < 10 { return c.0 }
        let v = Signals.labelWithPrefix(pid: pid, prefix: prefix)
        workspaceCache[pid] = (v, Date())
        return v
    }

    /// Editors put the folder name in the title; matching it against known
    /// project folders recovers the real path, which is what rules match on.
    private func resolveProject(title: String) -> (String, String)? {
        if Date().timeIntervalSince(lastProjectScan) > 300 { rescanProjects() }
        let parts = title
            .components(separatedBy: CharacterSet(charactersIn: "\u{2014}\u{2013}"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for candidate in parts.reversed() {
            if let path = projectIndex[candidate] { return (candidate, path) }
        }
        return nil
    }

    /// Editors get the folder name from the title even when it resolves to no
    /// known path, so two projects in the same editor stay distinguishable and
    /// each can be given its own rule.
    private func unresolvedProjectName(title: String) -> String? {
        let parts = title
            .components(separatedBy: CharacterSet(charactersIn: "\u{2014}\u{2013}"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2, let last = parts.last, last.count < 60 else { return nil }
        return last
    }

    private func rescanProjects() {
        lastProjectScan = Date()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var index: [String: String] = [:]
            let fm = FileManager.default
            for root in EnvironmentScanner.codeRoots(home: home, fm: fm) {
                index[(root.path as NSString).lastPathComponent] = root.path
                guard let kids = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
                for k in kids where !k.hasPrefix(".") {
                    let p = (root.path as NSString).appendingPathComponent(k)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                        index[k] = p
                    }
                }
            }
            Task { @MainActor in self?.projectIndex = index }
        }
    }

    // MARK: - Classification

    /// Recomputes every segment for the day from raw observations.
    func reclassify(preservingBreakProgress: Bool = false) {
        if !preservingBreakProgress { resetBreakNotifications() }
        var obs = data.observations
        if let o = open, o.duration > 0 { obs.append(o) }
        let classifier = Classifier(rules: rules, settings: settings)
        segments = Manual.apply(data.manual,
                                to: classifier.classify(observations: obs, presence: data.presence))
        totals = Totals.compute(segments)
        reviewItems = ReviewItem.build(from: segments)
        if let last = segments.last {
            currentState = last.state
            currentReason = last.reason
        }
        breakStatus = Breaks.status(segments: breakReminderState.segmentsSinceSkip(segments),
                                    now: Date(), settings: settings,
                                    snoozedUntil: breakReminderState.quietUntil, inCall: inCall,
                                    currentState: currentState)
    }

    /// Quiet for a while. The break stays owed, so the menu bar keeps saying so.
    func snoozeBreak() {
        breakReminderState.snooze(at: Date())
        store.save(breakReminderState)
        reminders.cancelBreakDue()
        breakPanel.close()
        reclassify(preservingBreakProgress: true)
    }

    func skipBreak() {
        guard breakStatus.owed else { return }
        breakReminderState.skip(at: Date())
        store.save(breakReminderState)
        resetBreakNotifications()
        reclassify(preservingBreakProgress: true)
    }

    private func recordBreakReminder(at now: Date) {
        breakReminderState.recordReminder(at: now)
        store.save(breakReminderState)
        reclassify(preservingBreakProgress: true)
    }

    private func resetBreakNotifications() {
        breakCompletion.reset()
        reminders.cancel()
        breakPanel.close()
    }

    /// Said once when a break falls due, then at most every twenty minutes while
    /// it is still owed: a reminder that repeats every tick is an alarm.
    private func updateBreakReminders(now: Date) {
        let reminderSegments = breakReminderState.segmentsSinceSkip(segments)
        if breakCompletion.update(segments: reminderSegments, now: now, settings: settings, inCall: inCall) {
            breakReminderState.clearSnooze()
            store.save(breakReminderState)
            breakPanel.close()
            reminders.breakOver(length: settings.breakLength)
            return
        }
        if !breakStatus.owed {
            if reminders.cancelBreakDue() { breakPanel.close() }
            return
        }
        guard breakStatus.due else { return }
        // Reserve the interval while permission/delivery is in flight. Actual
        // delivery refreshes it in case the permission prompt took a long time.
        recordBreakReminder(at: now)
        reminders.breakDue(worked: breakStatus.workedStraight)
    }

    // MARK: - Time added by hand

    /// Adds a stretch the tracker could not see. Returns why not, if not.
    ///
    /// An entry spanning midnight is split so each day's file still stands
    /// alone, and every piece is checked before any of them is written: a
    /// half-added entry would be worse than a rejected one.
    func addManual(start: Date, end: Date, category: TimeCategory,
                   note: String = "") -> String? {
        let entry = ManualEntry(start: start, end: end, category: category, note: note)
        if let problem = Manual.problem(with: entry, existing: []) { return problem }

        let pieces = Manual.split(entry)
        guard !pieces.isEmpty else { return "That is not a stretch of time." }
        var existing: [String: [ManualEntry]] = [:]
        for (day, piece) in pieces {
            var onThatDay = existing[day] ?? manualEntries(on: day)
            if let problem = Manual.problem(with: piece, existing: onThatDay) { return problem }
            onThatDay.append(piece)
            existing[day] = onThatDay
        }
        for (day, entries) in existing { write(entries, day: day) }
        return nil
    }

    func removeManual(id: UUID, day: String) {
        write(manualEntries(on: day).filter { $0.id != id }, day: day)
    }

    func manualEntries(on day: String) -> [ManualEntry] {
        day == self.day ? data.manual : store.loadManual(day: day)
    }

    private func write(_ entries: [ManualEntry], day: String) {
        store.saveManual(entries, day: day)
        if day == self.day { data.manual = entries; reclassify() }
        // Any day can be edited, so the rollup for every day is redone.
        scheduleRebuild()
    }

    var currentSegment: Segment? { segments.last }

    /// Segments worth showing: very short flickers are folded away so the
    /// timeline stays readable. They still count towards totals.
    var displaySegments: [Segment] {
        segments.filter { $0.duration >= settings.minDisplaySegment }
    }

    // MARK: - Rule editing

    func impact(ofAdding rule: Rule) -> Impact {
        var after = rules
        after.insertBySpecificity(rule)
        var obs = data.observations
        if let o = open, o.duration > 0 { obs.append(o) }
        return Impact.compute(observations: obs, presence: data.presence, settings: settings,
                              before: rules, after: after)
    }

    func add(_ rule: Rule) {
        pushUndo("Add “\(rule.name)”")
        rules.insertBySpecificity(rule)
    }

    func remove(ruleId: UUID) {
        pushUndo("Remove rule")
        rules.remove(id: ruleId)
    }

    func setEnabled(_ enabled: Bool, ruleId: UUID) {
        guard var r = rules.rules.first(where: { $0.id == ruleId }) else { return }
        pushUndo("\(enabled ? "Enable" : "Disable") “\(r.name)”")
        r.enabled = enabled
        rules.replace(r)
    }

    func moveRules(from: IndexSet, to: Int) {
        pushUndo("Reorder rules")
        rules.move(from: from, to: to)
    }

    func replaceRules(_ set: RuleSet, note: String) {
        pushUndo(note)
        rules = set
    }

    private func pushUndo(_ note: String) {
        undoStack.append((rules, note))
        if undoStack.count > 30 { undoStack.removeFirst() }
    }

    var undoTitle: String? { undoStack.last?.1 }

    func undo() {
        guard let (previous, _) = undoStack.popLast() else { return }
        rules = previous
    }

    // MARK: - Setup

    func completeSetup(with set: RuleSet) {
        rules = set
        isSetUp = true
        store.save(set)
    }

    func detectEnvironment() -> Environment {
        EnvironmentScanner.scan(
            installedApps: Signals.installedApps(),
            firefoxContainers: { [weak self] in self?.browsers.firefoxContainers($0) ?? [] },
            chromiumProfiles: { [weak self] in self?.browsers.chromiumProfiles($0) ?? [] })
    }

    /// Classifying weeks of history is too slow for the main thread, so it
    /// happens on a background queue with its own Store.
    func loadStats(period: StatsPeriod, now: Date = Date(), completion: @escaping (RangeStats) -> Void) {
        let r = rules, s = settings, root = store.root
        // The open observation has not been committed to disk yet. Include a
        // snapshot of today's live record so week-to-date agrees with Today.
        var currentDay = data
        if let open, open.duration > 0 { currentDay.observations.append(open) }
        let snapshot = currentDay
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Store(root: root).stats(period: period, rules: r, settings: s,
                                               now: now, currentDay: snapshot)
            Task { @MainActor in completion(result) }
        }
    }

    // MARK: - Export

    func writeDaily() {
        lastDailyWrite = Date()
        store.upsertDaily(DailySummary.compute(day: day, segments: segments))
    }

    /// Rebuilds every day's totals under the current rules, so a fix applies to
    /// history and not just to today. Debounced: editing several rules in a row
    /// should rewrite the CSV once, not once per keystroke.
    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildAllDays() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func rebuildAllDays() {
        writeDaily()
        let r = rules, s = settings
        let root = store.root
        DispatchQueue.global(qos: .utility).async {
            // A separate Store instance: nothing is shared across queues.
            Store(root: root).rebuildDaily(rules: r, settings: s)
        }
    }

    private func maybeBackup() {
        guard !settings.backupTo.isEmpty,
              Date().timeIntervalSince(lastBackupAt) > settings.backupInterval else { return }
        lastBackupAt = Date()
        drainInbox()
        writeDaily()
        let result = store.mirror(to: settings.backupTo,
                                  includeObservations: settings.backupObservations, day: day)
        backupErrors = result.errors
        if !result.destinations.isEmpty { lastBackup = Date() }
    }

    /// Picks up rules and sessions sent from the phone. Runs on the backup
    /// cadence, since the same folder is being visited anyway.
    @discardableResult
    func drainInbox() -> Inbox.Result {
        var total = Inbox.Result()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        for token in settings.backupTo {
            guard let dir = CloudMirror.resolve(token, home: home) else { continue }
            var updated = rules
            let r = Inbox.drain(from: dir, into: store, rules: &updated)
            if r.rulesAdded > 0 { rules = updated }
            if r.sessionsAdded > 0 { data = store.load(day: day) }
            total.rulesAdded += r.rulesAdded
            total.sessionsAdded += r.sessionsAdded
            total.sessionSeconds += r.sessionSeconds
            total.failed += r.failed
        }
        if total.rulesAdded > 0 || total.sessionsAdded > 0 { reclassify() }
        return total
    }

    @discardableResult
    func backupNow() -> (destinations: [String], errors: [String]) {
        drainInbox()
        writeDaily()
        let r = store.mirror(to: settings.backupTo,
                             includeObservations: settings.backupObservations, day: day)
        backupErrors = r.errors
        if !r.destinations.isEmpty { lastBackup = Date() }
        return r
    }
}
