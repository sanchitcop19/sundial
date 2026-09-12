import Foundation

/// A browser found on this Mac, with whatever identity split it offers.
public struct DetectedBrowser: Sendable, Equatable, Identifiable {
    public enum Engine: String, Sendable { case chromium, webkit, firefox }
    public var id: String { bundleId }
    public var bundleId: String
    public var name: String
    public var engine: Engine
    /// Chrome/Edge profiles, or Firefox/Zen containers: the usual place people
    /// already keep work and personal apart.
    public var identities: [String]

    public init(bundleId: String, name: String, engine: Engine, identities: [String] = []) {
        self.bundleId = bundleId; self.name = name; self.engine = engine; self.identities = identities
    }
}

/// A folder holding several git repositories - a likely home for code.
public struct DetectedCodeRoot: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var repoCount: Int
    public var display: String { (path as NSString).abbreviatingWithTildeInPath }

    public init(path: String, repoCount: Int) { self.path = path; self.repoCount = repoCount }
}

public struct DetectedApp: Sendable, Equatable, Identifiable {
    public var id: String { bundleId }
    public var bundleId: String
    public var name: String
    /// What the catalogue expects this app is usually for, as a starting point.
    public var suggested: Outcome?

    public init(bundleId: String, name: String, suggested: Outcome? = nil) {
        self.bundleId = bundleId; self.name = name; self.suggested = suggested
    }
}

public struct Environment: Sendable, Equatable {
    public var browsers: [DetectedBrowser]
    public var codeRoots: [DetectedCodeRoot]
    public var apps: [DetectedApp]

    public init(browsers: [DetectedBrowser] = [], codeRoots: [DetectedCodeRoot] = [],
                apps: [DetectedApp] = []) {
        self.browsers = browsers; self.codeRoots = codeRoots; self.apps = apps
    }
}

/// Opinions about common apps, used only to pre-tick boxes during setup.
/// Everything here is a suggestion the user can override; nothing is enforced.
public enum Catalogue {
    public static let browsers: [String: (name: String, engine: DetectedBrowser.Engine)] = [
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.google.Chrome.beta": ("Chrome Beta", .chromium),
        "com.brave.Browser": ("Brave", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "company.thebrowser.dia": ("Dia", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.operasoftware.Opera": ("Opera", .chromium),
        "com.apple.Safari": ("Safari", .webkit),
        "org.mozilla.firefox": ("Firefox", .firefox),
        "app.zen-browser.zen": ("Zen", .firefox),
        "io.gitlab.librewolf": ("LibreWolf", .firefox),
        "net.waterfox.waterfox": ("Waterfox", .firefox),
        "org.mozilla.floorp": ("Floorp", .firefox),
    ]

    /// Apps most people use for one purpose or the other. Communication tools
    /// lean work; media and games lean personal.
    public static let appHints: [String: Outcome] = [
        "com.tinyspeck.slackmacgap": .work,
        "com.microsoft.teams2": .work,
        "us.zoom.xos": .work,
        "com.linear": .work,
        "com.atlassian.jira": .work,
        "com.figma.Desktop": .work,
        "com.postmanlabs.mac": .work,
        // Editors and terminals are deliberately absent: the same app is used
        // for work and for side projects, so they are judged by which project
        // is open, never by the app itself.
        "com.spotify.client": .personal,
        "com.apple.Music": .personal,
        "com.hnc.Discord": .personal,
        "net.whatsapp.WhatsApp": .personal,
        "com.apple.MobileSMS": .personal,
        "com.valvesoftware.steam": .personal,
        "com.apple.Photos": .personal,
        "com.netflix.Netflix": .personal,
        "com.apple.TV": .personal,
    ]

    /// Sites that are leisure for almost everyone. Kept short on purpose: a
    /// wrong guess is worse than an honest "unclassified" the user can fix.
    public static let personalSites = [
        "netflix.com", "youtube.com", "reddit.com", "instagram.com", "tiktok.com",
        "twitch.tv", "hulu.com", "disneyplus.com", "spotify.com", "primevideo.com",
        "facebook.com", "pinterest.com", "ebay.com",
    ]

    /// Editors and terminals, where the open project decides the verdict
    /// rather than the app. Used to keep a project name from the title even
    /// when it cannot be resolved to a folder on disk.
    public static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",          // Cursor
        "com.visualstudio.code.oss", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "io.alacritty",
    ]

    /// Apps whose active account or workspace can be read out of the
    /// accessibility tree, keyed by the label that precedes it.
    public static let workspaceProbes: [String: String] = [
        "notion.id": "Switch workspace: ",
    ]

    /// Folders people keep code in.
    public static let codeRootCandidates = [
        "repos", "code", "src", "dev", "Developer", "Projects", "projects",
        "work", "git", "GitHub", "Documents/GitHub", "Documents/code", "Sites",
    ]
}

public enum EnvironmentScanner {
    /// `installedApps` comes from the app layer so the core stays UI-free.
    public static func scan(installedApps: [(bundleId: String, name: String)],
                            home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                            fm: FileManager = .default,
                            firefoxContainers: (String) -> [String] = { _ in [] },
                            chromiumProfiles: (String) -> [String] = { _ in [] }) -> Environment {
        var browsers: [DetectedBrowser] = []
        var apps: [DetectedApp] = []

        for app in installedApps {
            if let b = Catalogue.browsers[app.bundleId] {
                let identities: [String]
                switch b.engine {
                case .firefox:  identities = firefoxContainers(app.bundleId)
                case .chromium: identities = chromiumProfiles(app.bundleId)
                case .webkit:   identities = []
                }
                browsers.append(DetectedBrowser(bundleId: app.bundleId, name: b.name,
                                                engine: b.engine, identities: identities))
            } else {
                apps.append(DetectedApp(bundleId: app.bundleId, name: app.name,
                                        suggested: Catalogue.appHints[app.bundleId]))
            }
        }

        return Environment(browsers: browsers.sorted { $0.name < $1.name },
                           codeRoots: codeRoots(home: home, fm: fm),
                           apps: apps.sorted { $0.name < $1.name })
    }

