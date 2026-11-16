import Foundation
import Combine
import CryptoKit
import Security
import SundialCore

/// Only this Mac holds the provider key. The phone shares its activity token,
/// and Apple delivers updates even when the companion is suspended.
struct PushCredentials: Codable, Equatable, Sendable {
    let keyID: String
    let teamID: String
    let privateKey: String

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.sanchit.sundial.live-activity",
        kSecAttrAccount as String: "apns-provider"
    ]

    static func load() -> PushCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        guard keyID.count == 10, teamID.count == 10,
              (keyID + teamID).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw SyncError.message("Enter Apple's 10-character Key ID and Team ID.")
        }
        _ = try P256.Signing.PrivateKey(pemRepresentation: privateKey)
        let data = try JSONEncoder().encode(self)
        let updates = [kSecValueData as String: data]
        var result = SecItemUpdate(Self.query as CFDictionary, updates as CFDictionary)
        if result == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else {
            throw SyncError.message("Could not save the APNs key in Keychain (\(result)).")
        }
    }
}

enum SyncError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

private struct PushResponseError: LocalizedError {
    let statusCode: Int
    let reason: String
    var errorDescription: String? { "Live Activity push failed: \(reason) (\(statusCode))." }
}

@MainActor
final class PhoneSync: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "sundial.phoneSync.enabled")
            lastAttempt = .distantPast
            if !enabled {
                cancelSync()
                activeLiveActivityUntil = nil
                status = "iPhone sync is off."
            }
        }
    }
    @Published var preferLiveActivity: Bool {
        didSet {
            UserDefaults.standard.set(preferLiveActivity, forKey: "sundial.phoneSync.preferLiveActivity")
        }
    }
    @Published var dailySchedule: LiveActivitySchedule {
        didSet {
            if let data = try? JSONEncoder().encode(dailySchedule) {
                UserDefaults.standard.set(data, forKey: "sundial.phoneSync.dailySchedule")
            }
            cancelSync()
            lastAttempt = .distantPast
        }
    }
    @Published private(set) var status = "On iPhone, choose iCloud Drive → Sundial."
    @Published private(set) var hasPushKey = false
    @Published private(set) var activeLiveActivityUntil: Date?
    @Published private(set) var isRestartingLiveActivity = false
    private var credentials: PushCredentials?
    private var lastAttempt = Date.distantPast
    private var lastSnapshot: WorkProgressSnapshot?
    private var syncTask: Task<Void, Never>?
    private var syncRequest = UUID()
    private var restartRequested = false
    private let worker = PhoneSyncWorker()

    init() {
        enabled = UserDefaults.standard.bool(forKey: "sundial.phoneSync.enabled")
        preferLiveActivity = UserDefaults.standard.object(forKey: "sundial.phoneSync.preferLiveActivity") as? Bool ?? true
        dailySchedule = UserDefaults.standard.data(forKey: "sundial.phoneSync.dailySchedule")
            .flatMap { try? JSONDecoder().decode(LiveActivitySchedule.self, from: $0) }
            ?? LiveActivitySchedule()
        credentials = PushCredentials.load()
        hasPushKey = credentials != nil
    }

    func configureKey(file: URL, keyID: String, teamID: String) throws {
        let key = try String(contentsOf: file, encoding: .utf8)
        let credentials = PushCredentials(keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                                          teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines),
                                          privateKey: key)
        try credentials.save()
        cancelSync()
        self.credentials = credentials
        hasPushKey = true
        lastAttempt = .distantPast
        status = "APNs key saved in this Mac's Keychain."
    }

    func restartLiveActivity() {
        guard !isRestartingLiveActivity else { return }
        guard enabled else {
            status = "Turn on iPhone sync before restarting the Live Activity."
            return
        }
        guard hasPushKey else {
            status = "Add an APNs key before restarting the Live Activity."
            return
        }
        // Let any current request finish first: cancelling an in-flight start
        // cannot tell us whether Apple already delivered it.
        restartRequested = true
        isRestartingLiveActivity = true
        lastAttempt = .distantPast
        status = "Restarting the iPhone Live Activity…"
    }

    func update(_ snapshot: WorkProgressSnapshot, destinations: [String]) {
        guard enabled, syncTask == nil else { return }
        let now = Date()
        var snapshot = snapshot
        snapshot.automaticActivityEnd = dailySchedule.activeWindow(for: snapshot, now: now)?.end.timeIntervalSince1970
        guard snapshot.isValid else {
            if restartRequested {
                restartRequested = false
                isRestartingLiveActivity = false
                status = "The work summary is not ready. Try restarting the Live Activity again shortly."
            }
            return
        }
        let statusChanged = lastSnapshot?.day != snapshot.day || lastSnapshot?.target != snapshot.target
            || lastSnapshot?.weeklyTarget != snapshot.weeklyTarget
            || lastSnapshot?.timeZoneIdentifier != snapshot.timeZoneIdentifier
            || lastSnapshot?.state != snapshot.state || lastSnapshot?.isPaused != snapshot.isPaused
            || lastSnapshot?.automaticActivityEnd != snapshot.automaticActivityEnd
            || lastSnapshot?.breakEndsAt != snapshot.breakEndsAt
            || lastSnapshot?.breakPausedRemaining != snapshot.breakPausedRemaining
        // Keep discovering tokens and checking renewal even when idle updates are skipped.
        guard statusChanged || now.timeIntervalSince(lastAttempt) >= 60 else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let iCloudFolder = CloudMirror.resolve("icloud", home: home)?.standardizedFileURL
        var seenPaths = Set<String>()
        let folders = ([iCloudFolder].compactMap { $0 }
            + destinations.compactMap { CloudMirror.resolve($0, home: home)?.standardizedFileURL })
            .filter { seenPaths.insert($0.path).inserted }
        guard !folders.isEmpty else {
            activeLiveActivityUntil = nil
            restartRequested = false
            isRestartingLiveActivity = false
            status = "Enable iCloud Drive on this Mac, or select a shared backup folder below."
            return
        }
        lastAttempt = now
        lastSnapshot = snapshot
        let request = UUID()
        syncRequest = request
        let credentials = credentials
        let schedule = dailySchedule
        let restarting = restartRequested
        restartRequested = false
        syncTask = Task {
            let result = await worker.synchronize(snapshot, folders: folders,
                                                   iCloudFolder: iCloudFolder, credentials: credentials,
                                                   schedule: schedule, restarting: restarting)
            guard syncRequest == request else { return }
            syncTask = nil
            if restarting { isRestartingLiveActivity = false }
            if enabled, !Task.isCancelled {
                if !restartRequested { status = result.status }
                activeLiveActivityUntil = result.activeLiveActivityUntil
            }
        }
    }

    private func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        syncRequest = UUID()
        restartRequested = false
        isRestartingLiveActivity = false
    }
}

