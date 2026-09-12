import Foundation

/// What a stretch of time is counted as.
public enum TimeCategory: String, Codable, Sendable, CaseIterable {
    /// Rules said this is work, and someone was present.
    case work
    /// Rules said this is not work.
    case personal
    /// Nobody was at the machine: idle, locked, asleep.
    case away
    /// No rule matched. Never guessed at, always offered for review.
    case unclassified

    public var glyph: String {
        switch self {
        case .work:         return "●"
        case .personal:     return "○"
        case .away:         return "◌"
        case .unclassified: return "?"
        }
    }

    public var label: String {
        switch self {
        case .work:         return "Work"
        case .personal:     return "Personal"
        case .away:         return "Away"
        case .unclassified: return "Unclassified"
        }
    }
}

/// What a rule can conclude. Presence is decided separately, so a rule only
/// ever says "this is work" or "this is not".
public enum Outcome: String, Codable, Sendable, CaseIterable {
    case work, personal

    public var state: TimeCategory { self == .work ? .work : .personal }
    public var label: String { self == .work ? "Work" : "Personal" }
}

/// Everything observed about what was on screen at one moment.
///
/// Deliberately free of any judgement: this is the raw record, and it is what
/// gets persisted. Verdicts are derived from it on demand, so editing a rule
/// re-decides the whole history instead of only affecting the future.
public struct Snapshot: Codable, Hashable, Sendable {
    public var bundleId: String
    public var appName: String
    public var windowTitle: String?

    /// Browser tab, when the front app is a browser.
    public var url: String?
    public var host: String?
    public var urlPath: String?
    /// Chrome/Edge/Arc profile, or Firefox/Zen container - the usual way people
    /// keep a work identity apart from a personal one in the same browser.
    public var browserProfile: String?

    /// Tenant inside a multi-account app: a Notion workspace, a Slack team.
    public var workspace: String?

    /// Folder open in an editor, resolved to a real path where possible.
    public var projectName: String?
    public var projectPath: String?

    /// False when the window could not be inspected at all - in practice,
    /// before Accessibility was granted. The process name is still known,
    /// because that needs no permission, but nothing inside the window is.
    ///
    /// Recorded rather than inferred later, because it is not recoverable: a
    /// stretch captured blind can never be classified by any rule, and saying
    /// so is more useful than offering rules that cannot work.
    public var detailAvailable: Bool

    public init(bundleId: String, appName: String, windowTitle: String? = nil,
                url: String? = nil, host: String? = nil, urlPath: String? = nil,
                browserProfile: String? = nil, workspace: String? = nil,
                projectName: String? = nil, projectPath: String? = nil,
                detailAvailable: Bool = true) {
        self.bundleId = bundleId; self.appName = appName; self.windowTitle = windowTitle
        self.url = url; self.host = host; self.urlPath = urlPath
        self.browserProfile = browserProfile; self.workspace = workspace
        self.projectName = projectName; self.projectPath = projectPath
        self.detailAvailable = detailAvailable
    }

    // Records written before this flag existed were captured with permission,
    // so they default to true.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        appName = try c.decode(String.self, forKey: .appName)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        urlPath = try c.decodeIfPresent(String.self, forKey: .urlPath)
        browserProfile = try c.decodeIfPresent(String.self, forKey: .browserProfile)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        detailAvailable = try c.decodeIfPresent(Bool.self, forKey: .detailAvailable) ?? true
    }

    /// Short "what am I looking at" line for the UI.
    public var summary: String {
        if let host {
            var s = host
            if let p = browserProfile { s += " · \(p)" }
            return s
        }
        if let w = workspace { return "\(appName) · \(w)" }
        if let p = projectName { return "\(appName) · \(p)" }
        if let t = windowTitle, !t.isEmpty { return "\(appName) · \(t)" }
        return appName
    }

    /// Stable identity used to group equivalent moments in the review queue.
    ///
    /// Stretches captured blind group on their own, so they are never mixed in
    /// with things a rule could actually fix.
    public var groupingKey: String {
        if !detailAvailable { return "nodetail:\(bundleId)" }
        if let host {
            return "web:\(host)" + (browserProfile.map { "@\($0)" } ?? "")
        }
        if let w = workspace { return "app:\(bundleId)#\(w)" }
        if let p = projectPath ?? projectName { return "project:\(p)" }
        return "app:\(bundleId)"
    }
}