    /// Folders directly containing git repositories, busiest first.
    public static func codeRoots(home: URL, fm: FileManager = .default) -> [DetectedCodeRoot] {
        var found: [DetectedCodeRoot] = []
        for candidate in Catalogue.codeRootCandidates {
            let root = home.appendingPathComponent(candidate)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let kids = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            var count = 0
            for k in kids where !k.hasPrefix(".") {
                let git = root.appendingPathComponent(k).appendingPathComponent(".git")
                if fm.fileExists(atPath: git.path) { count += 1 }
            }
            if count > 0 { found.append(DetectedCodeRoot(path: root.path, repoCount: count)) }
        }
        return found.sorted { $0.repoCount > $1.repoCount }
    }
}

/// What the user told the setup wizard.
public struct SetupChoices: Sendable, Equatable {
    /// Company domains, e.g. "acme.com". Everything on them counts as work.
    public var workDomains: [String] = []
    /// Browser identities that mean work: (bundleId, profile or container).
    public var workBrowserIdentities: [[String]] = []
    /// Folders whose contents are work.
    public var workCodeRoots: [String] = []
    /// Folders whose contents are explicitly not work.
    public var personalCodeRoots: [String] = []
    public var workApps: [String] = []
    public var personalApps: [String] = []
    public var includePersonalSites = true

    public init() {}
}

public enum StarterRules {
    /// Turns setup answers into an ordered rule set.
    public static func build(_ c: SetupChoices) -> RuleSet {
        var set = RuleSet()
        func add(_ name: String, _ conditions: [Condition], _ outcome: Outcome) {
            set.insertBySpecificity(Rule(name: name, conditions: conditions,
                                         outcome: outcome, origin: .setup))
        }

        for domain in c.workDomains where !domain.isEmpty {
            let clean = domain.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard !clean.isEmpty else { continue }
            add("Company site \(clean)", [Condition(.host, .hostOrSubdomain, clean)], .work)
        }

        for pair in c.workBrowserIdentities where pair.count == 2 {
            add("\(pair[1]) browser profile",
                [Condition(.bundleId, .equals, pair[0]),
                 Condition(.browserProfile, .equals, pair[1])], .work)
        }

        for root in c.workCodeRoots where !root.isEmpty {
            add("Code in \((root as NSString).abbreviatingWithTildeInPath)",
                [Condition(.projectPath, .pathUnder, root)], .work)
        }
        for root in c.personalCodeRoots where !root.isEmpty {
            add("Code in \((root as NSString).abbreviatingWithTildeInPath)",
                [Condition(.projectPath, .pathUnder, root)], .personal)
        }

        for bundle in c.workApps {
            add(name(for: bundle), [Condition(.bundleId, .equals, bundle)], .work)
        }
        for bundle in c.personalApps {
            add(name(for: bundle), [Condition(.bundleId, .equals, bundle)], .personal)
        }

        if c.includePersonalSites {
            for site in Catalogue.personalSites {
                add(site, [Condition(.host, .hostOrSubdomain, site)], .personal)
            }
        }
        return set
    }

    private static func name(for bundleId: String) -> String {
        bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }
}
