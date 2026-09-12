import Foundation

/// A candidate rule offered when correcting a segment.
///
/// Corrections are the main way rules get written, so the choice on offer is
/// deliberately a ladder of scopes - "just this page" through "the whole app" -
/// rather than a blank form. Picking the right breadth is the hard part of
/// rule-writing, so the app does the drafting and shows the consequences.
public struct Suggestion: Sendable, Identifiable, Equatable {
    /// Narrow to broad. Also the order shown.
    public enum Scope: Int, Sendable, Comparable, CaseIterable {
        case exactPage, section, site, profile, workspace, project, folder, titlePart, app
        public static func < (a: Scope, b: Scope) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { scope.rawValue.description + ":" + conditions.map(\.value).joined(separator: "|") }
    public var scope: Scope
    /// Button text, e.g. "Everything on github.com".
    public var title: String
    /// One line on exactly what this would cover.
    public var detail: String
    /// Why this choice is likely to be wrong here. Set when a scope covers
    /// things the person can already be seen to use both ways.
    public var caution: String?
    public var conditions: [Condition]

    public func rule(outcome: Outcome, origin: Rule.Origin = .correction) -> Rule {
        Rule(name: title, conditions: conditions, outcome: outcome, origin: origin)
    }
}

public enum Suggestions {
    /// Builds the scope ladder for one observed snapshot, narrowest first.
    public static func build(for s: Snapshot) -> [Suggestion] {
        var out: [Suggestion] = []

        if let host = s.host, !host.isEmpty {
            let path = s.urlPath ?? ""
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

            // A specific page or document.
            if !path.isEmpty, path != "/" {
                out.append(Suggestion(
                    scope: .exactPage, title: "Only this page",
                    detail: "\(host)\(path)",
                    conditions: [Condition(.url, .urlPrefix, host + path)]))

                // The first path component is usually the org, team or project.
                let parts = path.split(separator: "/").map(String.init)
                if let first = parts.first, parts.count > 1 {
                    out.append(Suggestion(
                        scope: .section, title: "Everything under \(cleanHost)/\(first)",
                        detail: "Covers every page below \(host)/\(first)",
                        conditions: [Condition(.url, .urlPrefix, "\(host)/\(first)")]))
                }
            }

            out.append(Suggestion(
                scope: .site, title: "Everything on \(cleanHost)",
                detail: "The whole site, including subdomains",
                conditions: [Condition(.host, .hostOrSubdomain, cleanHost)]))
        }

        // A browser profile or container is usually the cleanest work/personal split.
        if let profile = s.browserProfile, !profile.isEmpty {
            out.append(Suggestion(
                scope: .profile, title: "All browsing in “\(profile)”",
                detail: "Every tab in the \(profile) profile of \(s.appName)",
                conditions: [Condition(.bundleId, .equals, s.bundleId),
                             Condition(.browserProfile, .equals, profile)]))
        }

        if let ws = s.workspace, !ws.isEmpty {
            out.append(Suggestion(
                scope: .workspace, title: "All of the “\(ws)” workspace",
                detail: "Everything in \(s.appName) while \(ws) is open",
                conditions: [Condition(.bundleId, .equals, s.bundleId),
                             Condition(.workspace, .equals, ws)]))
        }

        if let path = s.projectPath, !path.isEmpty {
            let display = (path as NSString).abbreviatingWithTildeInPath
            out.append(Suggestion(
                scope: .project, title: "The \((path as NSString).lastPathComponent) project",
                detail: "Any editor or terminal inside \(display)",
                conditions: [Condition(.projectPath, .pathUnder, path)]))

            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != "/" {
                let parentDisplay = (parent as NSString).abbreviatingWithTildeInPath
                out.append(Suggestion(
                    scope: .folder, title: "Everything in \(parentDisplay)",
                    detail: "Every project inside that folder",
                    conditions: [Condition(.projectPath, .pathUnder, parent)]))
            }
        }

        // An editor whose folder is open but not under any known code root: the
        // name from the title is still enough to tell one project from another.
        if s.projectPath == nil, let name = s.projectName, !name.isEmpty {
            out.append(Suggestion(
                scope: .project, title: "The “\(name)” project",
                detail: "\(s.appName) whenever \(name) is the open folder",
                conditions: [Condition(.bundleId, .equals, s.bundleId),
                             Condition(.projectPath, .equals, name)]))
        }

        // A title part is how apps like Slack expose the account in use.
        if let title = s.windowTitle, s.host == nil, s.workspace == nil {
            let parts = title
                .components(separatedBy: CharacterSet(charactersIn: "\u{2014}\u{2013}"))
                .flatMap { $0.components(separatedBy: " - ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 2 && $0.count < 40 && $0 != s.appName }
            if parts.count > 1, let candidate = parts.dropFirst().first {
                out.append(Suggestion(
                    scope: .titlePart, title: "\(s.appName) windows for “\(candidate)”",
                    detail: "Matches when the title contains the part “\(candidate)”",
                    conditions: [Condition(.bundleId, .equals, s.bundleId),
                                 Condition(.title, .titleSegment, candidate)]))
            }
        }

        // An app that reports a project is an app used for several projects, and
        // an editor is the obvious case: one rule for all of VS Code quietly
        // claims every personal repo as well. Offered, because sometimes it is
        // what you want, but never offered silently.
        let project = s.projectName ?? (s.projectPath as NSString?)?.lastPathComponent
        out.append(Suggestion(
            scope: .app, title: "All of \(s.appName)",
            detail: "Every window of \(s.appName), whatever is in it",
            caution: project.map {
                "\(s.appName) is open on “\($0)” now, but this would cover every other "
                + "project in it too. The narrower choices above survive that."
            },
            conditions: [Condition(.bundleId, .equals, s.bundleId)]))

        return out.sorted { $0.scope < $1.scope }
    }
}

/// What adding, removing or editing a rule would do to time already recorded.
///
/// Shown before the change is committed, so a rule that is too broad is
/// obvious immediately rather than discovered at the end of the week.
public struct Impact: Sendable, Equatable {
    public var before: Totals
    public var after: Totals
    public var changedSeconds: TimeInterval
    public var changedSegments: Int
    /// Time that moved out of a state it had been confidently assigned - the
    /// signal that a new rule is overreaching.
    public var reclassifiedFromDecided: TimeInterval

    public var workDelta: TimeInterval { after.work - before.work }

    public var summary: String {
        if changedSeconds < 1 { return "No time already recorded would change." }
        var s = "\(Format.duration(changedSeconds)) would be reclassified"
        if abs(workDelta) >= 1 {
            s += ", work \(workDelta > 0 ? "+" : "−")\(Format.duration(abs(workDelta)))"
        }
        if reclassifiedFromDecided >= 1 {
            s += ". \(Format.duration(reclassifiedFromDecided)) of that already had a rule."
        }
        return s + "."
    }

    /// Reclassifies the same history under both rule sets and diffs them.
    public static func compute(observations: [ObservationSpan], presence: PresenceLog,
                               settings: Settings,
                               before rulesBefore: RuleSet,
                               after rulesAfter: RuleSet) -> Impact {
        let a = Classifier(rules: rulesBefore, settings: settings)
            .classify(observations: observations, presence: presence)
        let b = Classifier(rules: rulesAfter, settings: settings)
            .classify(observations: observations, presence: presence)

        var impact = Impact(before: Totals.compute(a), after: Totals.compute(b),
                            changedSeconds: 0, changedSegments: 0,
                            reclassifiedFromDecided: 0)

        // Walk both timelines together over their shared boundaries.
        var cuts = Set<Date>()
        for s in a { cuts.insert(s.start); cuts.insert(s.end) }
        for s in b { cuts.insert(s.start); cuts.insert(s.end) }
        let ordered = cuts.sorted()
        guard ordered.count > 1 else { return impact }

        var changedRuns = 0
        var previousChanged = false
        for i in 0..<(ordered.count - 1) {
            let t = ordered[i], next = ordered[i + 1]
            let dur = next.timeIntervalSince(t)
            guard dur > 0 else { continue }
            let sa = state(of: a, at: t), sb = state(of: b, at: t)
            let changed = sa?.state != sb?.state
            if changed {
                impact.changedSeconds += dur
                if sa?.state != .unclassified && sa?.state != nil {
                    impact.reclassifiedFromDecided += dur
                }
                if !previousChanged { changedRuns += 1 }
            }
            previousChanged = changed
        }
        impact.changedSegments = changedRuns
        return impact
    }

    private static func state(of segments: [Segment], at d: Date) -> Segment? {
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].end <= d { lo = mid + 1 }
            else if segments[mid].start > d { hi = mid - 1 }
            else { return segments[mid] }
        }
        return nil
    }

    public init(before: Totals, after: Totals, changedSeconds: TimeInterval,
                changedSegments: Int, reclassifiedFromDecided: TimeInterval) {
        self.before = before; self.after = after
        self.changedSeconds = changedSeconds; self.changedSegments = changedSegments
        self.reclassifiedFromDecided = reclassifiedFromDecided
    }
}
