import Foundation

/// Advisory file lock, so a second launch exits instead of both processes
/// appending to the same record. Works however the app was started.
enum SingleInstance {
    private static var lockFD: Int32 = -1

    static func acquire(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }   // cannot lock: prefer running
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        ftruncate(fd, 0)
        _ = "\(getpid())\n".withCString { write(fd, $0, strlen($0)) }
        lockFD = fd
        return true
    }
}
