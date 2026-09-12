import Foundation

/// One-shot migration from the earlier WorkClock tracker.
///
/// WorkClock stored a verdict per stretch and never kept raw input times, so
/// two things are reconstructed rather than recovered:
///   - the observation, from the context key and detail it recorded;
///   - presence, from its own conclusions - stretches it called active become
///     input, stretches it called away become absence.
/// That reproduces its numbers faithfully without pretending to a precision the
/// old data never had. Its configuration is translated into rules, so imported
/// history is classified rather than dumped into the review queue.
public enum WorkClockImport {
    public struct Result: Sendable, Equatable {
        public var days = 0
        public var observations = 0
        public var rules = 0
        public var imported: TimeInterval = 0
        public var skippedOverlapping = 0
    }

    public struct LegacySegment: Decodable {
        public var start: Date
        public var end: Date
        public var state: String
        public var app: String
        public var detail: String
        public var rule: String
        public var contextKey: String

        public init(start: Date, end: Date, state: String, app: String,
                    detail: String, rule: String, contextKey: String) {
            self.start = start; self.end = end; self.state = state; self.app = app
            self.detail = detail; self.rule = rule; self.contextKey = contextKey
        }
    }

    static var legacyDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Configuration to rules

    /// Translates a WorkClock config.json into an equivalent rule set.
    public static func rules(fromConfig data: Data) -> RuleSet {
        var set = RuleSet()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return set
        }
        func add(_ name: String, _ conditions: [Condition], _ outcome: Outcome) {
            guard !conditions.isEmpty else { return }
            set.insertBySpecificity(Rule(name: name, conditions: conditions,
                                         outcome: outcome, origin: .setup))
        }
        func urlCondition(_ pattern: String) -> Condition {
            pattern.contains("/") ? Condition(.url, .urlPrefix, pattern)
                                  : Condition(.host, .hostOrSubdomain, pattern)
        }