private actor PhoneSyncWorker {
    private var jwt: String?
    private var jwtCredentials: PushCredentials?
    private var issuedAt = Date.distantPast
    private var rejectedTokens = Set<String>()
    private var rejectedStartTokens = Set<String>()
    private var lastPushed: [String: WorkProgressSnapshot] = [:]
    private let startLedger = LiveActivityStartLedger()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func synchronize(_ snapshot: WorkProgressSnapshot, folders: [URL], iCloudFolder: URL?,
                     credentials: PushCredentials?, schedule: LiveActivitySchedule = LiveActivitySchedule(),
                     restarting: Bool = false)
        async -> (status: String, activeLiveActivityUntil: Date?) {
        var registrations: [String: LiveActivityRegistration] = [:]
        var devices: [String: LiveActivityStartRegistration] = [:]
        func result(_ status: String) -> (status: String, activeLiveActivityUntil: Date?) {
            let now = Date()
            let expiry = registrations.values
                .filter { $0.isCurrent(for: snapshot, at: now) && !rejectedTokens.contains($0.token) }
                .map(\.expiresAt).max()
            return (status, expiry.map { Date(timeIntervalSince1970: $0) })
        }
        do {
            try Task.checkCancellation()
            var copied = 0
            var copiedToICloud = false
            var errors: [String] = []
            for folder in folders {
                try Task.checkCancellation()
                do {
                    try WorkProgressSync.writeSummary(snapshot,
                        to: folder.appendingPathComponent(WorkProgressSnapshot.fileName))
                    copied += 1
                    if folder == iCloudFolder { copiedToICloud = true }
                    let directory = folder.appendingPathComponent("live-activities")
                    let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                      includingPropertiesForKeys: [.fileSizeKey])) ?? []
                    for file in files where file.pathExtension == "json" {
                        try Task.checkCancellation()
                        // A registration is tiny; don't read arbitrary large files from a sync folder.
                        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size < 8192, let bytes = try? Data(contentsOf: file),
                              let registration = try? JSONDecoder().decode(LiveActivityRegistration.self, from: bytes),
                              registration.isWellFormed,
                              registration.expiresAt > Date().timeIntervalSince1970 - 8 * 3600
                        else { continue }
                        registrations[registration.token] = registration
                    }
                    let devicesFolder = folder.appendingPathComponent(LiveActivityStartRegistration.directoryName)
                    let deviceFiles = (try? FileManager.default.contentsOfDirectory(at: devicesFolder,
                        includingPropertiesForKeys: [.fileSizeKey])) ?? []
                    for file in deviceFiles where file.pathExtension == "json" {
                        try Task.checkCancellation()
                        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size < 8192, let bytes = try? Data(contentsOf: file),
                              let device = try? JSONDecoder().decode(LiveActivityStartRegistration.self, from: bytes),
                              device.isValid(at: Date()) else { continue }
                        if devices[device.deviceID].map({ $0.updatedAt < device.updatedAt }) ?? true {
                            devices[device.deviceID] = device
                        }
                    }
                } catch {
                    let name = folder == iCloudFolder ? "iCloud Drive → Sundial" : folder.lastPathComponent
                    errors.append("Could not update \(name): \(error.localizedDescription)")
                }
            }
            try Task.checkCancellation()
            lastPushed = lastPushed.filter { registrations[$0.key] != nil && !rejectedTokens.contains($0.key) }
            guard copied > 0 else { return result(errors.first ?? "Could not write the phone summary.") }
            let summaryStatus = copiedToICloud
                ? "Summary synced to iCloud Drive → Sundial."
                : "Summary synced to selected backup folders."
            guard let credentials else {
                return result(summaryStatus + " " + (errors.first
                    ?? "Add an APNs key for Live Activity updates while iPhone is locked."))
            }
            let token = try authorization(using: credentials)
            let now = Date()
            let window = schedule.window(for: snapshot, now: now)
            if restarting {
                let restartStatus = try await restart(snapshot, registrations: Array(registrations.values),
                    devices: Array(devices.values), authorization: token, schedule: schedule, now: now)
                return result(summaryStatus + " " + restartStatus)
            }
            var automationReady = true
            var updatedRegistrations: [LiveActivityRegistration] = []
            var sent = 0
            for registration in registrations.values where !rejectedTokens.contains(registration.token) {
                try Task.checkCancellation()
                do {
                    let ending = !registration.isCurrent(for: snapshot, at: Date())
                        || (registration.automatic == true
                            && schedule.shouldEndCurrentActivity(for: snapshot, now: now))
                    if ending || WorkProgressSync.shouldPublish(snapshot, replacing: lastPushed[registration.token]) {
                        try await send(snapshot, registration: registration, authorization: token, ending: ending)
                        if ending { rejectedTokens.insert(registration.token) }
                        else { lastPushed[registration.token] = snapshot }
                        sent += 1
                    }
                    // Skipped updates have already been accepted by Apple; failed ones never enter the cache.
                    if !ending { updatedRegistrations.append(registration) }
                } catch { errors.append(error.localizedDescription) }
            }
            // Only confirmed updates can extend a hold. Old registration files
            // whose tokens Apple rejects must not postpone the next start.
            if schedule.enabled {
                do {
                    for device in devices.values {
                        if let active = updatedRegistrations.filter({
                            $0.deviceID == device.deviceID || $0.deviceID == nil
                        }).max(by: { $0.expiresAt < $1.expiresAt }) {
                            try startLedger.rememberObservedActivity(day: snapshot.day,
                                requestID: active.startRequestID ?? active.id,
                                expiresAt: Date(timeIntervalSince1970: active.expiresAt),
                                for: device.deviceID, at: now)
                        }
                    }
                } catch {
                    automationReady = false
                    errors.append("Automatic starts are paused because their saved history could not be read or written. \(error.localizedDescription)")
                }
            }
            var automationStatus: String?
            if schedule.enabled, automationReady, let window {
                if devices.isEmpty {
                    automationStatus = "Open Sundial on iPhone once to connect automatic starts."
                }
                for device in devices.values {
                    guard !device.isPaused(at: Date()), !rejectedStartTokens.contains(device.token) else { continue }
                    let active = registrations.values.contains {
                        ($0.deviceID == device.deviceID || $0.deviceID == nil)
                            && $0.isCurrent(for: snapshot, at: Date()) && !rejectedTokens.contains($0.token)
                    }
                    guard !active else { continue }
                    if let previous = try startLedger.entry(for: device.deviceID),
                       previous.nextAttemptAt > Date() {
                        automationStatus = "Waiting for the requested Live Activity; automatic retries are paused to avoid duplicates."
                        continue
                    }
                    try Task.checkCancellation()
                    let requestedAt = Date()
                    guard requestedAt < window.end, !snapshot.isStale(at: requestedAt) else { continue }
                    let expiry = min(requestedAt.addingTimeInterval(LiveActivitySchedule.maximumActivityDuration), window.end)
                    let requestID = UUID().uuidString
                    var reservation = LiveActivityStartLedger.Entry(day: snapshot.day, requestID: requestID,
                        expiresAt: expiry, nextAttemptAt: expiry)
                    try startLedger.save(reservation, for: device.deviceID)
                    do {
                        let payload = LiveActivityStartPayload(snapshot: snapshot, deviceID: device.deviceID,
                            requestID: requestID, expiresAt: expiry, now: requestedAt)
                        try await post(try JSONEncoder().encode(payload), token: device.token,
                            environment: device.environment, authorization: token,
                            starting: true, collapseID: requestID)
                        automationStatus = "Apple accepted the automatic Live Activity start."
                    } catch let error as PushResponseError {
                        // An explicit rejection is safe to retry later. A timeout
                        // is ambiguous, so retain its reservation until expiry.
                        reservation.nextAttemptAt = Date().addingTimeInterval(5 * 60)
                        try startLedger.save(reservation, for: device.deviceID)
                        if error.statusCode == 410 { rejectedStartTokens.insert(device.token) }
                        errors.append(error.localizedDescription)
                    } catch {
                        errors.append("Automatic start could not be confirmed. Reopen Sundial on iPhone to check; it will not retry this activity and risk a duplicate. \(error.localizedDescription)")
                    }
                }
            }
            if let error = errors.first { return result(summaryStatus + " " + error) }
            if let automationStatus { return result(summaryStatus + " " + automationStatus) }
            return result(summaryStatus + (sent > 0
                ? " Sent \(sent) Live Activity update\(sent == 1 ? "" : "s") to Apple."
                : updatedRegistrations.isEmpty ? " Start a Live Activity in the iPhone app."
                : " Live Activity is up to date."))
        } catch { return result("iPhone sync: \(error.localizedDescription)") }
    }

    private func restart(_ snapshot: WorkProgressSnapshot,
                         registrations: [LiveActivityRegistration],
                         devices: [LiveActivityStartRegistration], authorization: String,
                         schedule: LiveActivitySchedule, now: Date) async throws -> String {
        guard let window = schedule.activeWindow(for: snapshot, now: now) else {
            return "Restart is available during your scheduled Live Activity hours. To start now, open Sundial on iPhone."
        }
        guard !devices.isEmpty else {
            return "Open Sundial on iPhone once to connect automatic starts, then try restarting."
        }
        let available = devices.filter { !$0.isPaused(at: now) && !rejectedStartTokens.contains($0.token) }
        guard !available.isEmpty else {
            return devices.contains(where: { $0.isPaused(at: now) })
                ? "Automatic starts are paused on iPhone. Tap Start in Sundial on iPhone to resume."
                : "The iPhone start connection has expired. Open Sundial on iPhone to reconnect."
        }
        // Check persistence before ending anything. A damaged history still
        // requires attention rather than risking an unrecorded replacement.
        for device in available { _ = try startLedger.entry(for: device.deviceID) }
        let deviceIDs = Set(available.map(\.deviceID))
        for registration in registrations where !rejectedTokens.contains(registration.token)
            && (registration.deviceID.map { deviceIDs.contains($0) } ?? true) {
            do {
                try await send(snapshot, registration: registration, authorization: authorization,
                               ending: true, urgent: true)
                rejectedTokens.insert(registration.token)
            } catch let error as PushResponseError where error.statusCode == 410 {
                // Apple has already retired this activity; it needs no end push.
                continue
            } catch {
                throw SyncError.message("Could not confirm the previous Live Activity ended. No replacement was requested. \(error.localizedDescription)")
            }
        }

        var accepted = 0
        var errors: [String] = []
        for device in available {
            try Task.checkCancellation()
            let requestedAt = Date()
            guard requestedAt < window.end, !snapshot.isStale(at: requestedAt) else {
                errors.append("Your scheduled hours ended or the work summary needs to refresh. Try restarting again.")
                break
            }
            let expiry = min(requestedAt.addingTimeInterval(LiveActivitySchedule.maximumActivityDuration), window.end)
            let requestID = UUID().uuidString
            var reservation = LiveActivityStartLedger.Entry(day: snapshot.day, requestID: requestID,
                expiresAt: expiry, nextAttemptAt: expiry)
            // This explicit action may replace an older unresolved reservation.
            // Ordinary automatic sync never clears it or repeats this request.
            try startLedger.save(reservation, for: device.deviceID)
            do {
                let payload = LiveActivityStartPayload(snapshot: snapshot, deviceID: device.deviceID,
                    requestID: requestID, expiresAt: expiry, now: requestedAt, replacesExisting: true)
                try await post(try JSONEncoder().encode(payload), token: device.token,
                    environment: device.environment, authorization: authorization,
                    starting: true, collapseID: requestID)
                accepted += 1
            } catch let error as PushResponseError {
                reservation.nextAttemptAt = Date().addingTimeInterval(5 * 60)
                try startLedger.save(reservation, for: device.deviceID)
                if error.statusCode == 410 { rejectedStartTokens.insert(device.token) }
                errors.append(error.localizedDescription)
            } catch {
                errors.append("The restart could not be confirmed. Open Sundial on iPhone to check; it will not retry and risk a duplicate. \(error.localizedDescription)")
            }
        }
        let acceptedStatus = accepted > 0
            ? "Apple accepted \(accepted == 1 ? "the Live Activity restart" : "\(accepted) Live Activity restarts"). Check your iPhone's Lock Screen."
            : nil
        return [acceptedStatus, errors.first].compactMap { $0 }.joined(separator: " ")
    }

    private func authorization(using credentials: PushCredentials) throws -> String {
        let age = Date().timeIntervalSince(issuedAt)
        if let jwt, jwtCredentials == credentials, age >= 0, age < 50 * 60 { return jwt }
        func encoded(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Date()
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": credentials.keyID])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": credentials.teamID,
                                                                  "iat": Int(now.timeIntervalSince1970)])
        let body = encoded(header) + "." + encoded(claims)
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKey)
        let signature = try key.signature(for: Data(body.utf8))
        let token = body + "." + encoded(signature.rawRepresentation)
        jwt = token; jwtCredentials = credentials; issuedAt = now
        return token
    }

    private func send(_ snapshot: WorkProgressSnapshot, registration: LiveActivityRegistration,
                      authorization: String, ending: Bool, urgent: Bool = false) async throws {
        do {
            try await post(try JSONEncoder().encode(LiveActivityPushPayload(snapshot: snapshot, ending: ending)),
                token: registration.token, environment: registration.environment,
                authorization: authorization, urgent: urgent)
        } catch let error as PushResponseError {
            if error.statusCode == 410 { rejectedTokens.insert(registration.token) }
            throw error
        }
    }

    private func post(_ payload: Data, token: String, environment: String, authorization: String,
                      starting: Bool = false, collapseID: String? = nil, urgent: Bool = false) async throws {
        try Task.checkCancellation()
        let host = environment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(token)")!)
        request.httpMethod = "POST"
        request.setValue("bearer " + authorization, forHTTPHeaderField: "authorization")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("dev.sanchit.sundial.mobile.push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue(starting || urgent ? "10" : "5", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(Date().timeIntervalSince1970 + (starting ? 60 : 300))), forHTTPHeaderField: "apns-expiration")
        request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.message("Apple returned no response.") }
        guard response.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
                ?? "Unknown error"
            throw PushResponseError(statusCode: response.statusCode, reason: reason)
        }
    }
}
