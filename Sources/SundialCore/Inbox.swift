import Foundation

/// The phone-to-Mac channel.
///
/// The mirror is written by the Mac and would overwrite anything the phone put
/// there, so the phone drops small files into an `inbox` folder instead and the
/// Mac drains it. One writer per file, no shared mutable state, nothing to
/// conflict.
public enum Inbox {
    public struct Result: Sendable, Equatable {
        public var rulesAdded = 0
        public var sessionsAdded = 0
        public var sessionSeconds: TimeInterval = 0
        public var failed = 0

        public init(rulesAdded: Int = 0, sessionsAdded: Int = 0,
                    sessionSeconds: TimeInterval = 0, failed: Int = 0) {
            self.rulesAdded = rulesAdded; self.sessionsAdded = sessionsAdded
            self.sessionSeconds = sessionSeconds; self.failed = failed
        }
    }

    public static func directory(in folder: URL) -> URL {
        folder.appendingPathComponent("inbox")
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let v = full.date(from: text) { return v }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let v = plain.date(from: text) { return v }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "bad date \(text)")
        }
        return d
    }

    /// Applies everything waiting and removes what it applied. A file that
    /// cannot be read is left alone and counted, so a bad drop is visible
    /// rather than silently discarded or retried forever.
    @discardableResult
    public static func drain(from folder: URL, into store: Store, rules: inout RuleSet,
                             fm: FileManager = .default) -> Result {
        var result = Result()
        let dir = directory(in: folder)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return result }
        let dec = decoder

        for name in names.sorted() {
            let file = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }

            if name.hasPrefix("rule-"), let rule = try? dec.decode(Rule.self, from: data) {
                if !rules.rules.contains(where: { $0.id == rule.id }) {
                    rules.insertBySpecificity(rule)
                    result.rulesAdded += 1
                }
                try? fm.removeItem(at: file)

            } else if name.hasPrefix("session-"),
                      let span = try? dec.decode(ObservationSpan.self, from: data) {
                if span.duration >= 1 {
                    store.append(span)
                    // A session the user started is time they were present for,
                    // so it is recorded as input rather than left to the idle rule.
                    let day = Format.day(span.start)
                    var presence = store.load(day: day).presence
                    presence.input.append(Span(span.start, span.end))
                    presence.normalise()
                    store.savePresence(presence, day: day)
                    result.sessionsAdded += 1
                    result.sessionSeconds += span.duration
                }
                try? fm.removeItem(at: file)

            } else {
                result.failed += 1
            }
        }
        return result
    }
}