/// A stretch during which the snapshot did not change.
public struct ObservationSpan: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var snapshot: Snapshot

    public init(start: Date, end: Date, snapshot: Snapshot) {
        self.start = start; self.end = end; self.snapshot = snapshot
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// A half-open time range, `start ..< end`.
public struct Span: Codable, Sendable, Equatable, Hashable {
    public var start: Date
    public var end: Date

    public init(_ start: Date, _ end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public func contains(_ d: Date) -> Bool { d >= start && d < end }
    public func overlaps(_ o: Span) -> Bool { start < o.end && o.start < end }

    public func intersection(_ o: Span) -> Span? {
        let s = Swift.max(start, o.start), e = Swift.min(end, o.end)
        return s < e ? Span(s, e) : nil
    }
}

/// Presence facts recorded as raw intervals rather than as decisions.
///
/// Storing when input happened, rather than "was idle", is what lets the idle
/// threshold be changed later and applied to the whole history.
public struct PresenceLog: Codable, Sendable, Equatable {
    /// Periods containing keyboard/mouse activity.
    public var input: [Span]
    /// Screen locked, display asleep, or screen saver running.
    public var absent: [Span]
    /// Microphone or camera in use by some app: a call, whatever the app.
    public var call: [Span]
    /// Periods the tracker was not running, or the machine was asleep.
    public var offline: [Span]

    public init(input: [Span] = [], absent: [Span] = [], call: [Span] = [], offline: [Span] = []) {
        self.input = input; self.absent = absent; self.call = call; self.offline = offline
    }

    public static func merge(_ spans: [Span], tolerance: TimeInterval) -> [Span] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.sorted { $0.start < $1.start }
        var out: [Span] = [sorted[0]]
        for s in sorted.dropFirst() {
            let last = out[out.count - 1]
            if s.start <= last.end.addingTimeInterval(tolerance) {
                out[out.count - 1] = Span(last.start, Swift.max(last.end, s.end))
            } else {
                out.append(s)
            }
        }
        return out
    }

    public mutating func normalise(tolerance: TimeInterval = 1) {
        input = PresenceLog.merge(input, tolerance: tolerance)
        absent = PresenceLog.merge(absent, tolerance: tolerance)
        call = PresenceLog.merge(call, tolerance: tolerance)
        offline = PresenceLog.merge(offline, tolerance: tolerance)
    }
}

/// A classified stretch of the day. Derived, never stored as the source of truth.
public struct Segment: Sendable, Equatable, Identifiable {
    public var id: String { "\(start.timeIntervalSince1970)-\(state.rawValue)" }
    public var start: Date
    public var end: Date
    public var state: TimeCategory
    public var snapshot: Snapshot?
    /// Which rule decided this, if any.
    public var ruleId: UUID?
    public var ruleName: String?
    /// Why, in words, for the UI.
    public var reason: String
    /// Entered by hand rather than observed.
    public var manual: Bool

    public init(start: Date, end: Date, state: TimeCategory, snapshot: Snapshot? = nil,
                ruleId: UUID? = nil, ruleName: String? = nil, reason: String,
                manual: Bool = false) {
        self.start = start; self.end = end; self.state = state; self.snapshot = snapshot
        self.ruleId = ruleId; self.ruleName = ruleName; self.reason = reason
        self.manual = manual
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public enum Format {
    public static func duration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return "\(m)m"
    }

    /// "4.25 h" style, for CSV and charts.
    public static func hours(_ t: TimeInterval) -> String {
        String(format: "%.3f", t / 3600)
    }

    public static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    public static func clockSeconds(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    public static func day(_ d: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.string(from: d)
    }
}
