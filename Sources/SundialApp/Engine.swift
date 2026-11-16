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
    @Published private(set) var workTarget = WorkTarget.compute(
        settings: .default, previousDays: [], workedToday: 0, now: Date())
    @Published private(set) var isWorkTargetLoading = true

    // Configuration
    /// Whole days away from work. They have no target and are left out of averages.
    @Published private(set) var outOfOffice: OutOfOffice {
        didSet {
            guard outOfOffice != oldValue else { return }
            store.save(outOfOffice)
            statsCache = [:]
            updateWorkTarget()
        }
    }
    @Published var rules: RuleSet {
        didSet {
            store.save(rules)
            reclassify()
            reloadWorkTargetHistory()
            scheduleRebuild()
        }
    }
    @Published var settings: Settings {
        didSet {
            store.save(settings)
            var previous = oldValue
            previous.menuBarTimeDisplay = settings.menuBarTimeDisplay
            // Changing the menu bar does not affect tracking or break reminders.
            if previous == settings { return }
            // A target edit only changes the display; keep any active break intact.
            previous.dailyWorkTarget = settings.dailyWorkTarget
            previous.smartWorkTargetEnabled = settings.smartWorkTargetEnabled
            previous.weeklyWorkTarget = settings.weeklyWorkTarget
            previous.includeWeekendsInWorkTarget = settings.includeWeekendsInWorkTarget
            if previous != settings {
                reclassify()
                reloadWorkTargetHistory()
            } else {
                updateWorkTarget()
            }
        }
    }

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
    let phoneSync = PhoneSync()
    private var data: DayData
    private var open: ObservationSpan?
    private var timer: Timer?
    private var lastTick: Date?
    private var lastPresenceSave = Date.distantPast
    private var lastBackupAt = Date.distantPast
    private var lastInboxDrain = Date.distantPast
    private var lastDailyWrite = Date.distantPast
    private var undoStack: [(RuleSet, String)] = []
    private var projectIndex: [String: String] = [:]
    private var lastProjectScan = Date.distantPast
    private var workspaceCache: [pid_t: (String?, Date)] = [:]
    private var claudeAccountCache: (modified: Date, tag: String?)?
    /// The last statistics read per period, shown while a fresh read runs.
    var statsCache: [StatsPeriod: (stats: RangeStats, at: Date)] = [:]
    private var rebuildWork: DispatchWorkItem?
    private var followUpWork: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var breakReminderState: BreakReminderState
    private var breakStatusUpdatedAt = Date()
    private var breakCompletion = BreakCompletionTracker()
    private var previousWorkDays: [DailySummary]?
    private var workTargetRequest = UUID()
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
        outOfOffice = store.loadOutOfOffice()
        isSetUp = loaded != nil
        day = today
        data = store.load(day: today)

        if let recovered = store.recoverOpen() { data.observations.append(recovered) }
        noteOfflineSinceLastRun()
        reclassify()
        reloadWorkTargetHistory()
    }

    // MARK: - Lifecycle

    func start() {
        needsAccessibility = !Signals.accessibilityGranted
        reminders.onStart = { [weak self] in self?.startBreak() }
        reminders.onSnooze = { [weak self] in self?.snoozeBreak() }
        reminders.onSkip = { [weak self] in self?.skipBreak() }
        reminders.onBreakDueDelivered = { [weak self] in self?.recordBreakReminder(at: Date()) }
        breakPanel.onStart = { [weak self] in self?.startBreak() }
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
        let now = Date()
        guard !isPaused else {
            completeBreakIfNeeded(now: now)
            synchronizePhone()
            return
        }

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
        maybeDrainInbox()
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
        reloadWorkTargetHistory()
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
        } else if bundleId == ClaudeDesktop.bundleId {
            snap.workspace = claudeAccount()
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

    /// Re-read only when the file changes, which is when the account does.
    private func claudeAccount() -> String? {
        let url = ClaudeDesktop.configURL()
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        if let c = claudeAccountCache, c.modified == modified { return c.tag }
        let tag = (try? Data(contentsOf: url)).flatMap(ClaudeDesktop.accountTag(fromConfig:))
        claudeAccountCache = (modified, tag)
        return tag
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

    var breakCountdownText: String? {
        guard settings.breakReminders, settings.workBeforeBreak > 0 else { return nil }
        guard !isPaused || breakStatus.breakEndsAt != nil else { return "Break timer paused" }
        let elapsed = Date().timeIntervalSince(breakStatusUpdatedAt)
        let projected = breakStatus.breakEndsAt == nil ? min(settings.maxSampleGap, elapsed) : elapsed
        return breakStatus.countdownText(after: projected, currentState: currentState)
    }

    /// Recomputes every segment for the day from raw observations.
    func reclassify(preservingBreakProgress: Bool = false) {
        if !preservingBreakProgress {
            // Reclassifying history cannot create a break, and must not erase
            // observation of a timer the user already started.
            if breakReminderState.activeBreak == nil { breakCompletion.reset() }
            reminders.cancel()
            breakPanel.close()
        }
        if !settings.breakReminders || settings.workBeforeBreak <= 0 || settings.breakLength <= 0 {
            if breakReminderState.activeBreak != nil {
                breakReminderState.cancelBreak()
                store.save(breakReminderState)
            }
        }
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
        breakStatusUpdatedAt = Date()
        breakStatus = Breaks.status(segments: breakReminderState.segmentsSinceSkip(segments),
                                    now: breakStatusUpdatedAt, settings: settings,
                                    snoozedUntil: breakReminderState.quietUntil, inCall: inCall,
                                    currentState: currentState, activeBreak: breakReminderState.activeBreak)
        updateWorkTarget()
    }

    /// Only an explicit choice starts the countdown; activity classification
    /// continues to record actual work independently of this timer.
    func startBreak() {
        guard settings.breakReminders, settings.workBeforeBreak > 0,
              settings.breakLength > 0, !isPaused, breakReminderState.activeBreak == nil else { return }
        let now = Date()
        breakReminderState.start(at: now, length: settings.breakLength)
        store.save(breakReminderState)
        resetBreakNotifications()
        _ = breakCompletion.update(activeBreak: breakReminderState.activeBreak, now: now,
                                   settings: settings, inCall: inCall)
        reclassify(preservingBreakProgress: true)
    }

    /// Quiet for a while. The break stays owed, so the menu bar keeps saying so.
    func snoozeBreak() {
        guard settings.breakReminders, !isPaused, breakStatus.owed,
              breakReminderState.activeBreak == nil else { return }
        breakReminderState.snooze(at: Date())
        store.save(breakReminderState)
        reminders.cancelBreakDue()
        breakPanel.close()
        reclassify(preservingBreakProgress: true)
    }

    func skipBreak() {
        guard settings.breakReminders, !isPaused, breakStatus.owed,
              breakReminderState.activeBreak == nil else { return }
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

    @discardableResult
    private func completeBreakIfNeeded(now: Date) -> Bool {
        let notify = breakCompletion.update(activeBreak: breakReminderState.activeBreak, now: now,
                                            settings: settings, inCall: inCall || isPaused)
        guard let completed = breakReminderState.finishBreak(at: now) else { return false }
        // Persist consumption before notifying, including silent expiry after
        // relaunch or sleep, so an old break cannot announce itself again.
        store.save(breakReminderState)
        reminders.cancel()
        breakPanel.close()
        reclassify(preservingBreakProgress: true)
        if notify { reminders.breakOver(length: completed.duration) }
        return true
    }

    /// Said once when a break falls due, then at most every twenty minutes while
    /// it is still owed: a reminder that repeats every tick is an alarm.
    private func updateBreakReminders(now: Date) {
        if completeBreakIfNeeded(now: now) { return }
        guard breakReminderState.activeBreak == nil else { return }
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
        else { reloadWorkTargetHistory() }
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

    // MARK: - Work targets

    private func updateWorkTarget() {
        var targetSettings = settings
        // Use the ordinary daily target until the current week's history is ready.
        if previousWorkDays == nil { targetSettings.smartWorkTargetEnabled = false }
        let result = WorkTarget.compute(settings: targetSettings,
                                        previousDays: previousWorkDays ?? [],
                                        workedToday: totals.work, now: Date(),
                                        outOfOffice: outOfOffice)
        if result != workTarget { workTarget = result }
        synchronizePhone()
    }

    private func synchronizePhone() {
        guard day == Format.day(Date()), !(settings.smartWorkTargetEnabled && isWorkTargetLoading) else { return }
        var snapshot = WorkProgressSnapshot(
            day: day, timeZoneIdentifier: TimeZone.current.identifier,
            updatedAt: Date().timeIntervalSince1970, worked: totals.work, target: workTarget.dailyTarget,
            weeklyWorked: settings.smartWorkTargetEnabled ? workTarget.weeklyWorked : nil,
            weeklyTarget: settings.smartWorkTargetEnabled ? workTarget.weeklyTarget : nil,
            state: currentState.rawValue, isPaused: isPaused)
        snapshot.updateBreak(breakStatus)
        phoneSync.update(snapshot, destinations: settings.backupTo)
    }

    /// At most six completed days are classified, off the main thread. Live
    /// ticks reuse this cache; only history or classification changes invalidate it.
    private func reloadWorkTargetHistory() {
        let requestedDay = day
        let request = UUID()
        workTargetRequest = request
        previousWorkDays = nil
        isWorkTargetLoading = true
        updateWorkTarget()
        let dayStart = StatsPeriod.calendar.startOfDay(for: Date())
        loadStats(period: .week, now: dayStart) { [weak self] stats in
            guard let self, self.workTargetRequest == request,
                  self.day == requestedDay, Format.day(Date()) == requestedDay else { return }
            self.previousWorkDays = stats.days.filter { $0.day < requestedDay }.map {
                DailySummary(date: $0.day, work: $0.work)
            }
            self.isWorkTargetLoading = false
            self.updateWorkTarget()
        }
    }

    var isOutOfOfficeToday: Bool { outOfOffice.contains(Date()) }

    func markOutOfOffice(_ away: Bool, from first: Date, through last: Date) {
        var updated = outOfOffice
        if away {
            updated.add(from: first, through: last, calendar: StatsPeriod.calendar)
        } else {
            updated.remove(from: first, through: last, calendar: StatsPeriod.calendar)
        }
        outOfOffice = updated
    }

    func removeOutOfOffice(_ run: OutOfOffice.Run) {
        var updated = outOfOffice
        updated.remove(days: run.days)
        outOfOffice = updated
    }

    func toggleOutOfOfficeToday() {
        let today = Date()
        markOutOfOffice(!isOutOfOfficeToday, from: today, through: today)
    }

    var workTargetLabel: String {
        if workTarget.isOutOfOffice { return "Out of office" }
        if workTarget.isRestDay { return "Rest day" }
        let kind = settings.smartWorkTargetEnabled && !isWorkTargetLoading ? "adjusted" : "daily"
        return "\(Format.hoursMinutes(workTarget.dailyTarget, roundingUp: true)) \(kind) target"
    }

    var workTargetWeekSummary: String? {
        guard settings.smartWorkTargetEnabled else { return nil }
        guard !isWorkTargetLoading else { return "Updating this week’s work…" }
        return "\(Format.duration(workTarget.weeklyWorked)) of \(Format.duration(workTarget.weeklyTarget)) this week"
            + " · \(Format.hoursMinutes(workTarget.weeklyRemaining, roundingUp: true)) left"
    }

    var workTargetNote: String? {
        guard settings.smartWorkTargetEnabled, !isWorkTargetLoading else { return nil }
        if workTarget.isOutOfOffice {
            return "Work you do today still counts toward this week."
        }
        if workTarget.weeklyTarget <= 0 {
            return "Every planned day this week is out of office, so there is no weekly target."
        }
        if workTarget.isRestDay {
            return workTarget.weeklyRemaining > 0
                ? "No planned days left this week. Weekend work still counts toward the weekly target."
                : "Rest day. The weekly target is complete."
        }
        if workTarget.isCapped && workTarget.weeklyRemaining > 0 {
            return "The weekly target needs \(Format.hoursMinutes(workTarget.requiredDailyPace, roundingUp: true)) per planned day; "
                + "today’s target stays at \(Format.hoursMinutes(workTarget.dailyTarget, roundingUp: true))."
        }
        if workTarget.plannedDaysAway > 0 {
            let days = workTarget.plannedDaysAway
            return "The weekly target is reduced for \(days) day\(days == 1 ? "" : "s") out of office."
        }
        return nil
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
        reloadWorkTargetHistory()
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

    /// The phone reports an entry as waiting until the Mac takes it, and as
    /// failed if that takes too long, so this interval is the one the phone
    /// quotes. Anything applied is mirrored at once: the phone stops counting
    /// the inbox file as soon as it is gone, and the mirror must already
    /// include it.
    private func maybeDrainInbox() {
        guard !settings.backupTo.isEmpty,
              Date().timeIntervalSince(lastInboxDrain) >= PhoneDeliveries.macCheckInterval
        else { return }
        lastInboxDrain = Date()
        let r = drainInbox()
        guard r.rulesAdded > 0 || r.sessionsAdded > 0 else { return }
        backupNow()
        lastBackupAt = Date()
    }

    /// Picks up rules and sessions sent from the phone. Also runs with every
    /// backup, since the same folder is being visited anyway.
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
        if total.rulesAdded > 0 || total.sessionsAdded > 0 {
            reclassify()
            reloadWorkTargetHistory()
        }
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
