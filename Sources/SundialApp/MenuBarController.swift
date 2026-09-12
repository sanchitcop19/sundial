import AppKit
import SwiftUI
import Combine
import SundialCore

/// The always-visible indicator: current state and today's work total.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine: Engine
    private let menu = NSMenu()
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()

    /// Drives the beat and the idle fade between samples, so the icon reacts to
    /// a keystroke immediately rather than at the next five-second tick.
    private var display: Timer?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var motionObserver: NSObjectProtocol?
    /// Monotonic, so the breath does not stutter when the wall clock is adjusted.
    private var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var drawn: String?
    private var tipped: String?

    /// The pulsing dot, drawn as a layer rather than as text.
    ///
    /// Setting the button's title repaints a strip of blurred menu bar and
    /// costs around eight milliseconds; changing a layer's opacity skips
    /// rasterising anything and measures roughly a tenth of that. The dot is
    /// the only part that moves, so it is the only part that leaves the title.
    private let dot = CALayer()
    private var dotPlaced = false
    private var titleWidth: CGFloat = 0
    /// A space padded to the exact advance of the glyph it stands in for, so
    /// the total does not shift sideways when the dot takes over.
    private lazy var dotKern: CGFloat = {
        let f = NSFont.systemFont(ofSize: 11)
        let glyph = (TimeCategory.work.glyph as NSString).size(withAttributes: [.font: f]).width
        return glyph - (" " as NSString).size(withAttributes: [.font: f]).width
    }()

    init(engine: Engine) {
        self.engine = engine
        super.init()
        menu.delegate = self
        item.menu = menu
        item.button?.wantsLayer = true
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self.refresh()
                }
            }
        refresh()
    }

    private func nsColor(_ c: TimeCategory) -> NSColor {
        switch c {
        case .work:         return .systemGreen
        case .personal:     return .systemBlue
        case .away:         return .tertiaryLabelColor
        case .unclassified: return .systemOrange
        }
    }

    /// The live picture: what the current stretch counts as, and whether it is
    /// still being earned. Idle is read here rather than taken from the last
    /// sample, so the icon is never a whole sample interval out of date.
    private func indicator() -> LiveIndicator {
        Indicator.current(state: engine.currentState,
                          idleSeconds: engine.isPaused ? 0 : Signals.idleSeconds(),
                          inCall: engine.inCall, isPaused: engine.isPaused,
                          settings: engine.settings)
    }

    private func refresh() {
        let ind = indicator()
        let state = engine.isPaused ? TimeCategory.away : engine.currentState
        let glyph = engine.isPaused ? "⏸" : state.glyph
        // A break that is owed shows even while the reminder is snoozed, and
        // needs no notification permission to be seen.
        let total = Format.duration(engine.totals.work)
            + (engine.breakStatus.owed ? " \u{2615}" : "")
        let beating = ind.pulses && !reduceMotion
        schedule(ind, beating: beating)
        guard let button = item.button else { return }
        if let w = button.window, !w.occlusionState.contains(.visible) { return }

        // The dot only leaves the title once the layer has somewhere to be, and
        // it never goes back: a placement that fails leaves a still icon rather
        // than no icon at all.
        let useLayer = beating && dotPlaced

        // The expensive half: the words. Setting the title repaints a strip of
        // blurred menu bar, so it happens when the words change and not when
        // the dot does - about once a minute while work is being counted.
        let key = "\(glyph)|\(state.rawValue)|\(total)|\(Int(ind.alpha * 50))|\(useLayer)"
        if key != drawn {
            drawn = key
            let s = NSMutableAttributedString()
            s.append(useLayer
                ? NSAttributedString(string: "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .kern: dotKern])
                : NSAttributedString(string: glyph + " ", attributes: [
                    .foregroundColor: nsColor(state).withAlphaComponent(ind.alpha),
                    .font: NSFont.systemFont(ofSize: 11)]))
            s.append(NSAttributedString(string: total, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor]))
            button.attributedTitle = s
            titleWidth = s.size().width
            // Set apart from the redraw: assigning a tooltip rebuilds the
            // view's tracking areas, and the words change with the state, not
            // several times a second as the dot fades.
            let tip = "\(state.label) — \(engine.currentReason)"
                + (ind.note.map { "\n" + $0 } ?? "")
            if tip != tipped { tipped = tip; button.toolTip = tip }
        }

        // Placement is re-checked on every pass, not only after a redraw: the
        // button's width is not final the instant a new title is set, and a
        // single missed placement used to leave the dot hidden until the
        // minute rolled over.
        if beating { place(dot, in: button) }
        // The cheap half: an opacity, twenty-four times a second, no redraw.
        pulse(useLayer ? Indicator.pulseAlpha(at: clock, period: engine.settings.beatPeriod) : 0,
              colour: nsColor(state))
    }

    /// Shows the dot at an opacity, or hides it. Implicit animation is switched
    /// off so the steps are exactly the ones asked for, rather than Core
    /// Animation interpolating between them at the display's refresh rate -
    /// which on a fast display is how the first attempt at this cost 40% of a
    /// core.
    private func pulse(_ opacity: Double, colour: NSColor) {
        let hide = opacity <= 0
        let value = Float(opacity)
        guard hide != !dot.isHidden || value != dot.opacity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = hide
        if !hide {
            let cg = colour.cgColor
            if dot.backgroundColor != cg { dot.backgroundColor = cg }
            dot.opacity = value
        }
        CATransaction.commit()
    }

    /// Puts the dot where the glyph it stands in for would have been drawn: the
    /// title is centred in the button, so its left edge is half the slack.
    private func place(_ layer: CALayer, in button: NSStatusBarButton) {
        let b = button.bounds
        guard b.width > 1, b.height > 1, titleWidth > 1 else { return }
        let size: CGFloat = 6
        let x = max(0, (b.width - titleWidth) / 2 + (dotKern + 2 - size) / 2)
        let frame = CGRect(x: x, y: ((b.height - size) / 2).rounded(),
                           width: size, height: size)
        if layer.superlayer == nil {
            button.wantsLayer = true
            layer.isHidden = true
            layer.cornerRadius = size / 2
            button.layer?.addSublayer(layer)
        }
        if layer.frame != frame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = frame
            CATransaction.commit()
        }
        dotPlaced = true
    }

    /// While the dot is pulsing this runs at a fixed rate, because an opacity
    /// change is cheap enough to afford one; otherwise it wakes once a second
    /// for the idle fade, and not at all while paused.
    private func schedule(_ ind: LiveIndicator, beating: Bool) {
        display?.invalidate()
        display = nil
        guard ind.liveness != .paused else { return }
        let wait = beating ? 1 / Indicator.beatFrameRate : 1
        let t = Timer(timeInterval: max(wait, 0.05), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = beating ? wait * 0.2 : 0.4
        RunLoop.main.add(t, forMode: .common)
        display = t
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    private func label(_ text: String, color: NSColor = .labelColor,
                       size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSMenuItem {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: size, weight: weight)])
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func rebuild() {
        menu.removeAllItems()
        let state = engine.isPaused ? TimeCategory.away : engine.currentState
        menu.addItem(label("\(state.glyph)  \(engine.isPaused ? "Paused" : state.label)",
                           color: nsColor(state), size: 13, weight: .semibold))
        menu.addItem(label("     " + engine.currentReason, color: .secondaryLabelColor, size: 10))
        if let note = indicator().note {
            menu.addItem(label("     " + note, color: .tertiaryLabelColor, size: 10))
        }

        menu.addItem(.separator())
        for c in TimeCategory.allCases {
            let v = engine.totals.byState[c] ?? 0
            guard v > 0 || c == .work else { continue }
            menu.addItem(label("     \(c.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                               + Format.duration(v), color: nsColor(c), size: 12))
        }

        if engine.breakStatus.owed {
            menu.addItem(.separator())
            menu.addItem(label("Break due after "
                               + Format.duration(engine.breakStatus.workedStraight)
                               + " of work"
                               + (engine.breakStatus.heldBack.map { " (\($0))" } ?? ""),
                               color: .systemTeal, size: 11, weight: .semibold))
            menu.addItem(action("Snooze for \(Int(Breaks.snooze / 60)) minutes",
                                #selector(snoozeBreak)))
            menu.addItem(action("Skip break", #selector(skipBreak)))
        }

        if !engine.reviewItems.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label("\(engine.reviewItems.count) need a rule "
                               + "(\(Format.duration(engine.totals.unclassified)))",
                               color: .systemOrange, size: 11, weight: .semibold))
        }
        if engine.needsAccessibility {
            menu.addItem(.separator())
            menu.addItem(label("⚠︎ Accessibility permission needed", color: .systemRed, size: 11))
        }

        menu.addItem(.separator())
        menu.addItem(action("Open Sundial…", #selector(open), key: "o"))
        menu.addItem(action(engine.isPaused ? "Resume Tracking" : "Pause Tracking", #selector(pause)))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    @objc func pause() { engine.togglePause(); refresh() }

    @objc func snoozeBreak() { engine.snoozeBreak(); refresh() }

    @objc func skipBreak() { engine.skipBreak(); refresh() }

    @objc func open() {
        if window == nil {
            let host = NSHostingController(rootView: MainWindow().environmentObject(engine))
            let w = NSWindow(contentViewController: host)
            w.title = "Sundial"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.setContentSize(NSSize(width: 720, height: 620))
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func quit() {
        display?.invalidate()
        if let o = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        engine.shutdown()
        NSApp.terminate(nil)
    }
}
