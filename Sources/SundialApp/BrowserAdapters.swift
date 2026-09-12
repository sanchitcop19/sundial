import AppKit
import SundialCore

struct BrowserReading {
    var url: String?
    var title: String?
    var profile: String?
    /// Set when the browser is known but could not be read, so the reason can
    /// be shown rather than the time silently misfiled.
    var problem: String?
}

/// Reads the active tab from whichever browser is in front.
///
/// Three families, three mechanisms: Chromium and WebKit browsers answer over
/// Apple Events; Firefox forks have no scripting interface, so their session
/// store is read and reconciled against the live window title.
final class BrowserReader {
    private var firefoxReaders: [String: FirefoxSessionReader] = [:]
    private var chromiumProfileNames: [String: [String]] = [:]
    private var profileCache: [pid_t: (name: String?, at: Date)] = [:]
    private var scriptCache: [String: NSAppleScript] = [:]
    private let profileTTL: TimeInterval = 15

    static let chromiumSupportFolders: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "com.operasoftware.Opera",
    ]

    static func isBrowser(_ bundleId: String) -> Bool {
        Catalogue.browsers[bundleId] != nil
    }

    // MARK: - Profiles

    /// Chromium browsers list their profiles, with display names, in Local TimeCategory.
    func chromiumProfiles(_ bundleId: String) -> [String] {
        if let c = chromiumProfileNames[bundleId] { return c }
        guard let folder = BrowserReader.chromiumSupportFolders[bundleId] else { return [] }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(folder)/Local TimeCategory")
        var names: [String] = []
        if let d = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let profile = root["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            for (_, v) in cache {
                if let info = v as? [String: Any], let n = info["name"] as? String, !n.isEmpty {
                    names.append(n)
                }
            }
        }
        names.sort()
        chromiumProfileNames[bundleId] = names
        return names
    }

    func firefoxContainers(_ bundleId: String) -> [String] {
        reader(for: bundleId)?.knownContainers() ?? []
    }

    private func reader(for bundleId: String) -> FirefoxSessionReader? {
        guard let folder = FirefoxFamily.profiles[bundleId] else { return nil }
        if let r = firefoxReaders[bundleId] { return r }
        let r = FirefoxSessionReader(folderName: folder)
        firefoxReaders[bundleId] = r
        return r
    }

    // MARK: - Reading

    func read(app: NSRunningApplication, windowTitle: String?) -> BrowserReading? {
        guard let bundleId = app.bundleIdentifier,
              let entry = Catalogue.browsers[bundleId] else { return nil }

        switch entry.engine {
        case .firefox:
            guard let r = reader(for: bundleId) else { return nil }
            // The address bar is live; the session store is up to ~15s behind.
            let liveURL = Signals.liveURL(pid: app.processIdentifier)
            let tab = r.activeTab(liveTitle: windowTitle)

            if let liveURL {
                // Name the container from whichever recorded tab is on the same
                // site, rather than trusting a possibly stale selection.
                let host = URLComponents(string: liveURL)?.host
                let match = r.session()?.tabs
                    .filter { host != nil && URLComponents(string: $0.url)?.host == host }
                    .max { $0.lastAccessed < $1.lastAccessed }
                    ?? (tab.flatMap { URLComponents(string: $0.url)?.host == host ? $0 : nil })
                return BrowserReading(url: liveURL,
                                      title: match?.title ?? windowTitle,
                                      profile: match?.container ?? match?.space)
            }

            guard let tab else {
                return BrowserReading(title: windowTitle, problem: r.lastError
                                      ?? "could not read the \(entry.name) session store")
            }
            // A container is the browser's own work/personal split; a Zen space
            // is the same idea one level up, so it stands in when unset.
            return BrowserReading(url: tab.url, title: tab.title.isEmpty ? windowTitle : tab.title,
                                  profile: tab.container ?? tab.space)

        case .chromium, .webkit:
            let pid = app.processIdentifier
            // The address bar needs only the Accessibility permission the app
            // already has; Apple Events need a second, separate consent that
            // people often decline. So read it directly first.
            if let live = Signals.liveURL(pid: pid) {
                return BrowserReading(url: live, title: windowTitle,
                                      profile: cachedProfile(pid: pid, bundleId: bundleId))
            }
            let (url, title, err) = appleScriptTab(bundleId: bundleId, engine: entry.engine)
            if url == nil, let err { return BrowserReading(title: windowTitle, problem: err) }
            return BrowserReading(url: url, title: title ?? windowTitle,
                                  profile: cachedProfile(pid: pid, bundleId: bundleId))
        }
    }

    /// Chromium exposes no scripting hook for the window's profile, so it is
    /// read off the toolbar. Cached briefly: people switch profile rarely, and
    /// a window belongs to one profile for its whole life.
    private func cachedProfile(pid: pid_t, bundleId: String) -> String? {
        guard Catalogue.browsers[bundleId]?.engine == .chromium else { return nil }
        if let c = profileCache[pid], Date().timeIntervalSince(c.at) < profileTTL { return c.name }
        let name = Signals.chromiumProfile(pid: pid)
        profileCache[pid] = (name, Date())
        return name
    }

    private func appleScriptTab(bundleId: String,
                                engine: DetectedBrowser.Engine) -> (String?, String?, String?) {
        let source: String
        if engine == .webkit {
            source = """
            tell application id "\(bundleId)"
                if (count of windows) = 0 then return ""
                set t to current tab of front window
                return (URL of t as string) & linefeed & (name of t as string)
            end tell
            """
        } else {
            source = """
            tell application id "\(bundleId)"
                if (count of windows) = 0 then return ""
                set t to active tab of front window
                return (URL of t as string) & linefeed & (title of t as string)
            end tell
            """
        }

        let script: NSAppleScript
        if let cached = scriptCache[bundleId] { script = cached }
        else if let s = NSAppleScript(source: source) { script = s; scriptCache[bundleId] = s }
        else { return (nil, nil, "could not build the query script") }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743: the user has not granted Automation access for this app.
            if code == -1743 {
                return (nil, nil, "not allowed to read tabs. Grant access under "
                        + "Privacy & Security › Automation.")
            }
            // -600/-609: the browser has no windows or just quit; not an error.
            if code == -600 || code == -609 || code == -1728 { return (nil, nil, nil) }
            return (nil, nil, (error[NSAppleScript.errorMessage] as? String) ?? "script error \(code)")
        }
        let text = result.stringValue ?? ""
        guard !text.isEmpty else { return (nil, nil, nil) }
        let parts = text.components(separatedBy: "\n")
        let url = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        let title = parts.count > 1 ? parts[1] : nil
        return (url, title, nil)
    }
}
