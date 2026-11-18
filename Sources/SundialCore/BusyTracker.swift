import Foundation

/// Which button-triggered jobs are still running.
///
/// A button that starts slow work shows a spinner and ignores further presses
/// until that work finishes, so a second tap cannot start the same job twice.
/// Keys name the job ("backup", "rule:<id>"), so unrelated buttons stay usable.
public struct BusyTracker: Equatable, Sendable {
    private var running: Set<String> = []

    public init() {}

    /// Marks `key` as running. Returns false if it already was, in which case
    /// the caller must not start the work again.
    @discardableResult
    public mutating func begin(_ key: String) -> Bool {
        running.insert(key).inserted
    }

    public mutating func end(_ key: String) {
        running.remove(key)
    }

    public func isBusy(_ key: String) -> Bool { running.contains(key) }

    public var isIdle: Bool { running.isEmpty }
}
