import SwiftUI
import SundialCore

/// One place for colour, type and surfaces.
///
/// Dark first, the way the apps this borrows from are: deep neutral ground,
/// cards raised off it by a shade rather than a border, one saturated accent
/// per meaning, and numbers set in rounded figures large enough to read from
/// across the desk. Light mode is the same idea inverted rather than a second
/// design.
enum Theme {
    // MARK: - Ground and surfaces

    static let canvas = Color(light: 0xF2F3F6, dark: 0x0D0F13)
    static let surface = Color(light: 0xFFFFFF, dark: 0x171A20)
    static let raised = Color(light: 0xF6F7F9, dark: 0x1F232B)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    static let sidebar = Color(light: 0xEAECF0, dark: 0x111318)

    // MARK: - Meaning

    static let work = Color(light: 0x1FA971, dark: 0x3DDC97)
    static let personal = Color(light: 0x4E6EF2, dark: 0x7C9BFF)
    static let away = Color(light: 0x9AA1AC, dark: 0x596170)
    static let unclassified = Color(light: 0xD9840F, dark: 0xF5B14C)

    // MARK: - Type
    //
    // Rounded for anything numeric, because the numbers are the point; the
    // default face for words, so long sentences stay comfortable.

    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static let hero = figure(40)
    static let stat = figure(21)
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let caption = Font.system(size: 10.5)

    static let radius: CGFloat = 14
}

extension Color {
    /// Two hex literals, one per appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                           green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension TimeCategory {
    var color: Color {
        switch self {
        case .work:         return Theme.work
        case .personal:     return Theme.personal
        case .away:         return Theme.away
        case .unclassified: return Theme.unclassified
        }
    }

    /// Bars and dots get a little depth rather than a flat fill.
    var gradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A small-caps section label. Used instead of a heavier title so the numbers
/// underneath stay the loudest thing on the screen.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(.tertiary)
    }
}

struct Card<Content: View>: View {
    var title: String?
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { SectionLabel(title) }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// One number with its name under it. The building block of every summary here.
struct StatTile: View {
    let value: String
    let label: String
    var detail: String?
    var tint: Color = .primary
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value)
                .font(Theme.figure(compact ? 17 : 21))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A category with its total, as a rounded chip.
struct CategoryChip: View {
    let category: TimeCategory
    let value: TimeInterval
    var emphasised = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(category.gradient).frame(width: 7, height: 7)
            Text(category.label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Format.duration(value))
                .font(Theme.figure(11.5, emphasised ? .semibold : .medium))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.raised)
        .clipShape(Capsule())
    }
}
