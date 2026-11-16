import ActivityKit
import Combine
import Foundation
import OSLog
import SundialCore

@MainActor
final class LiveActivityController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    @Published private(set) var isBusy = false
    @Published private(set) var recoveryAction: RecoveryAction?
    @Published private(set) var automaticStartStatus = "Choose a shared folder to connect automatic starts."

    enum RecoveryAction { case restart, sync }

    private var folder: URL?
    private var snapshot: WorkProgressSnapshot?
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]
    private var registeredIDs = Set<String>()
    private var registeredTokens: [String: Data] = [:]
    private var connectionTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var recoveryActivityID: String?
    private var activityUpdatesTask: Task<Void, Never>?
    private var startTokenTask: Task<Void, Never>?
    private var startToken: Data?
    private var lastDeviceRegistrationAt: Date?
    private var endingIDs = Set<String>()
    private let deviceID: String
    private let pausedUntilKey = "sundial.liveActivity.pausedUntil"
    private var pausedUntil: TimeInterval?
    private let logger = Logger(subsystem: "dev.sanchit.sundial.mobile", category: "LiveActivity")

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    init() {
        let key = "sundial.liveActivity.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: key)
        }
        let savedPause = UserDefaults.standard.double(forKey: pausedUntilKey)
        pausedUntil = savedPause > Date().timeIntervalSince1970 ? savedPause : nil

        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<WorkActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { break }
                self?.observe(activity)
                self?.updateRunningState()
            }
        }
        for activity in Activity<WorkActivityAttributes>.activities { observe(activity) }
        updateRunningState()
        if #available(iOS 17.2, *) {
            startToken = Activity<WorkActivityAttributes>.pushToStartToken
            startTokenTask = Task { [weak self] in
                for await token in Activity<WorkActivityAttributes>.pushToStartTokenUpdates {
                    guard !Task.isCancelled else { break }
                    self?.startToken = token
                    self?.syncDeviceRegistration(force: true)
                }
            }
        }
    }

    func connect(to folder: URL) {
        guard self.folder != folder else {
            syncDeviceRegistration()
            return
        }
        self.folder = folder
        registeredTokens.removeAll()
        syncDeviceRegistration(force: true)
        for activity in Activity<WorkActivityAttributes>.activities { observe(activity) }
    }

    func receive(_ snapshot: WorkProgressSnapshot?, folder: URL) async {
        // An older queued refresh must not reconnect a folder after Disconnect.
        guard self.folder == folder else { return }
        self.snapshot = snapshot
        syncDeviceRegistration()
        for activity in Activity<WorkActivityAttributes>.activities {
            guard activity.activityState == .active || activity.activityState == .stale else {
                removeRegistration(activity.id)
                continue
            }
            let expired = activity.attributes.expiresAt <= Date().timeIntervalSince1970
            let differentDay = snapshot.map {
                activity.attributes.automatic != true && $0.day != activity.attributes.day
                    && $0.updatedAt >= activity.content.state.updatedAt
            } ?? false
            if expired || differentDay {
                endingIDs.insert(activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
                removeRegistration(activity.id)
                continue
            }
            guard self.folder == folder else { return }
            observe(activity)
            guard !endingIDs.contains(activity.id) else { continue }
            if let snapshot, !snapshot.isStale(at: Date()),
               snapshot.updatedAt >= activity.content.state.updatedAt,
               snapshot != activity.content.state {
                await activity.update(content(snapshot))
            }
        }
        updateRunningState()
    }

    func start() async {
        logger.notice("Start Live Activity selected")
        guard !isBusy else { return }
        guard areActivitiesEnabled else {
            status = "Live Activities are unavailable or disabled. On iPhone, allow Live Activities in Settings → Apps → Sundial."
            return
        }
        guard folder != nil, let snapshot else {
            logger.notice("Live Activity start needs a Mac summary")
            status = "This folder hasn’t received work totals from your Mac. Choose the existing shared folder used by Sundial on your Mac; a new empty folder won’t connect automatically."
            return
        }
        guard !snapshot.isStale(at: Date()) else {
            logger.notice("Live Activity start needs a fresh Mac summary")
            status = "Wait for a fresh update from your Mac before starting a Live Activity."
            return
        }
        guard !isRunning else {
            status = "Live Activity is already running. Lock your iPhone or go to the Home Screen to see it."
            return
        }
        isBusy = true
        status = "Starting Live Activity…"
        defer { isBusy = false }
        do {
            let expiry = min(Date().addingTimeInterval(8 * 3_600),
                             WorkProgressPresentation.dayEnd(for: snapshot))
            #if targetEnvironment(simulator)
            let pushType: PushType? = nil
            #else
            let pushType: PushType? = .token
            #endif
            let activity = try Activity.request(
                attributes: WorkActivityAttributes(day: snapshot.day,
                                                   expiresAt: expiry.timeIntervalSince1970,
                                                   deviceID: deviceID, automatic: false),
                content: content(snapshot), pushType: pushType)
            setPause(until: nil)
            logger.info("Live Activity requested; remote updates: \(pushType != nil)")
            updateRunningState()
            observe(activity)
        } catch {
            logError("Live Activity request failed", error: error)
            status = "Could not start a Live Activity: \(error.localizedDescription)"
        }
    }

    func recoverConnection() async {
        guard !isBusy, let action = recoveryAction, let id = recoveryActivityID,
              let activity = Activity<WorkActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if let token = activity.pushToken {
            logger.info("Retrying Live Activity registration sync")
            register(token, for: activity)
        } else if action == .restart {
            guard let snapshot, !snapshot.isStale(at: Date()) else {
                status = "Wait for a fresh update from your Mac before restarting the Live Activity."
                return
            }
            logger.info("Restarting Live Activity after missing push token")
            await stop(pausingAutomaticStarts: false)
            await start()
        } else {
            waitForConnection(activity)
        }
    }

    func stop(pausingAutomaticStarts: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        logger.info("Stopping Live Activities")
        if pausingAutomaticStarts { pauseAutomaticStarts() }
        for activity in Activity<WorkActivityAttributes>.activities {
            endingIDs.insert(activity.id)
            removeRegistration(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        updateRunningState()
        recoveryAction = nil
        recoveryActivityID = nil
        status = pausingAutomaticStarts
            ? "Live Activity stopped. \(automaticPauseStatus)"
            : "Live Activity stopped."
    }

    func disconnect() {
        let activities = Activity<WorkActivityAttributes>.activities
        endingIDs.formUnion(activities.map(\.id))
        let ids = Set(tokenTasks.keys).union(registeredIDs).union(connectionTimeoutTasks.keys)
        for id in ids { removeRegistration(id) }
        removeSharedFile("\(LiveActivityStartRegistration.directoryName)/\(deviceID).json")
        folder = nil
        snapshot = nil
        lastDeviceRegistrationAt = nil
        automaticStartStatus = "Choose a shared folder to connect automatic starts."
        // Capture only the old activities: choosing another folder immediately
        // afterwards must not stop a newly created activity.
        Task {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
            updateRunningState()
        }
    }

    private func content(_ snapshot: WorkProgressSnapshot) -> ActivityContent<WorkProgressSnapshot> {
        ActivityContent(state: snapshot,
                        staleDate: WorkProgressPresentation.staleDate(for: snapshot))
    }

    private func observe(_ activity: Activity<WorkActivityAttributes>) {
        guard activity.activityState == .active || activity.activityState == .stale,
              !endingIDs.contains(activity.id) else { return }
        if activity.attributes.expiresAt <= Date().timeIntervalSince1970
            || (activity.attributes.automatic == true && (pausedUntil ?? 0) > Date().timeIntervalSince1970) {
            endProgrammatically(activity)
            return
        }
        if activity.attributes.deviceID == deviceID, activity.attributes.automatic == true {
            let peers = Activity<WorkActivityAttributes>.activities.filter {
                $0.attributes.deviceID == deviceID
                    && ($0.activityState == .active || $0.activityState == .stale)
                    && $0.attributes.expiresAt > Date().timeIntervalSince1970
                    && !endingIDs.contains($0.id)
            }
            let preferred = peers.max {
                // A user-requested restore wins even if Apple's end push for an
                // older manual activity has not arrived yet.
                if ($0.attributes.replacesExisting == true) != ($1.attributes.replacesExisting == true) {
                    return $1.attributes.replacesExisting == true
                }
                if ($0.attributes.automatic == true) != ($1.attributes.automatic == true) {
                    return $0.attributes.automatic == true
                }
                if $0.attributes.expiresAt != $1.attributes.expiresAt {
                    return $0.attributes.expiresAt < $1.attributes.expiresAt
                }
                if $0.content.state.updatedAt != $1.content.state.updatedAt {
                    return $0.content.state.updatedAt < $1.content.state.updatedAt
                }
                return $0.id < $1.id
            }
            if let preferred, preferred.id != activity.id {
                endProgrammatically(activity)
                return
            }
            for peer in peers where peer.id != activity.id { endProgrammatically(peer) }
        }
        if let token = activity.pushToken { register(token, for: activity) }
        guard tokenTasks[activity.id] == nil else { return }
        logger.info("Live Activity token observer attached")
        if activity.pushToken == nil { waitForConnection(activity) }
        tokenTasks[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { break }
                self?.register(token, for: activity)
            }
        }
        stateTasks[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { break }
                if state == .ended || state == .dismissed {
                    self?.logger.info("Live Activity ended or dismissed")
                    // A direct dismissal before expiry is the user's stop. An
                    // ended activity can later be dismissed by iOS itself.
                    if state == .dismissed, let self, !self.endingIDs.contains(activity.id),
                       activity.attributes.expiresAt > Date().timeIntervalSince1970 + 60 {
                        self.pauseAutomaticStarts(using: activity.content.state)
                    }
                    self?.removeRegistration(activity.id)
                    self?.updateRunningState()
                    break
                }
            }
        }
    }

    private func endProgrammatically(_ activity: Activity<WorkActivityAttributes>) {
        guard endingIDs.insert(activity.id).inserted else { return }
        removeRegistration(activity.id)
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            updateRunningState()
        }
    }

    private func pauseAutomaticStarts(using progress: WorkProgressSnapshot? = nil) {
        let progress = ([progress, snapshot].compactMap { $0 }
            + Activity<WorkActivityAttributes>.activities.map { $0.content.state })
            .filter(\.isValid)
            .max { $0.updatedAt < $1.updatedAt }
        let now = Date()
        let deadline = progress?.automaticPauseDeadline(at: now)
            ?? Calendar.current.dateInterval(of: .day, for: now)?.end
            ?? now.addingTimeInterval(24 * 3_600)
        setPause(until: deadline.timeIntervalSince1970)
    }

    private var automaticPauseStatus: String {
        guard let pausedUntil else { return "Automatic starts are paused." }
        let resumeTime = Date(timeIntervalSince1970: pausedUntil)
            .formatted(date: .abbreviated, time: .shortened)
        return "Automatic starts paused until \(resumeTime). Start manually to resume."
    }

    private func setPause(until date: TimeInterval?) {
        pausedUntil = date
        if let date { UserDefaults.standard.set(date, forKey: pausedUntilKey) }
        else { UserDefaults.standard.removeObject(forKey: pausedUntilKey) }
        syncDeviceRegistration(force: true)
    }

    private func syncDeviceRegistration(force: Bool = false) {
        guard let folder else { return }
        guard #available(iOS 17.2, *) else {
            automaticStartStatus = "Automatic starts require iOS 17.2 or later."
            return
        }
        guard areActivitiesEnabled else {
            removeSharedFile("\(LiveActivityStartRegistration.directoryName)/\(deviceID).json")
            lastDeviceRegistrationAt = nil
            automaticStartStatus = "Allow Live Activities in iPhone Settings to connect automatic starts."
            return
        }
        if let token = Activity<WorkActivityAttributes>.pushToStartToken, token != startToken {
            startToken = token
            lastDeviceRegistrationAt = nil
        }
        let now = Date()
        if let pausedUntil, pausedUntil <= now.timeIntervalSince1970 {
            self.pausedUntil = nil
            UserDefaults.standard.removeObject(forKey: pausedUntilKey)
            lastDeviceRegistrationAt = nil
        }
        guard force || lastDeviceRegistrationAt.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let directory = folder.appendingPathComponent(LiveActivityStartRegistration.directoryName, isDirectory: true)
        let file = directory.appendingPathComponent("\(deviceID).json")
        // On a background wake ActivityKit may deliver its token later. The
        // last registration still lets a user's Stop reach the Mac immediately.
        var token = startToken.map { $0.map { String(format: "%02x", $0) }.joined() }
        if token == nil {
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
                if let data = try? Data(contentsOf: url),
                   let existing = try? JSONDecoder().decode(LiveActivityStartRegistration.self, from: data),
                   existing.deviceID == deviceID {
                    token = existing.token
                }
            }
        }
        guard let token else {
            #if targetEnvironment(simulator)
            automaticStartStatus = "Automatic starts connect on a physical iPhone."
            #else
            automaticStartStatus = "Connecting automatic starts with Apple…"
            #endif
            return
        }
        let environment = Bundle.main.object(forInfoDictionaryKey: "SundialPushEnvironment") as? String == "production"
            ? "production" : "sandbox"
        let registration = LiveActivityStartRegistration(
            deviceID: deviceID, token: token, environment: environment,
            updatedAt: now.timeIntervalSince1970, pausedUntil: pausedUntil)
        do {
            try writeRegistration(registration, to: file)
            lastDeviceRegistrationAt = now
            automaticStartStatus = pausedUntil == nil
                ? "Automatic-start connection saved. Choose the days and hours on your Mac."
                : automaticPauseStatus
        } catch {
            logError("Automatic-start registration sync failed", error: error)
            automaticStartStatus = "Could not sync the automatic-start connection. Reopen Sundial to retry."
        }
    }

    private func writeRegistration<T: Encodable>(_ registration: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(registration)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }

    private func waitForConnection(_ activity: Activity<WorkActivityAttributes>) {
        #if targetEnvironment(simulator)
        status = "Live Activity on. Simulator updates come from this app."
        #else
        guard connectionTimeoutTasks[activity.id] == nil else { return }
        recoveryAction = nil
        recoveryActivityID = nil
        status = "Live Activity is running. Connecting background updates…"
        connectionTimeoutTasks[activity.id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, activity.activityState == .active || activity.activityState == .stale else { return }
            if let token = activity.pushToken {
                self.register(token, for: activity)
            } else {
                self.logger.notice("Live Activity push token still unavailable after 20 seconds")
                self.status = "Live Activity is running, but iPhone hasn’t connected for background updates yet. Restart it to try again."
                self.recoveryAction = .restart
                self.recoveryActivityID = activity.id
            }
        }
        #endif
    }

    private func register(_ token: Data, for activity: Activity<WorkActivityAttributes>) {
        guard registeredTokens[activity.id] != token, !endingIDs.contains(activity.id) else { return }
        connectionTimeoutTasks.removeValue(forKey: activity.id)?.cancel()
        logger.info("Live Activity push token received; bytes: \(token.count)")
        guard let folder, activity.attributes.expiresAt > Date().timeIntervalSince1970 else {
            logger.notice("Skipping token sync: no shared folder or activity expired")
            return
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let environment = Bundle.main.object(forInfoDictionaryKey: "SundialPushEnvironment") as? String == "production"
            ? "production" : "sandbox"
        let registration = LiveActivityRegistration(
            id: activity.id, token: token.map { String(format: "%02x", $0) }.joined(),
            environment: environment, day: activity.attributes.day,
            expiresAt: activity.attributes.expiresAt,
            deviceID: activity.attributes.deviceID ?? deviceID,
            automatic: activity.attributes.automatic,
            startRequestID: activity.attributes.startRequestID)
        do {
            let directory = folder.appendingPathComponent("live-activities", isDirectory: true)
            try writeRegistration(registration, to: directory.appendingPathComponent("\(activity.id).json"))
            registeredIDs.insert(activity.id)
            registeredTokens[activity.id] = token
            if recoveryActivityID == activity.id {
                recoveryAction = nil
                recoveryActivityID = nil
            }
            logger.info("Live Activity registration written to shared folder")
            status = "Live Activity on. Background updates need Live Activity push enabled on your Mac."
        } catch {
            logError("Live Activity registration sync failed", error: error)
            recoveryAction = .sync
            recoveryActivityID = activity.id
            status = "Live Activity on, but its update token could not sync: \(error.localizedDescription)"
        }
    }

    private func removeRegistration(_ id: String) {
        connectionTimeoutTasks.removeValue(forKey: id)?.cancel()
        tokenTasks.removeValue(forKey: id)?.cancel()
        stateTasks.removeValue(forKey: id)?.cancel()
        registeredIDs.remove(id)
        registeredTokens.removeValue(forKey: id)
        if recoveryActivityID == id {
            recoveryAction = nil
            recoveryActivityID = nil
        }
        removeSharedFile("live-activities/\(id).json")
    }

    private func removeSharedFile(_ path: String) {
        guard let folder else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(path)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func logError(_ message: String, error: Error) {
        let error = error as NSError
        logger.error("\(message, privacy: .public); domain: \(error.domain, privacy: .public), code: \(error.code)")
    }

    private func updateRunningState() {
        isRunning = Activity<WorkActivityAttributes>.activities.contains {
            $0.activityState == .active || $0.activityState == .stale
        }
    }
}
