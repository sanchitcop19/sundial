import AppKit
import ApplicationServices
import CoreGraphics
import CoreAudio
import AVFoundation
import SundialCore

/// Live readings from the machine.
enum Signals {
    // MARK: - Presence

    /// Seconds since the last keyboard or pointer event. Needs no permission,
    /// and is the main defence against counting an unattended machine as work.
    static func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func displayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    static func screensaverActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.hasPrefix("com.apple.ScreenSaver") == true
        }
    }

    static var absent: Bool { screenLocked() || displayAsleep() || screensaverActive() }

    /// True while any app holds the default input device open. This is what
    /// makes meetings work for every conferencing app at once, rather than
    /// maintaining a list of meeting URLs.
    static func microphoneInUse() -> Bool {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr, id != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Reads the in-use flag only; it does not open a stream, so it triggers no
    /// camera permission prompt.
    static func cameraInUse() -> Bool {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
            .devices.contains { $0.isInUseByAnotherApplication }
    }

    static var inCall: Bool { microphoneInUse() || cameraInUse() }

    // MARK: - Accessibility

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func frontmostApp() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    /// `AXFocusedWindow` is absent for apps that are not frontmost, so main
    /// window and then the first window are tried in turn.
    static func windowElement(pid: pid_t, timeout: Float = 0.4) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &win) == .success,
               let win, CFGetTypeID(win) == AXUIElementGetTypeID() {
                return (win as! AXUIElement)
            }
        }
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement], let first = arr.first { return first }
        return nil
    }

    static func windowTitle(pid: pid_t) -> String? {
        guard let w = windowElement(pid: pid) else { return nil }
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
              let s = t as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Walks the window's accessibility tree looking for text starting with
    /// `prefix`, returning the rest. Bounded and exits on the first hit.
    static func labelWithPrefix(pid: pid_t, prefix: String,
                                maxNodes: Int = 600, maxDepth: Int = 18) -> String? {
        search(pid: pid, maxNodes: maxNodes, maxDepth: maxDepth) { text in
            guard text.hasPrefix(prefix) else { return nil }
            let v = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
    }

    /// Collects the toolbar buttons and hands the choice to ChromiumToolbar,
    /// which is where the heuristic is tested.
    static func chromiumProfile(pid: pid_t, maxNodes: Int = 300, maxDepth: Int = 9) -> String? {
        guard let win = windowElement(pid: pid, timeout: 0.5) else { return nil }
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        var buttons: [ChromiumToolbar.Button] = []

        while !queue.isEmpty, visited < maxNodes {
            let (e, depth) = queue.removeFirst()
            visited += 1
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXButton" {
                var descRef: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &descRef)
                var roleDescRef: CFTypeRef?
                AXUIElementCopyAttributeValue(e, "AXRoleDescription" as CFString, &roleDescRef)
                buttons.append(ChromiumToolbar.Button(
                    depth: depth,
                    description: (descRef as? String) ?? "",
                    roleDescription: (roleDescRef as? String) ?? "button"))
            }
            guard depth < maxDepth else { continue }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr.prefix(40) { queue.append((k, depth + 1)) }
            }
        }
        return ChromiumToolbar.profileName(from: buttons)
    }

    /// Finds whichever of `candidates` appears in the tree. Used for browser
    /// profiles, where the possible names are already known from the browser's
    /// own configuration - far more reliable than guessing a label format.
    static func labelMatching(pid: pid_t, candidates: [String],
                              maxNodes: Int = 500, maxDepth: Int = 14) -> String? {
        guard !candidates.isEmpty else { return nil }
        return search(pid: pid, maxNodes: maxNodes, maxDepth: maxDepth) { text in
            candidates.first {
                text.caseInsensitiveCompare($0) == .orderedSame
                    || text.localizedCaseInsensitiveContains($0)
            }
        }
    }

    /// Reads the address bar straight from the accessibility tree.
    ///
    /// Firefox-family browsers flush their session store only every ~15s, so
    /// relying on it means a tab change can be misattributed for that whole
    /// window. The address bar updates the instant you navigate, so it is used
    /// as the authoritative source and the session store is left to do only
    /// what it alone can: name the container.
    static func liveURL(pid: pid_t, maxNodes: Int = 250, maxDepth: Int = 8) -> String? {
        guard let win = windowElement(pid: pid, timeout: 0.4) else { return nil }
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (e, depth) = queue.removeFirst()
            visited += 1
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""
            if role == "AXComboBox" || role == "AXTextField" {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v) == .success,
                   let text = v as? String, let url = normaliseAddressBar(text) {
                    return url
                }
            }
            guard depth < maxDepth else { continue }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr.prefix(40) { queue.append((k, depth + 1)) }
            }
        }
        return nil
    }

    /// Address bars hide the https:// scheme and may hold a half-typed search,
    /// so only something that really looks like an address is accepted.
    static func normaliseAddressBar(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2048, !t.contains(" ") else { return nil }
        if t.contains("://") {
            guard let c = URLComponents(string: t), let h = c.host, !h.isEmpty else { return nil }
            return t
        }
        // No scheme: accept only a plausible hostname.
        let head = t.split(separator: "/").first.map(String.init) ?? t
        guard head == "localhost" || head.hasPrefix("localhost:")
                || (head.contains(".") && !head.hasPrefix(".") && !head.hasSuffix(".")) else { return nil }
        guard let c = URLComponents(string: "https://" + t), let h = c.host, !h.isEmpty else { return nil }
        return "https://" + t
    }

    private static func search(pid: pid_t, maxNodes: Int, maxDepth: Int,
                               test: (String) -> String?) -> String? {
        guard let win = windowElement(pid: pid, timeout: 0.5) else { return nil }
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (e, depth) = queue.removeFirst()
            visited += 1
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success,
                      let text = v as? String, !text.isEmpty, text.count < 200 else { continue }
                if let hit = test(text) { return hit }
            }
            guard depth < maxDepth else { continue }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr.prefix(60) { queue.append((k, depth + 1)) }
            }
        }
        return nil
    }

    // MARK: - Installed apps

    static func installedApps() -> [(bundleId: String, name: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        let dirs = ["/Applications", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Applications"]
        for dir in dirs {
            guard let kids = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for k in kids where k.hasSuffix(".app") {
                let plist = "\(dir)/\(k)/Contents/Info.plist"
                guard let d = NSDictionary(contentsOfFile: plist),
                      let bid = d["CFBundleIdentifier"] as? String, !seen.contains(bid) else { continue }
                seen.insert(bid)
                out.append((bid, String(k.dropLast(4))))
            }
        }
        return out.sorted { $0.1 < $1.1 }
    }
}
