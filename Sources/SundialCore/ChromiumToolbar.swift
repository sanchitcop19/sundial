import Foundation

/// Works out which toolbar button is the profile chip.
///
/// Chromium keeps its profile list in `Local State`, which macOS puts behind
/// Full Disk Access - too large an ask for a time tracker. The same name is on
/// the toolbar chip, reachable with the Accessibility permission the app
/// already needs. Identifying it is a heuristic, so it lives here where it can
/// be tested against real toolbar layouts.
public enum ChromiumToolbar {
    /// One accessibility button, as read off the toolbar.
    public struct Button: Sendable, Equatable {
        public var depth: Int
        public var description: String
        public var roleDescription: String

        public init(depth: Int, description: String, roleDescription: String = "button") {
            self.depth = depth; self.description = description
            self.roleDescription = roleDescription
        }
    }

    /// Buttons every Chromium browser ships. Anything else in the navigation
    /// row is the profile.
    public static let commands: Set<String> = [
        "new tab", "back", "forward", "reload", "stop", "home", "search",
        "open tab in split view", "bookmark this tab", "bookmark this page",
        "extensions", "tab search", "search tabs", "view site information",
        "downloads", "chrome", "you", "share", "cast", "translate", "zoom",
        "customize and control google chrome", "media controls", "google lens",
        "save and fill", "show side panel", "side panel", "bookmarks",
        "reading list", "history", "all bookmarks", "menu containing hidden bookmarks",
        "open gemini in chrome", "profile", "add", "close", "minimize",
        "maximize", "full screen", "print", "find", "settings",
    ]

    /// Buttons arrive in traversal order. Scanning stops at the bookmarks bar,
    /// and only a button sharing a row with back/forward/reload is trusted, so
    /// a stray control elsewhere in the window is never mistaken for a profile.
    public static func profileName(from buttons: [Button]) -> String? {
        var navDepth: Int?
        var candidates: [Button] = []
        for b in buttons {
            if b.roleDescription.lowercased().contains("bookmark") { break }
            let key = b.description.lowercased()
            if ["back", "forward", "reload"].contains(key) { navDepth = b.depth }
            guard !b.description.isEmpty, b.description.count < 60,
                  !commands.contains(key), !b.description.contains("://") else { continue }
            candidates.append(b)
        }
        guard let navDepth else { return nil }
        return candidates.first { $0.depth == navDepth }?.description
    }
}
