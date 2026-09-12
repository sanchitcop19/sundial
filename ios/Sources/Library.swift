import Foundation
import Combine
import SundialCore

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
    @Published var activeSession: ManualSession?

    private let bookmarkKey = "sundial.folder.bookmark"
    private let sessionKey = "sundial.session.active"

    struct ManualSession: Codable, Equatable {
        var start: Date
        var label: String
        var outcome: Outcome
    }

    init() {
        restoreFolder()
        if let d = UserDefaults.standard.data(forKey: sessionKey) {
            activeSession = try? JSONDecoder().decode(ManualSession.self, from: d)
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
        if let data = try? url.bookmarkData(options: .minimalBookmark,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        folder = url
        refresh()
    }

    func disconnect() {
        folder?.stopAccessingSecurityScopedResource()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folder = nil
        segments = []; totals = Totals(); reviewItems = []; daily = []
    }

    // MARK: - Reading

    func refresh() {
        guard let folder else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
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
            status = daily.isEmpty
                ? "No record found in that folder."
                : "Daily totals only. Turn on “Include the raw record” in the Mac app to review here."
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
        pendingCount = (try? fm.contentsOfDirectory(atPath: inbox().path).count) ?? 0
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, enc in
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

    func startSession(label: String, outcome: Outcome) {
        activeSession = ManualSession(start: Date(), label: label, outcome: outcome)
        persistSession()
    }

    func stopSession() {
        guard let s = activeSession, let folder else { return }
        activeSession = nil
        persistSession()
        guard Date().timeIntervalSince(s.start) >= 5 else { return }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let span = ObservationSpan(
            start: s.start, end: Date(),
            snapshot: Snapshot(bundleId: MobileSession.bundleId, appName: "Phone",
                               windowTitle: s.label, workspace: s.label))
        if let d = try? encoder.encode(span) {
            try? d.write(to: inbox().appendingPathComponent("session-\(UUID().uuidString).json"),
                         options: .atomic)
        }
        // Make sure the label has a rule, so phone time is not left unclassified.
        if rules.match(span.snapshot) == nil {
            add(Rule(name: "Phone: \(s.label)",
                     conditions: [Condition(.bundleId, .equals, MobileSession.bundleId),
                                  Condition(.workspace, .equals, s.label)],
                     outcome: s.outcome, origin: .manual))
        } else {
            refresh()
        }
    }

    private func persistSession() {
        if let s = activeSession, let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dec.dateDecodingStrategy = .custom { d in
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

/// Time recorded on the phone is tagged with this instead of a real bundle id,
/// so it is obvious in the record where it came from.
enum MobileSession {
    static let bundleId = "sundial.phone.session"
}
