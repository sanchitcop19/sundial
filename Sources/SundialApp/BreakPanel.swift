import AppKit
import SwiftUI
import SundialCore

/// The break reminder as a panel of our own.
///
/// Notifications are the better citizen - they respect Focus and they queue in
/// Notification Center - but they can be refused, and a reminder that silently
/// does nothing because of a dialog answered weeks ago is worse than no feature
/// at all. So when the system will not deliver, the app says it itself.
@MainActor
final class BreakPanel {
    private var panel: NSPanel?
    private var timer: Timer?

    var onSnooze: (() -> Void)?
    var onSkip: (() -> Void)?

    func show(_ reminder: BreakReminder) {
        close()
        let view = BreakPanelView(
            reminder: reminder,
            snooze: { [weak self] in self?.onSnooze?(); self?.close() },
            skip: { [weak self] in self?.onSkip?(); self?.close() },
            dismiss: { [weak self] in self?.close() })

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 96)
        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Top right of whichever screen has the menu bar, tucked under it.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - host.frame.width - 16,
                                     y: f.maxY - host.frame.height - 16))
        }
        p.orderFrontRegardless()
        panel = p

        // Never left on screen: a reminder that has to be dismissed is a
        // nuisance, not a reminder.
        timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct BreakPanelView: View {
    let reminder: BreakReminder
    let snooze: () -> Void
    let skip: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.work)
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title).font(.system(size: 13, weight: .semibold))
                Text(reminder.body)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    if reminder.canSnooze {
                        Button("Snooze \(Int(Breaks.snooze / 60)) min", action: snooze)
                            .controlSize(.small)
                        Button("Skip break", action: skip).controlSize(.small)
                    }
                    Button("Dismiss", action: dismiss).controlSize(.small)
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: 340, alignment: .leading)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
