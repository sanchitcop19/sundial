import Foundation

/// One test against an observed snapshot.
///
/// Modelled as data (field + operator + value) rather than as code so rules can
/// be created, explained, edited and reordered from the UI, and round-trip
/// through JSON without a bespoke encoder.
public struct Condition: Codable, Hashable, Sendable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case bundleId, appName, host, url, title, workspace, browserProfile, projectPath
    }

    public enum Op: String, Codable, Sendable, CaseIterable {
        /// Exact, case-insensitive.
        case equals
        /// Case-insensitive substring.
        case contains
        /// Host equal to, or a subdomain of, the value.
        case hostOrSubdomain
        /// URL starts with `host/path`.
        case urlPrefix
        /// One " - " / " — " separated part of the title equals the value.
        /// Precise where `contains` would over-match (Slack workspace names).
        case titleSegment
        /// Path equal to, or inside, the value's folder.
        case pathUnder
    }

    public var field: Field
    public var op: Op
    public var value: String

    public init(_ field: Field, _ op: Op, _ value: String) {
        self.field = field; self.op = op; self.value = value
    }

    /// How narrow this condition is; used to order new rules so a broad rule
    /// never silently shadows a precise one.
    public var specificity: Int {
        switch op {
        case .urlPrefix:       return 100 + value.count
        case .pathUnder:       return 90 + value.count
        case .equals:          return field == .bundleId ? 40 : 70
        case .titleSegment:    return 60
        case .hostOrSubdomain: return 50
        case .contains:        return 30
        }
    }

    func value(from s: Snapshot) -> String? {
        switch field {
        case .bundleId:       return s.bundleId
        case .appName:        return s.appName
        case .host:           return s.host
        case .url:            return s.url
        case .title:          return s.windowTitle
        case .workspace:      return s.workspace
        case .browserProfile: return s.browserProfile
        case .projectPath:    return s.projectPath ?? s.projectName
        }
    }

    public func matches(_ s: Snapshot) -> Bool {
        // Path scoping is derived from host and path, never from the full URL
        // string, so it works for any observation carrying a host - including
        // ones reconstructed from an import, where no full URL was recorded.
        if op == .urlPrefix {
            guard let host = s.host?.lowercased() else { return false }
            let path = (s.urlPath ?? "").lowercased()
            let full = host + path
            let v = value.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            guard full.hasPrefix(v) else { return false }
            if full.count == v.count { return true }
            let next = full[full.index(full.startIndex, offsetBy: v.count)]
            return next == "/" || next == "?" || v.hasSuffix("/")
        }

        guard let actual = value(from: s), !actual.isEmpty else { return false }
        switch op {
        case .equals:
            return actual.caseInsensitiveCompare(value) == .orderedSame

        case .contains:
            return actual.localizedCaseInsensitiveContains(value)

        case .hostOrSubdomain:
            let a = actual.lowercased(), v = value.lowercased()
            return a == v || a.hasSuffix("." + v)

        case .urlPrefix:
            return false   // handled above

        case .titleSegment:
            let parts = actual
                .components(separatedBy: CharacterSet(charactersIn: "\u{2014}\u{2013}"))
                .flatMap { $0.components(separatedBy: " - ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.contains { $0.caseInsensitiveCompare(value) == .orderedSame }

        case .pathUnder:
            let a = (actual as NSString).standardizingPath
            let v = (NSString(string: value).expandingTildeInPath as NSString).standardizingPath
            return a == v || a.hasPrefix(v + "/")
        }
    }

    /// Plain-English fragment, e.g. "site is github.com or a subdomain".
    public var describe: String {
        switch (field, op) {
        case (.host, .hostOrSubdomain): return "site is \(value) (or a subdomain)"
        case (.url, .urlPrefix):        return "URL starts with \(value)"
        case (.bundleId, .equals):      return "app is \(value)"
        case (.appName, _):             return "app name contains \(value)"
        case (.title, .titleSegment):   return "window title has a part equal to \(value)"
        case (.title, _):               return "window title contains \(value)"
        case (.workspace, _):           return "workspace is \(value)"
        case (.browserProfile, _):      return "browser profile is \(value)"
        case (.projectPath, .pathUnder):return "folder is inside \(value)"
        default:                        return "\(field.rawValue) \(op.rawValue) \(value)"
        }
    }
}

/// A rule: when every condition matches, the time counts as `outcome`.
public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Created by the setup wizard.
        case setup
        /// Created by correcting a segment in the timeline.
        case correction
        /// Hand-written by the user.
        case manual
    }

    public var id: UUID
    public var enabled: Bool
    public var name: String
    /// All conditions must match.
    public var conditions: [Condition]
    public var outcome: Outcome
    public var createdAt: Date
    public var origin: Origin

    public init(id: UUID = UUID(), enabled: Bool = true, name: String,
                conditions: [Condition], outcome: Outcome,
                createdAt: Date = Date(), origin: Origin = .manual) {
        self.id = id; self.enabled = enabled; self.name = name
        self.conditions = conditions; self.outcome = outcome
        self.createdAt = createdAt; self.origin = origin
    }

    public func matches(_ s: Snapshot) -> Bool {
        !conditions.isEmpty && conditions.allSatisfy { $0.matches(s) }
    }

    public var specificity: Int {
        conditions.reduce(0) { $0 + $1.specificity } + conditions.count
    }

    public var describe: String {
        conditions.map(\.describe).joined(separator: " and ")
    }
}

