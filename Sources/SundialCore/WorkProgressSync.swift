import Foundation

/// Keep changed progress timely, with a heartbeat before unchanged totals become stale.
public enum WorkProgressSync {
    public static let heartbeatInterval: TimeInterval = 180

    public static func shouldPublish(_ snapshot: WorkProgressSnapshot,
                                     replacing previous: WorkProgressSnapshot?) -> Bool {
        guard var previous else { return true }
        let elapsed = snapshot.updatedAt - previous.updatedAt
        previous.updatedAt = snapshot.updatedAt
        return snapshot != previous || elapsed >= heartbeatInterval || elapsed < 0
    }

    /// Compare against disk so app restarts and missing or damaged cloud files recover safely.
    @discardableResult
    public static func writeSummary(_ snapshot: WorkProgressSnapshot, to file: URL) throws -> Bool {
        guard shouldPublish(snapshot, replacing: readSummary(at: file)) else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        return true
    }

    private static func readSummary(at file: URL) -> WorkProgressSnapshot? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8192,
              let data = try? Data(contentsOf: file), data.count < 8192,
              let snapshot = try? JSONDecoder().decode(WorkProgressSnapshot.self, from: data),
              snapshot.isValid else { return nil }
        return snapshot
    }
}
