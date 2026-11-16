import AppKit
import SwiftUI
import Combine
import SundialCore

/// Always keeps a Mac control available, even when Live Activity mirroring disappears.
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
    private var activityExpiry: Timer?
    private var breakMenuTimer: Timer?
    private var breakMenuItem: NSMenuItem?
    private var startMenuItem: NSMenuItem?
    private var snoozeMenuItem: NSMenuItem?
    private var skipMenuItem: NSMenuItem?
    private var compactForLiveActivity = false
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
        engine.phoneSync.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
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
        refreshVisibility()
    }

    private func refreshVisibility() {
        activityExpiry?.invalidate()
        activityExpiry = nil
        var compact = false
        if #available(macOS 26, *), engine.phoneSync.enabled,
           engine.phoneSync.preferLiveActivity,
           let expiry = engine.phoneSync.activeLiveActivityUntil, expiry > Date() {
            compact = true
            // Restore the full hours display at expiry even when tracking is paused.
            let timer = Timer(fire: expiry, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refreshVisibility() }
            }
            RunLoop.main.add(timer, forMode: .common)
            activityExpiry = timer
        }
        if compactForLiveActivity != compact {
            drawn = nil
            tipped = nil
            compactForLiveActivity = compact
        }
        // A phone registration cannot tell us whether macOS is actually mirroring it.
        item.isVisible = true
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

    private var isOverTarget: Bool {
        engine.workTarget.dailyTarget > 0 && engine.totals.work > engine.workTarget.dailyTarget
    }

    private var targetBalance: String {
        if engine.workTarget.dailyTarget <= 0 { return "No target today" }
        if isOverTarget {
            let overtime = Format.hoursMinutes(engine.totals.work - engine.workTarget.dailyTarget)
            return "+\(overtime) over target"
        }
        return "\(Format.hoursMinutes(engine.workTarget.remainingToday, roundingUp: true)) remaining"
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
        guard let button = item.button else { return }
        let tip = "Today: \(Format.hoursMinutes(engine.totals.work)) worked · \(targetBalance) (hours:minutes)"
            + "\n\(engine.workTargetLabel)"
            + (engine.workTargetWeekSummary.map { "\n" + $0 } ?? "")
            + (engine.workTargetNote.map { "\n" + $0 } ?? "")
            + "\n\(engine.isPaused ? "Paused" : state.label) — \(engine.currentReason)"
            + (ind.note.map { "\n" + $0 } ?? "")
        if tip != tipped {
            tipped = tip
            button.toolTip = tip
            button.setAccessibilityLabel("Sundial. " + tip)
        }
        if compactForLiveActivity {
            display?.invalidate()
            display = nil
            pulse(0, colour: .clear)
            let fraction = engine.workTarget.dailyTarget > 0
                ? min(1, max(0, engine.totals.work / engine.workTarget.dailyTarget)) : 0
            let key = "compact|\(Int(fraction * 100))|\(isOverTarget)"
            if drawn != key {
                drawn = key
                button.attributedTitle = NSAttributedString(string: "")
                button.image = progressImage(fraction: fraction)
                button.imagePosition = .imageOnly
                button.contentTintColor = isOverTarget ? NSColor(Theme.overtime) : nil
            }
            return
        }
        button.image = nil
        button.imagePosition = .noImage
        button.contentTintColor = nil
        let glyph = engine.isPaused ? "⏸" : state.glyph
        let worked = Format.hoursMinutes(engine.totals.work)
        let remaining = Format.hoursMinutes(engine.workTarget.remainingToday, roundingUp: true)
        let overtime = Format.hoursMinutes(engine.totals.work - engine.workTarget.dailyTarget)
        let time: String
        let balance: String
        switch engine.settings.menuBarTimeDisplay {
        case .worked:
            time = worked
            balance = ""
        case .remaining:
            time = engine.workTarget.dailyTarget <= 0 ? "No target"
                : isOverTarget ? "+\(overtime) over" : "\(remaining) left"
            balance = ""
        case .both:
            time = worked
            balance = isOverTarget ? " · +\(overtime)"
                : engine.workTarget.dailyTarget > 0 ? " · \(remaining) left" : ""
        }
        let indicatorColor = isOverTarget ? NSColor(Theme.overtime) : nsColor(state)
        // A break that is owed stays visible even while its reminder is snoozed.
        let suffix = balance + (engine.breakStatus.owed ? " \u{2615}" : "")
        let beating = ind.pulses && !reduceMotion
        schedule(ind, beating: beating)
        if let w = button.window, !w.occlusionState.contains(.visible) { return }

        // The dot only leaves the title once the layer has somewhere to be, and
        // it never goes back: a placement that fails leaves a still icon rather
        // than no icon at all.
        let useLayer = beating && dotPlaced

        // The expensive half: the words. Setting the title repaints a strip of
        // blurred menu bar, so it happens when the words change and not when
        // the dot does - about once a minute while work is being counted.
        let key = "\(glyph)|\(state.rawValue)|\(time)|\(suffix)|\(Int(ind.alpha * 50))|\(useLayer)"
        if key != drawn {
            drawn = key
            let s = NSMutableAttributedString()
            s.append(useLayer
                ? NSAttributedString(string: "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .kern: dotKern])
                : NSAttributedString(string: glyph + " ", attributes: [
                    .foregroundColor: indicatorColor.withAlphaComponent(isOverTarget ? 1 : ind.alpha),
                    .font: NSFont.systemFont(ofSize: 11)]))
            // Let the status button choose text contrast for its menu bar
            // background and highlighted state; label colors bypass that.
            s.append(NSAttributedString(string: time, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]))
            s.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
            button.attributedTitle = s
            titleWidth = s.size().width
        }
        // Placement is re-checked on every pass, not only after a redraw: the
        // button's width is not final the instant a new title is set, and a
        // single missed placement used to leave the dot hidden until the
        // minute rolled over.
        if beating { place(dot, in: button) }
        // The cheap half: an opacity, twenty-four times a second, no redraw.
        pulse(useLayer ? Indicator.pulseAlpha(at: clock, period: engine.settings.beatPeriod) : 0,
              colour: indicatorColor)
    }

    private func progressImage(fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { _ in
            let bounds = NSRect(x: 2, y: 2, width: 13, height: 13)
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let track = NSBezierPath(ovalIn: bounds)
            track.lineWidth = 2
            track.stroke()
            if fraction > 0 {
                NSColor.black.setStroke()
                let progress = NSBezierPath()
                progress.lineWidth = 2
                progress.lineCapStyle = .round
                progress.appendArc(withCenter: NSPoint(x: 8.5, y: 8.5), radius: 6.5,
                                   startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                progress.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Shows the dot at an opacity, or hides it. Implicit animation is switched
    /// off so the steps are exactly the ones asked for, rather than Core
    /// Animation interpolating between them at the display's refresh rate -
    /// which on a fast display is how the first attempt at this cost 40% of a
    /// core.
    private func pulse(_ opacity: Double, colour: NSColor) {
        let hide = opacity <= 0
        let value = Float(opacity)
        guard hide != !dot.isHidden || value != dot.opacity
            || (!hide && dot.backgroundColor != colour.cgColor) else { return }
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

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        breakMenuTimer?.invalidate()
        guard breakMenuItem != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBreakMenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
        breakMenuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        breakMenuTimer?.invalidate()
        breakMenuTimer = nil
    }

    private func refreshBreakMenu() {
        if let text = engine.breakCountdownText, let item = breakMenuItem {
            item.attributedTitle = label(text, color: .systemTeal, size: 11,
                                         weight: .semibold).attributedTitle
        }
        let canStart = engine.breakStatus.breakRemaining == nil && !engine.isPaused
        startMenuItem?.isHidden = !canStart
        let canDefer = engine.breakStatus.owed && canStart
        snoozeMenuItem?.isHidden = !canDefer
        skipMenuItem?.isHidden = !canDefer
    }

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
        breakMenuItem = nil
        startMenuItem = nil
        snoozeMenuItem = nil
        skipMenuItem = nil
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
                               + Format.duration(v),
                               color: c == .work && isOverTarget ? NSColor(Theme.overtime) : nsColor(c), size: 12))
        }
        menu.addItem(label("     \(targetBalance)"
                           + " · \(engine.workTargetLabel)",
                           color: isOverTarget ? NSColor(Theme.overtime) : .secondaryLabelColor, size: 11))
        if let week = engine.workTargetWeekSummary {
            menu.addItem(label("     " + week, color: .secondaryLabelColor, size: 11))
        }
        if let note = engine.workTargetNote {
            menu.addItem(label("     " + note, color: .secondaryLabelColor, size: 10))
        }

        if let countdown = engine.breakCountdownText {
            menu.addItem(.separator())
            let countdownItem = label(countdown, color: .systemTeal, size: 11, weight: .semibold)
            let start = action("Start break", #selector(startBreak))
            let snooze = action("Snooze for \(Int(Breaks.snooze / 60)) minutes", #selector(snoozeBreak))
            let skip = action("Skip break", #selector(skipBreak))
            breakMenuItem = countdownItem
            startMenuItem = start
            snoozeMenuItem = snooze
            skipMenuItem = skip
            menu.addItem(countdownItem)
            menu.addItem(start)
            menu.addItem(snooze)
            menu.addItem(skip)
            refreshBreakMenu()
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
        if engine.phoneSync.enabled && engine.phoneSync.hasPushKey {
            let restore = action(engine.phoneSync.isRestartingLiveActivity
                ? "Restoring Live Activity…" : "Restore Live Activity", #selector(restoreLiveActivity))
            restore.isEnabled = !engine.phoneSync.isRestartingLiveActivity
            menu.addItem(restore)
        }
        menu.addItem(action(engine.isPaused ? "Resume Tracking" : "Pause Tracking", #selector(pause)))
        let away = action("Out of Office Today", #selector(toggleOutOfOffice))
        away.state = engine.isOutOfOfficeToday ? .on : .off
        menu.addItem(away)
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    @objc func pause() { engine.togglePause(); refresh() }

    @objc private func toggleOutOfOffice() { engine.toggleOutOfOfficeToday(); refresh() }

    @objc private func restoreLiveActivity() { engine.phoneSync.restartLiveActivity() }

    @objc func startBreak() { engine.startBreak(); refresh() }

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
        activityExpiry?.invalidate()
        breakMenuTimer?.invalidate()
        if let o = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        engine.shutdown()
        NSApp.terminate(nil)
    }
}