/// The ordered rule list. First enabled match wins.
public struct RuleSet: Codable, Sendable, Equatable {
    public var rules: [Rule]

    public init(rules: [Rule] = []) { self.rules = rules }

    public func match(_ s: Snapshot) -> Rule? {
        rules.first { $0.enabled && $0.matches(s) }
    }

    /// Inserts above every less specific rule and below every more specific
    /// one, so adding "all of Chrome is personal" cannot silently swallow an
    /// existing "this one site is work".
    public mutating func insertBySpecificity(_ rule: Rule) {
        let idx = rules.firstIndex { $0.specificity < rule.specificity } ?? rules.count
        rules.insert(rule, at: idx)
    }

    public mutating func remove(id: UUID) { rules.removeAll { $0.id == id } }

    public mutating func replace(_ rule: Rule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
    }

    /// Reorders by drag. Implemented here rather than using SwiftUI's
    /// `move(fromOffsets:toOffset:)` so the core stays free of UI frameworks.
    public mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().compactMap { rules.indices.contains($0) ? rules[$0] : nil }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        for i in offsets.sorted(by: >) where rules.indices.contains(i) { rules.remove(at: i) }
        let target = min(max(0, destination - before), rules.count)
        rules.insert(contentsOf: moving, at: target)
    }
}

/// Thresholds and other knobs that affect classification but are not rules.
public struct Settings: Codable, Sendable, Equatable {
    /// Silence after which nobody is considered present.
    public var idleThreshold: TimeInterval
    /// The same, while a call is in progress - sitting still in a meeting is
    /// still working.
    public var callIdleThreshold: TimeInterval
    /// A larger jump between samples means the machine slept.
    public var maxSampleGap: TimeInterval
    public var sampleInterval: TimeInterval
    /// Ignore stretches shorter than this when displaying, to keep the timeline
    /// readable. They still count towards totals.
    public var minDisplaySegment: TimeInterval
    /// How often the menu bar dot dips while work is being counted. The one
    /// setting here that costs battery: the menu bar is composited over the
    /// wallpaper, so every beat repaints a blurred strip.
    public var beatPeriod: TimeInterval

    /// Say something after a long enough unbroken run of work.
    public var breakReminders: Bool
    /// How much work earns a break. Counted as work, not as wall clock.
    public var workBeforeBreak: TimeInterval
    /// How long away from work counts as having taken one.
    public var breakLength: TimeInterval

    public var backupTo: [String]
    public var backupInterval: TimeInterval
    public var backupObservations: Bool

    public static let `default` = Settings(
        idleThreshold: 120,
        callIdleThreshold: 3600,
        maxSampleGap: 30,
        sampleInterval: 5,
        minDisplaySegment: 20,
        beatPeriod: 1.25,
        breakReminders: true,
        workBeforeBreak: 1500,
        breakLength: 300,
        backupTo: [],
        backupInterval: 900,
        backupObservations: false)

    public init(idleThreshold: TimeInterval, callIdleThreshold: TimeInterval,
                maxSampleGap: TimeInterval, sampleInterval: TimeInterval,
                minDisplaySegment: TimeInterval, beatPeriod: TimeInterval,
                breakReminders: Bool, workBeforeBreak: TimeInterval,
                breakLength: TimeInterval, backupTo: [String],
                backupInterval: TimeInterval, backupObservations: Bool) {
        self.idleThreshold = idleThreshold; self.callIdleThreshold = callIdleThreshold
        self.maxSampleGap = maxSampleGap; self.sampleInterval = sampleInterval
        self.minDisplaySegment = minDisplaySegment; self.beatPeriod = beatPeriod
        self.breakReminders = breakReminders; self.workBeforeBreak = workBeforeBreak
        self.breakLength = breakLength; self.backupTo = backupTo
        self.backupInterval = backupInterval; self.backupObservations = backupObservations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? fallback
        }
        idleThreshold = v(.idleThreshold, d.idleThreshold)
        callIdleThreshold = v(.callIdleThreshold, d.callIdleThreshold)
        maxSampleGap = v(.maxSampleGap, d.maxSampleGap)
        sampleInterval = v(.sampleInterval, d.sampleInterval)
        minDisplaySegment = v(.minDisplaySegment, d.minDisplaySegment)
        // Clamped: a hand-edited zero here would otherwise arm a timer with no
        // delay, and anything slower than a few seconds is not a beat at all.
        beatPeriod = min(max(v(.beatPeriod, d.beatPeriod), 0.3), 3)
        breakReminders = v(.breakReminders, d.breakReminders)
        // A zero here would make every moment of work overdue for a break.
        workBeforeBreak = max(v(.workBeforeBreak, d.workBeforeBreak), 60)
        breakLength = max(v(.breakLength, d.breakLength), 60)
        backupTo = v(.backupTo, d.backupTo)
        backupInterval = v(.backupInterval, d.backupInterval)
        backupObservations = v(.backupObservations, d.backupObservations)
    }
}
