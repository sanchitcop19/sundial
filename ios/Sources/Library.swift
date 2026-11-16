import Foundation
import Combine
import SundialCore

enum DurationSendStatus: Equatable {
    case queued(String)
    case sent(String)
    case failed(String)

    var message: String {
        switch self {
        case .queued(let message), .sent(let message), .failed(let message): return message
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock.fill"
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Reads the record the Mac mirrors to cloud storage, and posts changes back.
///
/// iOS cannot see which app is in front - there is no API for it, and Screen
/// Time data never leaves its own report extension. So this is a companion, not
/// a second tracker: it shows the Mac's record, lets the review queue be worked
/// anywhere, and records phone work you start yourself.
///
/// Writes never touch the mirrored files, which the Mac overwrites. They go
/// into an `inbox` folder the Mac drains, so neither side can clobber the other.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var day: String = Format.day(Date())
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var totals = Totals()
    @Published private(set) var reviewItems: [ReviewItem] = []
    @Published private(set) var daily: [DailySummary] = []
    @Published private(set) var rules = RuleSet()
    @Published private(set) var status: String?
    @Published private(set) var hasDetail = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var progress: WorkProgressSnapshot?
    @Published private(set) var progressStatus: String?
    @Published private(set) var durationStatus: DurationSendStatus?
    @Published private(set) var timer: PhoneTimer?

    let liveActivity = LiveActivityController()

    private let bookmarkKey = "sundial.folder.bookmark"
    private let deliveriesKey = "sundial.pending.deliveries"
    private let timerKey = "sundial.phone.timer"
    /// Persisted, so a send is still tracked if the app is closed before the
    /// Mac picks it up.
    private var deliveries: [PhoneDelivery] = []

    init() {
        restoreFolder()
        timer = UserDefaults.standard.data(forKey: timerKey)
            .flatMap { try? JSONDecoder().decode(PhoneTimer.self, from: $0) }
        deliveries = UserDefaults.standard.data(forKey: deliveriesKey)
            .flatMap { try? JSONDecoder().decode([PhoneDelivery].self, from: $0) } ?? []
        #if DEBUG
        // An isolated folder lets simulator checks exercise the real sync reader.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--sundial-sync-folder"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            folder = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1], isDirectory: true)
        }
        #endif
        // Push-to-start wakes the app without opening a view. Restore the sync
        // connection here so that activity and device tokens reach the Mac.
        if let folder {
            liveActivity.connect(to: folder)
            refreshProgress()
        }
    }

    // MARK: - Connecting

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        folder = url
    }

