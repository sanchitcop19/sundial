import AppKit
import UserNotifications
import SundialCore

enum BreakReminder {
    case due(worked: TimeInterval)
    case over(length: TimeInterval)

    var title: String {
        switch self {
        case .due: return "Time for a break"
        case .over: return "Your break is over"
        }
    }

    var body: String {
        switch self {
        case .due(let worked): return "\(Format.duration(worked)) of work in this stretch."
        case .over(let length): return "Your \(Format.duration(length)) break is complete."
        }
    }

    var canSnooze: Bool {
        if case .due = self { return true }
        return false
    }
}

/// Break reminders and completion alerts, delivered as notifications.
///
/// Permission is asked for at the moment the first break actually falls due,
/// never at launch. An app that has not yet had anything to say has not earned
/// the right to interrupt, and if permission is refused the feature still works
/// quietly in the menu bar.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "break"
    nonisolated static let snoozeAction = "snooze"
    nonisolated static let skipAction = "skip"
    nonisolated private static let requestKey = "breakRequestID"
    private static let identifier = "break"

    /// Called when someone chooses Snooze on the notification.
    var onSnooze: (() -> Void)?
    /// Called when someone chooses to skip the currently owed break.
    var onSkip: (() -> Void)?
    /// Called once the system accepts a current break-due notification.
    var onBreakDueDelivered: (() -> Void)?
    /// Called when the system will not deliver, so the app can say it itself.
    var onBlocked: ((BreakReminder) -> Void)?
    /// Last known answer, for the UI to explain a silent reminder.
    private(set) var refused = false
    private var asked = false
    private var requestID = UUID()
    private var currentReminder: BreakReminder?

    override init() {
        super.init()
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.snoozeAction,
                                         title: "Snooze \(Int(Breaks.snooze / 60)) min",
                                         options: []),
                    UNNotificationAction(identifier: Self.skipAction,
                                         title: "Skip break", options: [])
                ],
                intentIdentifiers: [], options: [])
        ])
    }

    func breakDue(worked: TimeInterval) {
        deliver(.due(worked: worked))
    }

    func breakOver(length: TimeInterval) {
        deliver(.over(length: length))
    }

    /// Invalidate permission callbacks too: an unanswered prompt must not post
    /// an obsolete reminder after the break ends or reminders are switched off.
    func cancel() {
        requestID = UUID()
        currentReminder = nil
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        centre.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    /// A completed break clears an old due reminder even when no completion
    /// alert is sent, for example after waking. Keep any completion alert.
    @discardableResult
    func cancelBreakDue() -> Bool {
        guard currentReminder?.canSnooze == true else { return false }
        cancel()
        return true
    }

    private func deliver(_ reminder: BreakReminder) {
        cancel()
        currentReminder = reminder
        let id = requestID
        // Authorisation is re-checked rather than remembered, so granting it in
        // System Settings later starts this working without a restart.
        request { [weak self] granted in
            guard let self, self.requestID == id else { return }
            self.refused = !granted
            granted ? self.post(reminder, id: id) : self.onBlocked?(reminder)
        }
    }

    /// Asks the system what it will do, without asking the person anything.
    func refreshAuthorisation() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in self.refused = !ok && s.authorizationStatus != .notDetermined }
        }
    }

    private func request(_ done: @escaping (Bool) -> Void) {
        if asked { return UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in done(ok) }
        } }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in done(ok) }
        }
    }

    private func post(_ reminder: BreakReminder, id: UUID) {
        let c = UNMutableNotificationContent()
        c.title = reminder.title
        c.body = reminder.body
        c.userInfo[Self.requestKey] = id.uuidString
        if reminder.canSnooze { c.categoryIdentifier = Self.category }
        c.sound = .default
        // A fixed identifier, so a second reminder replaces the first instead
        // of stacking up a column of them while someone is heads down.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.identifier, content: c, trigger: nil)) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.requestID == id else { return }
                    if error != nil {
                        self.onBlocked?(reminder)
                    } else if reminder.canSnooze {
                        self.onBreakDueDelivered?()
                    }
                }
            }
    }

    /// Menu bar apps are rarely "frontmost", but when they are the banner
    /// should still show rather than being swallowed.
    nonisolated func userNotificationCenter(
        _ centre: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.content.userInfo[Self.requestKey] as? String
        Task { @MainActor [weak self] in
            guard let self, id == self.requestID.uuidString else { return done([]) }
            done([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ centre: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = response.notification.request.content.userInfo[Self.requestKey] as? String
        Task { @MainActor [weak self] in
            if let self, id == self.requestID.uuidString,
               self.currentReminder?.canSnooze == true {
                switch action {
                case Self.snoozeAction: self.onSnooze?()
                case Self.skipAction: self.onSkip?()
                default: break
                }
            }
            done()
        }
    }
}
