import Foundation

/// Consecutive matching rows in the activity list. Hidden app switches can
/// separate the members, so duration counts only their recorded time.
public struct SegmentGroup: Sendable, Equatable, Identifiable {
    public private(set) var segments: [Segment]

    public var first: Segment { segments[0] }
    public var id: String { first.id }
    public var start: Date { first.start }
    public var end: Date { segments[segments.count - 1].end }
    public var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    /// Takes the visible segments in chronological order.
    public static func build(from segments: [Segment]) -> [SegmentGroup] {
        var groups: [SegmentGroup] = []
        for segment in segments {
            if let last = groups.last, last.matches(segment) {
                groups[groups.count - 1].segments.append(segment)
            } else {
                groups.append(SegmentGroup(segments: [segment]))
            }
        }
        return groups
    }

    private func matches(_ segment: Segment) -> Bool {
        !first.manual && !segment.manual
            && first.state == segment.state
            && first.ruleId == segment.ruleId
            && first.reason == segment.reason
            && first.snapshot?.bundleId == segment.snapshot?.bundleId
            && first.snapshot?.groupingKey == segment.snapshot?.groupingKey
            && first.snapshot?.summary == segment.snapshot?.summary
    }
}
