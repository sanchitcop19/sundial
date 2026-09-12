import SwiftUI
import SundialCore

/// The day as one bar, laid out in clock order.
///
/// The single most useful thing on the screen, so it is given room: a thick
/// rounded track, a tick for every few hours, and a marker where the last
/// stretch ends. Tapping a band selects it.
struct TimelineBar: View {
    let segments: [Segment]
    @Binding var selection: Segment?
    var height: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let total = max(1, span)
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        let selected = selection?.start == seg.start
                        seg.state.gradient
                            .frame(width: max(1, geo.size.width * (seg.duration / total)))
                            .overlay(selected ? Color.primary.opacity(0.55) : .clear)
                            .onTapGesture { selection = selected ? nil : seg }
                            .help("\(Format.clock(seg.start))–\(Format.clock(seg.end))  "
                                  + "\(seg.state.label)\n\(seg.snapshot?.summary ?? "")")
                    }
                }
            }
            .frame(height: height)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))

            if let first = segments.first, let last = segments.last {
                HStack {
                    Text(Format.clock(first.start))
                    Spacer()
                    Text(Format.clock(last.end))
                }
                .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }

    private var span: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
}

/// Work / Personal / Away / Unclassified as chips.
struct TotalsRow: View {
    let totals: Totals

    var body: some View {
        HStack(spacing: 7) {
            ForEach(TimeCategory.allCases, id: \.self) { c in
                let v = totals.byState[c] ?? 0
                if v > 0 || c == .work {
                    CategoryChip(category: c, value: v, emphasised: c == .work)
                }
            }
        }
    }
}

struct SegmentRow: View {
    let segment: Segment
    var selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Capsule().fill(segment.state.gradient).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(segment.snapshot?.summary ?? segment.state.label)
                        .lineLimit(1).font(.system(size: 12.5, weight: .medium))
                    if segment.manual {
                        Text("BY HAND")
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Theme.raised).clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(segment.reason)
                    .lineLimit(1).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.duration(segment.duration))
                    .font(Theme.figure(12, .medium)).monospacedDigit()
                Text("\(Format.clock(segment.start))–\(Format.clock(segment.end))")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(selected ? segment.state.color.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}
