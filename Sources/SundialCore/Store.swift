import Foundation

/// Everything recorded for one day.
public struct DayData: Sendable, Equatable {
    public var day: String
    public var observations: [ObservationSpan]
    public var presence: PresenceLog
    /// Time entered by hand. Not observations, and never mixed into them.
    public var manual: [ManualEntry]

    public init(day: String, observations: [ObservationSpan] = [],
                presence: PresenceLog = PresenceLog(), manual: [ManualEntry] = []) {
        self.day = day; self.observations = observations
        self.presence = presence; self.manual = manual
    }

    public var isEmpty: Bool {
        observations.isEmpty && presence.input.isEmpty && manual.isEmpty
    }
}

/// On-disk layout. Raw observations are the source of truth; everything else -
/// segments, totals, the CSV - is derived and can be rebuilt at any time.
public final class Store: @unchecked Sendable {
    public let root: URL

    /// Coders are created per call rather than shared: the daily rebuild runs
    /// on a background queue while sampling continues on the main one, and
    /// JSONEncoder/JSONDecoder are not safe to use concurrently.
    private var enc: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        Store.applyDateStrategy(e, JSONDecoder())
        return e
    }
    private var dec: JSONDecoder {
        let d = JSONDecoder()
        Store.applyDateStrategy(JSONEncoder(), d)
        return d
    }

    /// Serialises the read-modify-write of daily.csv, which both the sampler
    /// and the background rebuild touch.
    private static let csvLock = NSLock()
    static func lockCSV() { csvLock.lock() }
    static func unlockCSV() { csvLock.unlock() }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sundial")
    }

    /// The app was called Escapement until it was renamed, and it was already
    /// recording by then, so the record moves with the name. Done once, on the
    /// first launch under the new name, and never when something already sits
    /// at the new path - so a stale folder can never overwrite a live record.
    static let legacyRootName = "Escapement"

    /// A destination that exists but holds nothing recorded - one a lock file
    /// has just brought into being, say - is still safe to move onto. Only an
    /// actual record blocks the move.
    static func holdsNoRecord(_ url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return true }
        return items.allSatisfy { $0 == "tracker.lock" || $0 == ".DS_Store" }
    }

    static func migrateLegacyRoot(_ legacy: URL, to current: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), holdsNoRecord(current) else { return }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        // Moved item by item rather than as a folder, so a lock already held
        // open at the destination keeps working and is never carried over.
        for item in (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? [] {
            guard item != "tracker.lock" else { continue }
            let to = current.appendingPathComponent(item)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: legacy.appendingPathComponent(item), to: to)
        }
    }

    /// Moves a record written under the app's previous name, if there is one
    /// and nothing has been recorded under the current one. Idempotent, and
    /// must run before anything else touches the folder.
    public static func migrateLegacyRootIfNeeded() {
        let root = defaultRoot
        migrateLegacyRoot(root.deletingLastPathComponent()
                              .appendingPathComponent(legacyRootName), to: root)
    }

    /// ISO-8601 with fractional seconds: still readable in the raw files, but
    /// without the sub-second truncation that plain .iso8601 would introduce
    /// into every recorded boundary.
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func applyDateStrategy(_ e: JSONEncoder, _ d: JSONDecoder) {
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Store.dateFormatter.string(from: date))
        }
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let d = Store.dateFormatter.date(from: text) { return d }
            // Tolerate files written without fractional seconds.
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: text) { return d }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "bad date \(text)")
        }
    }

    public init(root: URL = Store.defaultRoot) {
        // Only the real location is migrated. A store pointed at an explicit
        // root stays exactly where it was asked to be.
        if root.standardizedFileURL == Store.defaultRoot.standardizedFileURL {
            Store.migrateLegacyRootIfNeeded()
        }
        self.root = root
        for d in [root, root.appendingPathComponent("days")] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    private var daysDir: URL { root.appendingPathComponent("days") }
    public var rulesURL: URL { root.appendingPathComponent("rules.json") }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public var dailyCSVURL: URL { root.appendingPathComponent("daily.csv") }
    private var stateURL: URL { root.appendingPathComponent("current.json") }
    func observationsURL(_ day: String) -> URL { daysDir.appendingPathComponent("observations-\(day).jsonl") }
    func presenceURL(_ day: String) -> URL { daysDir.appendingPathComponent("presence-\(day).json") }
    func manualURL(_ day: String) -> URL { daysDir.appendingPathComponent("manual-\(day).json") }

    // MARK: - Rules and settings

    public func loadRules() -> RuleSet? {
        guard let d = try? Data(contentsOf: rulesURL) else { return nil }
        return try? dec.decode(RuleSet.self, from: d)
    }

    public func save(_ rules: RuleSet) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        Store.applyDateStrategy(e, JSONDecoder())
        guard let d = try? e.encode(rules) else { return }
        try? d.write(to: rulesURL, options: .atomic)
    }

    public func loadSettings() -> Settings {
        guard let d = try? Data(contentsOf: settingsURL),
              let s = try? dec.decode(Settings.self, from: d) else { return .default }
        return s
    }

    public func save(_ settings: Settings) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(settings) else { return }
        try? d.write(to: settingsURL, options: .atomic)
    }

    public func loadBreakReminderState() -> BreakReminderState {
        let url = root.appendingPathComponent("break-reminders.json")
        guard let data = try? Data(contentsOf: url),
              let state = try? dec.decode(BreakReminderState.self, from: data)
        else { return BreakReminderState() }
        return state
    }

    public func save(_ state: BreakReminderState) {
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: root.appendingPathComponent("break-reminders.json"), options: .atomic)
    }

    // MARK: - Observations

    /// Appends one closed observation span, splitting it if it crosses midnight
    /// so each day's file stands alone.
    public func append(_ span: ObservationSpan) {
        for piece in Store.splitAcrossDays(span) {
            guard piece.duration >= 0.5 else { continue }
            guard let line = try? enc.encode(piece) else { continue }
            var data = line
            data.append(0x0A)
            let url = observationsURL(Format.day(piece.start))
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    public static func splitAcrossDays(_ s: ObservationSpan,
                                       calendar: Calendar = .current) -> [ObservationSpan] {
        var out: [ObservationSpan] = []
        var cursor = s.start
        while cursor < s.end {
            guard let midnight = calendar.nextDate(
                after: cursor, matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime), midnight < s.end else { break }
            out.append(ObservationSpan(start: cursor, end: midnight, snapshot: s.snapshot))
            cursor = midnight
        }
        out.append(ObservationSpan(start: cursor, end: s.end, snapshot: s.snapshot))
        return out
    }

    public func savePresence(_ p: PresenceLog, day: String) {
        guard let d = try? enc.encode(p) else { return }
        try? d.write(to: presenceURL(day), options: .atomic)
    }

    public func load(day: String) -> DayData {
        var data = DayData(day: day)
        if let text = try? String(contentsOf: observationsURL(day), encoding: .utf8) {
            data.observations = text.split(separator: "\n").compactMap {
                guard let d = $0.data(using: .utf8) else { return nil }
                return try? dec.decode(ObservationSpan.self, from: d)
            }
        }
        if let d = try? Data(contentsOf: presenceURL(day)),
           let p = try? dec.decode(PresenceLog.self, from: d) {
            data.presence = p
        }
        data.manual = loadManual(day: day)
        return data
    }

    public func loadManual(day: String) -> [ManualEntry] {
        guard let d = try? Data(contentsOf: manualURL(day)),
              let m = try? dec.decode([ManualEntry].self, from: d) else { return [] }
        return m.sorted { $0.start < $1.start }
    }

    public func saveManual(_ entries: [ManualEntry], day: String) {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: manualURL(day))
            return
        }
        guard let d = try? enc.encode(entries.sorted { $0.start < $1.start }) else { return }
        try? d.write(to: manualURL(day), options: .atomic)
    }

    /// A day's whole timeline: what was observed, decided by the rules, with
    /// anything entered by hand laid over the top.
    public func segments(for day: String, rules: RuleSet, settings: Settings) -> [Segment] {
        let d = load(day: day)
        return Manual.apply(d.manual, to: Classifier(rules: rules, settings: settings)
            .classify(observations: d.observations, presence: d.presence))
    }

    public func availableDays() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: daysDir.path) else { return [] }
        // Hand-entered days count: a day spent entirely in meetings has no
        // observations at all, and still has to appear in the totals.
        let days = files.compactMap { name -> String? in
            if name.hasPrefix("observations-"), name.hasSuffix(".jsonl") {
                return String(name.dropFirst("observations-".count).dropLast(".jsonl".count))
            }
            if name.hasPrefix("manual-"), name.hasSuffix(".json") {
                return String(name.dropFirst("manual-".count).dropLast(".json".count))
            }
            return nil
        }
        return Array(Set(days)).sorted()
    }

    // MARK: - Crash recovery

    /// The span still being observed, mirrored every few seconds so a crash
    /// loses seconds rather than the current stretch.
    public func saveOpen(_ span: ObservationSpan?) {
        guard let span else { try? FileManager.default.removeItem(at: stateURL); return }
        if let d = try? enc.encode(span) { try? d.write(to: stateURL, options: .atomic) }
    }

    @discardableResult
    public func recoverOpen() -> ObservationSpan? {
        guard let d = try? Data(contentsOf: stateURL),
              let s = try? dec.decode(ObservationSpan.self, from: d) else { return nil }
        try? FileManager.default.removeItem(at: stateURL)
        guard s.duration >= 0.5 else { return nil }
        append(s)
        return s
    }
}
