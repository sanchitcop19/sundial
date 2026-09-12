import Foundation
import Compression

/// Reads the active tab out of a Firefox-family browser.
///
/// Firefox and its forks expose no scripting interface for the current tab, so
/// the session store is read instead. It lags a tab switch by up to ~15s, which
/// the caller closes by matching the live window title against the tab list.
public enum FirefoxFamily {
    /// bundle identifier -> Application Support folder name.
    public static let profiles: [String: String] = [
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "app.zen-browser.zen": "zen",
        "io.gitlab.librewolf": "librewolf",
        "net.waterfox.waterfox": "Waterfox",
        "org.mozilla.floorp": "Floorp",
    ]

    public static func isFirefoxFamily(_ bundleId: String) -> Bool { profiles[bundleId] != nil }
}

public struct BrowserTab: Sendable, Equatable {
    public var title: String
    public var url: String
    /// Container name (Firefox) - the work/personal split for these browsers.
    public var container: String?
    /// Zen calls its container-bound workspaces "spaces".
    public var space: String?
    public var lastAccessed: Double

    public init(title: String, url: String, container: String? = nil,
                space: String? = nil, lastAccessed: Double = 0) {
        self.title = title; self.url = url; self.container = container
        self.space = space; self.lastAccessed = lastAccessed
    }
}

public enum MozLZ4 {
    public enum Failure: Error, Equatable { case badMagic, badHeader, decodeFailed }

    /// `mozLz40\0` + 4-byte little-endian size + a raw LZ4 block.
    public static func decompress(_ raw: Data) throws -> Data {
        guard raw.count > 12 else { throw Failure.badHeader }
        guard raw.prefix(8) == Data("mozLz40\0".utf8) else { throw Failure.badMagic }
        let size = raw.subdata(in: 8..<12).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard size > 0, size < 512_000_000 else { throw Failure.badHeader }
        let payload = raw.subdata(in: 12..<raw.count)
        var out = Data(count: Int(size))
        let n = out.withUnsafeMutableBytes { dst -> Int in
            payload.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, Int(size), s, payload.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard n > 0 else { throw Failure.decodeFailed }
        return out.prefix(n)
    }
}

public struct FirefoxSession: Sendable, Equatable {
    public var tabs: [BrowserTab]
    public var selected: BrowserTab?

    /// The live window title identifies the current tab even when the session
    /// store has not been flushed since the last switch.
    public func tab(matchingTitle title: String) -> BrowserTab? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let exact = tabs.filter { $0.title == t }
        if !exact.isEmpty { return exact.max { $0.lastAccessed < $1.lastAccessed } }
        let loose = tabs.filter { !$0.title.isEmpty && ($0.title.hasPrefix(t) || t.hasPrefix($0.title)) }
        return loose.max { $0.lastAccessed < $1.lastAccessed }
    }

    public static func parseContainers(_ data: Data) -> [Int: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = root["identities"] as? [[String: Any]] else { return [:] }
        var out: [Int: String] = [:]
        for i in ids {
            guard let id = i["userContextId"] as? Int, (i["public"] as? Bool) == true,
                  let name = i["name"] as? String else { continue }
            out[id] = name
        }
        return out
    }

    public static func parse(_ data: Data, containers: [Int: String]) -> FirefoxSession? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]], !windows.isEmpty else { return nil }
        let idx = (root["selectedWindow"] as? Int).map { $0 - 1 } ?? 0
        let window = windows.indices.contains(idx) ? windows[idx] : windows[0]

        // Zen spaces map a workspace uuid to a name and a default container.
        var spaces: [String: String] = [:]
        for s in (window["spaces"] as? [[String: Any]]) ?? [] {
            if let uuid = s["uuid"] as? String, let name = s["name"] as? String { spaces[uuid] = name }
        }

        var tabs: [BrowserTab] = []
        for t in (window["tabs"] as? [[String: Any]]) ?? [] {
            guard let entries = t["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
            let i = min(max((t["index"] as? Int) ?? entries.count, 1), entries.count)
            let e = entries[i - 1]
            let ctx = (t["userContextId"] as? Int) ?? 0
            tabs.append(BrowserTab(
                title: (e["title"] as? String) ?? "",
                url: (e["url"] as? String) ?? "",
                container: containers[ctx],
                space: (t["zenWorkspace"] as? String).flatMap { spaces[$0] },
                lastAccessed: (t["lastAccessed"] as? Double) ?? 0))
        }
        var selected: BrowserTab?
        if let s = window["selected"] as? Int, tabs.indices.contains(s - 1) { selected = tabs[s - 1] }
        return FirefoxSession(tabs: tabs, selected: selected)
    }
}

/// Locates and caches a Firefox-family session store.
public final class FirefoxSessionReader {
    private let supportDir: URL
    private var cached: FirefoxSession?
    private var stamp: (path: String, mtime: Date, size: Int)?
    private var containers: [Int: String] = [:]
    private var containersFrom: URL?
    public private(set) var lastError: String?

    public init(folderName: String,
                home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        supportDir = home.appendingPathComponent("Library/Application Support/\(folderName)")
    }

    private func candidates() -> [URL] {
        let fm = FileManager.default
        let profiles = supportDir.appendingPathComponent("Profiles")
        guard let dirs = try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else { return [] }
        var found: [(URL, Date)] = []
        for d in dirs {
            for name in ["recovery.jsonlz4", "recovery.baklz4"] {
                let f = d.appendingPathComponent("sessionstore-backups").appendingPathComponent(name)
                if let a = try? fm.attributesOfItem(atPath: f.path),
                   let m = a[.modificationDate] as? Date { found.append((f, m)) }
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public func session() -> FirefoxSession? {
        let fm = FileManager.default
        for file in candidates() {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else { continue }
            if let s = stamp, s.path == file.path, s.mtime == mtime, s.size == size,
               let cached { return cached }

            let profile = file.deletingLastPathComponent().deletingLastPathComponent()
            let cfile = profile.appendingPathComponent("containers.json")
            if containersFrom != cfile || containers.isEmpty,
               let d = try? Data(contentsOf: cfile) {
                containers = FirefoxSession.parseContainers(d)
                containersFrom = cfile
            }
            guard let raw = try? Data(contentsOf: file),
                  let plain = try? MozLZ4.decompress(raw),
                  let parsed = FirefoxSession.parse(plain, containers: containers) else { continue }
            cached = parsed
            stamp = (file.path, mtime, size)
            lastError = nil
            return parsed
        }
        if cached == nil { lastError = "no readable session store under \(supportDir.path)" }
        return cached
    }

    /// The container names configured in this browser, for the setup wizard.
    public func knownContainers() -> [String] {
        _ = session()
        return containers.values.sorted()
    }

    public func activeTab(liveTitle: String?) -> BrowserTab? {
        guard let s = session() else { return nil }
        if let t = liveTitle, let m = s.tab(matchingTitle: t) { return m }
        return s.selected
    }
}