    func connect(to url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            status = "Could not open that folder."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        if folder != url {
            liveActivity.disconnect()
            progress = nil
            segments = []; totals = Totals(); reviewItems = []; daily = []
            hasDetail = false; pendingCount = 0
            durationStatus = nil; setDeliveries([])
        }
        if let data = try? url.bookmarkData(options: .minimalBookmark,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        folder = url
        liveActivity.connect(to: url)
        refresh()
    }

    func disconnect() {
        liveActivity.disconnect()
        folder?.stopAccessingSecurityScopedResource()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folder = nil
        segments = []; totals = Totals(); reviewItems = []; daily = []
        progress = nil; progressStatus = nil; status = nil; hasDetail = false
        pendingCount = 0; durationStatus = nil
        setDeliveries([])
    }

    // MARK: - Reading

    func refresh() {
        guard let folder else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        readProgress(in: folder)
        refreshDeliveryState()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = full.date(from: text) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: text) { return d }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "bad date")
        }

        if let d = try? Data(contentsOf: folder.appendingPathComponent("rules.json")),
           let r = try? dec.decode(RuleSet.self, from: d) {
            rules = r
        }
        if let text = try? String(contentsOf: folder.appendingPathComponent("daily.csv"),
                                  encoding: .utf8) {
            daily = text.split(separator: "\n").compactMap { DailySummary.parse(row: String($0)) }
                .sorted { $0.date < $1.date }
        }

        // The detailed record is optional on the Mac side, so its absence is a
        // state to explain rather than an error.
        day = Format.day(Date())
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let obsName = names.first { $0 == "observations-\(day).jsonl" }
            ?? names.filter { $0.hasPrefix("observations-") }.sorted().last
        guard let obsName else {
            hasDetail = false
            segments = []; reviewItems = []
            totals = Totals()
            if let summary = daily.last {
                day = summary.date
                totals.byState = [.work: summary.work, .personal: summary.personal,
                                  .away: summary.away, .unclassified: summary.unclassified]
            }
            status = daily.isEmpty && progress == nil
                ? "No record found in that folder."
                : "Turn on “Include the raw record” on your Mac to review individual activities here."
            return
        }
        hasDetail = true
        status = nil
        if let dayFromName = obsName.split(separator: "-").dropFirst().joined(separator: "-")
            .replacingOccurrences(of: ".jsonl", with: "") as String?, dayFromName.count == 10 {
            day = dayFromName
        }

        var observations: [ObservationSpan] = []
        if let text = try? String(contentsOf: folder.appendingPathComponent(obsName), encoding: .utf8) {
            observations = text.split(separator: "\n").compactMap {
                guard let d = $0.data(using: .utf8) else { return nil }
                return try? dec.decode(ObservationSpan.self, from: d)
            }
        }
        var presence = PresenceLog()
        if let d = try? Data(contentsOf: folder.appendingPathComponent("presence-\(day).json")),
           let p = try? dec.decode(PresenceLog.self, from: d) {
            presence = p
        }
        // Anything already sent from the phone counts too.
        let (extraObs, extraInput) = pendingSessions()
        observations.append(contentsOf: extraObs)
        presence.input.append(contentsOf: extraInput)
        presence.normalise()

        segments = Classifier(rules: rules, settings: .default)
            .classify(observations: observations, presence: presence)
        totals = Totals.compute(segments)
        reviewItems = ReviewItem.build(from: segments)
    }

    private func readProgress(in folder: URL) {
        let file = folder.appendingPathComponent("work-progress.json")
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        var coordinationError: NSError?
        var readError: Error?
        var snapshot: WorkProgressSnapshot?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            do {
                snapshot = try JSONDecoder().decode(WorkProgressSnapshot.self,
                                                     from: Data(contentsOf: url))
            } catch { readError = error }
        }
        if let snapshot, snapshot.isValid {
            if progress.map({ snapshot.updatedAt >= $0.updatedAt }) ?? true {
                progress = snapshot
            }
            progressStatus = nil
        } else {
            progressStatus = "Waiting for your Mac’s progress. Enable Sync work progress to iPhone in Sundial on your Mac and choose this same shared folder."
            if coordinationError != nil || readError != nil, progress != nil {
                progressStatus = "Could not refresh from the shared folder. Showing the last update from your Mac."
            }
        }
        let current = progress
        Task { await liveActivity.receive(current, folder: folder) }
    }

    func refreshProgress() {
        guard let folder else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        readProgress(in: folder)
        refreshDeliveryState()
    }

    private func refreshDeliveryState() {
        guard let folder else { return }
        let directory = folder.appendingPathComponent("inbox")
        // An unreadable inbox says nothing about delivery: reporting "added"
        // from a failed listing would be a false confirmation.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        pendingCount = names.count
        guard !deliveries.isEmpty else { return }

        let result = PhoneDeliveries.resolve(deliveries, present: Set(names))
        if result.remaining != deliveries { setDeliveries(result.remaining) }
        let status: DurationSendStatus?
        switch result.state {
        case .waiting(let message): status = .queued(message)
        case .delivered(let message): status = .sent(message)
        case .stalled(let message): status = .failed(message)
        case nil: status = nil
        }
        if let status, status != durationStatus { durationStatus = status }
    }

    private func setDeliveries(_ new: [PhoneDelivery]) {
        deliveries = new
        if new.isEmpty {
            UserDefaults.standard.removeObject(forKey: deliveriesKey)
        } else if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: deliveriesKey)
        }
    }

    func refreshInBackground() async {
        refreshProgress()
        if let folder { await liveActivity.receive(progress, folder: folder) }
    }

    // MARK: - Writing back

    private func inbox() -> URL {
        let dir = (folder ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("inbox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return e
    }

    /// Rules added on the phone are applied locally at once so the screen
    /// responds, and left in the inbox for the Mac to adopt.
    func add(_ rule: Rule) {
        guard let folder else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        rules.insertBySpecificity(rule)
        if let d = try? encoder.encode(rule) {
            try? d.write(to: inbox().appendingPathComponent("rule-\(rule.id.uuidString).json"),
                         options: .atomic)
        }
        refresh()
    }

    /// Queues phone time as a completed stretch ending now. The Mac already
    /// understands this inbox format, so duration entry does not need its own
    /// sync protocol or any timer state on the phone.
    @discardableResult
    func sendDuration(label: String, outcome: Outcome, duration: TimeInterval,
                      endingAt end: Date = Date()) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder else {
            durationStatus = .failed("Connect to your Mac before sending time.")
            return false
        }
        guard !label.isEmpty else {
            durationStatus = .failed("Add a label before sending time.")
            return false
        }
        guard duration >= 60, duration <= Manual.maxLength else {
            durationStatus = .failed("Choose a duration between 1 minute and 24 hours.")
            return false
        }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let span = ObservationSpan(
            start: end.addingTimeInterval(-duration), end: end,
            snapshot: Snapshot(bundleId: MobileSession.bundleId, appName: "Phone",
                               windowTitle: label, workspace: label))
        let fileName = "session-\(UUID().uuidString).json"
        let destination = inbox().appendingPathComponent(fileName)
        do {
            try encoder.encode(span).write(to: destination, options: .atomic)
        } catch {
            durationStatus = .failed("Could not push time to the shared folder: \(error.localizedDescription)")
            return false
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            durationStatus = .failed("The shared folder did not keep the time. Try again.")
            return false
        }
        // Make sure the label has a rule, so phone time is not left unclassified.
        if rules.match(span.snapshot) == nil {
            add(Rule(name: "Phone: \(label)",
                     conditions: [Condition(.bundleId, .equals, MobileSession.bundleId),
                                  Condition(.workspace, .equals, label)],
                     outcome: outcome, origin: .manual))
        } else {
            refresh()
        }
        setDeliveries(deliveries + [PhoneDelivery(
            fileName: fileName,
            description: "\(Format.duration(duration)) of \(outcome.label.lowercased())",
            queuedAt: Date())])
        refreshDeliveryState()
        return true
    }

    // MARK: - Timer

    /// Starts counting phone time. Nothing is sent until it is stopped, so the
    /// Mac only ever receives a finished stretch, the same as a typed duration.
    func startTimer(label: String, outcome: Outcome) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folder != nil else {
            durationStatus = .failed("Connect to your Mac before starting a timer.")
            return
        }
        guard !label.isEmpty else {
            durationStatus = .failed("Add a label before starting a timer.")
            return
        }
        guard timer == nil else { return }
        setTimer(PhoneTimer(start: Date(), label: label, outcome: outcome))
        durationStatus = nil
    }

    /// Stops the timer and sends what it measured. If sending fails the timer
    /// keeps running, so the time can be sent again rather than lost.
    func stopTimer() {
        guard let running = timer else { return }
        let now = Date()
        switch running.finish(at: now) {
        case .send(let duration):
            if sendDuration(label: running.label, outcome: running.outcome,
                            duration: duration, endingAt: now) {
                setTimer(nil)
            }
        case .tooShort:
            setTimer(nil)
            durationStatus = .failed("The timer ran under a minute, so nothing was sent.")
        case .tooLong:
            setTimer(nil)
            durationStatus = .failed("The timer ran over 24 hours, so nothing was sent. Add the time by hand.")
        }
    }

    /// Throws the running timer away without sending anything.
    func discardTimer() {
        setTimer(nil)
    }

    private func setTimer(_ new: PhoneTimer?) {
        timer = new
        if let new, let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: timerKey)
        } else {
            UserDefaults.standard.removeObject(forKey: timerKey)
        }
    }

    /// Sessions still waiting for the Mac to pick them up.
    private func pendingSessions() -> ([ObservationSpan], [Span]) {
        guard let folder else { return ([], []) }
        let dir = folder.appendingPathComponent("inbox")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return ([], [])
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let t = try d.singleValueContainer().decode(String.self)
            if let v = f.date(from: t) { return v }
            let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: t) ?? Date()
        }
        var obs: [ObservationSpan] = []
        for n in names where n.hasPrefix("session-") {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
               let s = try? dec.decode(ObservationSpan.self, from: d),
               Format.day(s.start) == day {
                obs.append(s)
            }
        }
        return (obs, obs.map { Span($0.start, $0.end) })
    }
}
