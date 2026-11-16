import Foundation

/// A phone entry waiting in the shared folder's `inbox` for the Mac.
public struct PhoneDelivery: Codable, Equatable, Sendable {
    public var fileName: String
    public var description: String
    public var queuedAt: Date

    public init(fileName: String, description: String, queuedAt: Date) {
        self.fileName = fileName; self.description = description; self.queuedAt = queuedAt
    }
}

/// What the phone tells the user about entries it has pushed.
///
/// The inbox has one writer per file, so the phone cannot be told "applied" by
/// the Mac. It infers it: the Mac removes a file once it has taken it, and a
/// file that is still there well after the Mac's check interval means the Mac
/// is off, offline, or rejected it.
public enum PhoneDeliveries {
    public enum State: Equatable, Sendable {
        case waiting(String)
        case delivered(String)
        case stalled(String)
    }

    /// How often the Mac looks in the inbox.
    public static let macCheckInterval: TimeInterval = 300
    /// Two checks plus time for the shared folder to sync.
    public static let stallAfter: TimeInterval = 600

    /// Splits `pending` into what the Mac has taken and what is still waiting.
    /// `present` is the inbox listing; callers must not call this when the
    /// listing failed, or every entry would look delivered.
    public static func resolve(_ pending: [PhoneDelivery], present: Set<String>,
                               now: Date = Date())
        -> (remaining: [PhoneDelivery], state: State?)
    {
        let remaining = pending.filter { present.contains($0.fileName) }
        let delivered = pending.filter { !present.contains($0.fileName) }

        if let oldest = remaining.map(\.queuedAt).min() {
            let what = summary(remaining)
            if now.timeIntervalSince(oldest) >= stallAfter {
                let minutes = Int(stallAfter / 60)
                return (remaining, .stalled(
                    "Your Mac has not picked up \(what) after \(minutes) minutes. "
                    + "Open Sundial on your Mac and check it uses this same shared folder."))
            }
            return (remaining, .waiting(
                "Pushed \(what) to the shared folder. Your Mac adds it within "
                + "\(Int(macCheckInterval / 60)) minutes."))
        }
        guard !delivered.isEmpty else { return ([], nil) }
        return ([], .delivered("Added \(summary(delivered)) to your Mac."))
    }

    private static func summary(_ entries: [PhoneDelivery]) -> String {
        entries.count == 1 ? entries[0].description : "\(entries.count) entries"
    }
}