        for p in (root["personalURLPatterns"] as? [String]) ?? [] {
            add(p, [urlCondition(p)], .personal)
        }
        for p in (root["workURLPatterns"] as? [String]) ?? [] {
            add(p, [urlCondition(p)], .work)
        }
        // Container and space names both surface as the browser profile.
        for name in (root["zenWorkSpaceNames"] as? [String]) ?? [] {
            add("\(name) browser profile", [Condition(.browserProfile, .equals, name)], .work)
        }
        for path in (root["workRepoRoots"] as? [String]) ?? [] {
            add("Code in \((path as NSString).abbreviatingWithTildeInPath)",
                [Condition(.projectPath, .pathUnder, path)], .work)
        }
        for (bundle, state) in (root["appStates"] as? [String: String]) ?? [:] {
            guard let outcome = Outcome(rawValue: state == "working" ? "work" : state) else { continue }
            add(bundle.split(separator: ".").last.map(String.init) ?? bundle,
                [Condition(.bundleId, .equals, bundle)], outcome)
        }
        for r in (root["titleRules"] as? [[String: Any]]) ?? [] {
            guard let stateText = r["state"] as? String,
                  let outcome = Outcome(rawValue: stateText == "working" ? "work" : stateText)
            else { continue }
            var conditions: [Condition] = []
            if let b = r["bundleId"] as? String { conditions.append(Condition(.bundleId, .equals, b)) }
            if let seg = r["equalsSegment"] as? String {
                conditions.append(Condition(.title, .titleSegment, seg))
            } else if let c = r["contains"] as? String {
                conditions.append(Condition(.title, .contains, c))
            }
            add((r["note"] as? String) ?? "title rule", conditions, outcome)
        }
        for r in (root["workspaceRules"] as? [[String: Any]]) ?? [] {
            guard let stateText = r["state"] as? String,
                  let outcome = Outcome(rawValue: stateText == "working" ? "work" : stateText)
            else { continue }
            var conditions: [Condition] = []
            if let b = r["bundleId"] as? String { conditions.append(Condition(.bundleId, .equals, b)) }
            if let e = r["equals"] as? String { conditions.append(Condition(.workspace, .equals, e)) }
            else if let c = r["contains"] as? String { conditions.append(Condition(.workspace, .contains, c)) }
            add((r["note"] as? String) ?? "workspace rule", conditions, outcome)
        }
        return set
    }

    // MARK: - Segments to observations

    /// Rebuilds a snapshot from what WorkClock recorded about a stretch.
    public static func snapshot(from s: LegacySegment, projectIndex: [String: String]) -> Snapshot? {
        // "linear.app · Work" - host, then container or space.
        let parts = s.detail.components(separatedBy: " · ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if s.contextKey.hasPrefix("web:") {
            let host = String(s.contextKey.dropFirst(4))
            guard host != "unknown" else { return nil }
            return Snapshot(bundleId: "app.zen-browser.zen", appName: s.app,
                            url: "https://\(host)/", host: host, urlPath: "/",
                            browserProfile: parts.count > 1 ? parts[1] : nil)
        }
        if s.contextKey.hasPrefix("editor:") {
            let name = String(s.contextKey.dropFirst(7))
            guard name != "none" else { return nil }
            return Snapshot(bundleId: "com.microsoft.VSCode", appName: s.app,
                            projectName: name, projectPath: projectIndex[name])
        }
        if s.contextKey.hasPrefix("app:") {
            let rest = String(s.contextKey.dropFirst(4))
            if let hash = rest.firstIndex(of: "#") {
                let bundle = String(rest[rest.startIndex..<hash])
                let workspace = String(rest[rest.index(after: hash)...])
                guard workspace != "unreadable" else {
                    return Snapshot(bundleId: bundle, appName: s.app)
                }
                return Snapshot(bundleId: bundle, appName: s.app, workspace: workspace)
            }
            return Snapshot(bundleId: rest, appName: s.app,
                            windowTitle: parts.count > 1 ? parts[1] : nil)
        }
        return nil
    }

    /// Converts one day's legacy file. `existing` spans are left untouched, so
    /// a day the new tracker already covers is never double counted.
    public static func convert(segments: [LegacySegment], projectIndex: [String: String],
                               existing: [ObservationSpan]) -> (obs: [ObservationSpan],
                                                                presence: PresenceLog,
                                                                skipped: Int) {
        var obs: [ObservationSpan] = []
        var presence = PresenceLog()
        var skipped = 0

        for s in segments where s.end > s.start {
            let span = Span(s.start, s.end)
            if existing.contains(where: { Span($0.start, $0.end).overlaps(span) }) {
                skipped += 1
                continue
            }
            if s.state == "idle" {
                // Recorded as absence, not as silence, so the new idle
                // threshold cannot re-decide time the old tracker already judged.
                presence.absent.append(span)
                continue
            }
            guard s.state == "working" || s.state == "personal" || s.state == "unknown" else { continue }
            guard let snap = snapshot(from: s, projectIndex: projectIndex) else { continue }
            obs.append(ObservationSpan(start: s.start, end: s.end, snapshot: snap))
            presence.input.append(span)
        }
        presence.normalise(tolerance: 1)
        return (obs, presence, skipped)
    }

    // MARK: - Driver

    public static func run(sourceRoot: URL, configURL: URL, store: Store,
                           projectIndex: [String: String],
                           fm: FileManager = .default) -> Result {
        var result = Result()

        if let data = try? Data(contentsOf: configURL) {
            let translated = rules(fromConfig: data)
            if !translated.rules.isEmpty {
                var merged = store.loadRules() ?? RuleSet()
                for r in translated.rules where !merged.rules.contains(where: {
                    $0.conditions == r.conditions && $0.outcome == r.outcome
                }) {
                    merged.insertBySpecificity(r)
                }
                store.save(merged)
                result.rules = translated.rules.count
            }
        }

        guard let files = try? fm.contentsOfDirectory(atPath: sourceRoot.path) else { return result }
        for file in files.sorted() where file.hasPrefix("segments-") && file.hasSuffix(".jsonl") {
            let day = String(file.dropFirst("segments-".count).dropLast(".jsonl".count))
            guard let text = try? String(contentsOf: sourceRoot.appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            let segments = text.split(separator: "\n").compactMap { line -> LegacySegment? in
                guard let d = line.data(using: .utf8) else { return nil }
                return try? legacyDecoder.decode(LegacySegment.self, from: d)
            }
            guard !segments.isEmpty else { continue }

            let day0 = store.load(day: day)
            let (obs, presence, skipped) = convert(segments: segments,
                                                   projectIndex: projectIndex,
                                                   existing: day0.observations)
            result.skippedOverlapping += skipped
            guard !obs.isEmpty || !presence.absent.isEmpty else { continue }

            for o in obs { store.append(o) }
            var combined = day0.presence
            combined.input.append(contentsOf: presence.input)
            combined.absent.append(contentsOf: presence.absent)
            combined.normalise(tolerance: 1)
            store.savePresence(combined, day: day)

            result.days += 1
            result.observations += obs.count
            result.imported += obs.reduce(0) { $0 + $1.duration }
        }
        return result
    }
}
