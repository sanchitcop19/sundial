import Foundation

/// The Claude desktop app shows no account in its window or accessibility
/// tree, but records the signed-in account in its config file. Only that one
/// key is read: the same file holds credential caches, which are never kept.
public enum ClaudeDesktop {
    public static let bundleId = "com.anthropic.claudefordesktop"

    public static func configURL(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/config.json")
    }

    /// A short, stable tag for the signed-in account, used as the snapshot's
    /// workspace so rules can tell a work login from a personal one. The first
    /// block of the account UUID is unique among one person's accounts and
    /// reads better in the timeline than the whole thing.
    public static func accountTag(fromConfig data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["lastKnownAccountUuid"] as? String,
              let uuid = UUID(uuidString: raw) else { return nil }
        return String(uuid.uuidString.lowercased().prefix(8))
    }
}
