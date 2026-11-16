import Foundation

/// Reserve a start before contacting Apple: a timeout or a Mac restart must not
/// turn an already-delivered request into a second Live Activity.
final class LiveActivityStartLedger {
    struct Entry: Codable {
        var day: String
        var requestID: String
        var expiresAt: Date
        var nextAttemptAt: Date
    }

    private let file: URL
    private var entries: [String: Entry]?

    init(file: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sundial/live-activity-starts.json")) {
        self.file = file
    }

    func entry(for deviceID: String) throws -> Entry? {
        try load()
        return entries?[deviceID]
    }

    func save(_ entry: Entry, for deviceID: String) throws {
        try load()
        var updated = entries ?? [:]
        updated[deviceID] = entry
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        entries = updated
    }

    /// Only call after Apple accepts an update to this activity. A stale cloud
    /// file must not create a new reservation, or replace an unconfirmed start.
    func rememberObservedActivity(day: String, requestID: String, expiresAt: Date,
                                  for deviceID: String, at now: Date) throws {
        let saved = try entry(for: deviceID)
        if let saved, saved.nextAttemptAt > now, saved.requestID != requestID { return }
        guard (saved?.expiresAt ?? .distantPast) < expiresAt
            || (saved?.nextAttemptAt ?? .distantPast) < expiresAt else { return }
        try save(.init(day: day, requestID: requestID, expiresAt: expiresAt,
                       nextAttemptAt: expiresAt), for: deviceID)
    }

    private func load() throws {
        guard entries == nil else { return }
        guard FileManager.default.fileExists(atPath: file.path) else {
            entries = [:]
            return
        }
        // A damaged ledger needs attention; treating it as empty could duplicate
        // starts that Apple already accepted.
        entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
    }
}
