import Foundation

/// Copies exports into a cloud-synced folder.
///
/// A copy rather than a symlink: the CSV is written with an atomic replace,
/// which swaps the inode and would silently destroy a symlink left at the path.
public enum CloudMirror {
    public static let tokens = ["icloud", "dropbox", "gdrive", "onedrive"]

    public static func label(_ token: String) -> String {
        switch token.lowercased() {
        case "icloud":   return "iCloud Drive"
        case "dropbox":  return "Dropbox"
        case "gdrive":   return "Google Drive"
        case "onedrive": return "OneDrive"
        default:         return token
        }
    }

    public static func resolve(_ token: String, home: URL,
                               fm: FileManager = .default) -> URL? {
        func dir(_ u: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
        }
        func cloudStorage(prefix: String, suffix: String?) -> URL? {
            let cloud = home.appendingPathComponent("Library/CloudStorage")
            guard let kids = try? fm.contentsOfDirectory(atPath: cloud.path) else { return nil }
            guard let match = kids.filter({ $0.hasPrefix(prefix) }).sorted().first else { return nil }
            let base = cloud.appendingPathComponent(match)
            if let suffix {
                let inner = base.appendingPathComponent(suffix)
                if dir(inner) { return inner }
            }
            return dir(base) ? base : nil
        }

        switch token.lowercased() {
        case "icloud":
            let b = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            return dir(b) ? b.appendingPathComponent("Sundial") : nil
        case "dropbox":
            for c in ["Dropbox", "Library/CloudStorage/Dropbox"] {
                let b = home.appendingPathComponent(c)
                if dir(b) { return b.appendingPathComponent("Sundial") }
            }
            return nil
        case "gdrive":
            return cloudStorage(prefix: "GoogleDrive-", suffix: "My Drive")?
                .appendingPathComponent("Sundial")
        case "onedrive":
            return cloudStorage(prefix: "OneDrive", suffix: nil)?
                .appendingPathComponent("Sundial")
        default:
            let expanded = NSString(string: token).expandingTildeInPath
            return URL(fileURLWithPath: (expanded as NSString).standardizingPath)
        }
    }

    /// Which of the known services are actually set up here, for the settings UI.
    public static func available(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                 fm: FileManager = .default) -> [String] {
        tokens.filter { resolve($0, home: home, fm: fm) != nil }
    }

    public static func copy(_ files: [URL], into directory: URL,
                            fm: FileManager = .default) -> String? {
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return "could not create \(directory.path): \(error.localizedDescription)" }
        for src in files where fm.fileExists(atPath: src.path) {
            let dst = directory.appendingPathComponent(src.lastPathComponent)
            guard let data = fm.contents(atPath: src.path) else { continue }
            do { try data.write(to: dst, options: .atomic) }
            catch { return "could not write \(dst.lastPathComponent): \(error.localizedDescription)" }
        }
        return nil
    }
}

public extension Store {
    /// Pushes the CSV, and optionally the raw observations, to every
    /// destination. Never throws: a missing cloud folder is a warning, not an
    /// interruption to tracking.
    @discardableResult
    func mirror(to tokens: [String], includeObservations: Bool, day: String,
                home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                fm: FileManager = .default) -> (destinations: [String], errors: [String]) {
        var files = [dailyCSVURL, rulesURL]
        if includeObservations {
            files.append(observationsURL(day))
            files.append(presenceURL(day))
        }
        var destinations: [String] = [], errors: [String] = []
        for token in tokens {
            guard let dir = CloudMirror.resolve(token, home: home, fm: fm) else {
                errors.append("\(CloudMirror.label(token)) is not set up on this Mac")
                continue
            }
            if let e = CloudMirror.copy(files, into: dir, fm: fm) { errors.append(e) }
            else { destinations.append(dir.path) }
        }
        return (destinations, errors)
    }
}
