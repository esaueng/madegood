import Foundation
import Synchronization
import WatchConnectivity
import WaterKit

/// Moves finished recordings from the watch to the phone.
///
/// - The watch sends each file with `WCSession.transferFile` (each stream is already
///   gzipped), `meta.json` last.
/// - The phone stores each file durably (atomic replace for duplicates) and only then
///   acknowledges it with `transferUserInfo`, which is queued, delivered in order and
///   delivered even if the watch app isn't running. Each acknowledgement lists every
///   recording file the phone holds for that session right then, with its size.
/// - The watch deletes a recording only when one acknowledgement shows the phone holding
///   **every** file of it at the same size (`isDelivered`). Acknowledgements are not added
///   up over time: if the phone loses a file it acknowledged earlier (the user deletes a
///   half-received recording, or a replace fails), the next list shows it, and the watch
///   keeps the recording and sends it again on the next launch. An acknowledgement without
///   a list (a phone build from before it) never deletes anything.
/// - The recording in progress is never sent or deleted (`markActive`).
/// - WatchConnectivity can leave a transfer outstanding forever without calling back. Each
///   transfer carries the time it was queued; each launch cancels and re-queues any that has
///   been outstanding for `stuckAfter`, and "Send again" re-queues them all. Cancelling never
///   touches the recording's files, and the phone replaces duplicates atomically.
///
/// - Raw format versions (docs/formats.md): the phone advertises the versions it reads
///   (`rawVersions` in its application context; a phone build without it reads only 1).
///   The watch sends a recording only to a phone that reads its version and otherwise
///   keeps it, and the phone never acknowledges a `meta.json` whose version it cannot read.
///
/// The watch never talks to the API (docs/PLAN.md §4.1); the phone is the hub.
final class RecordingTransfer: NSObject, WCSessionDelegate, Sendable {
    static let shared = RecordingTransfer()

    /// Posted on the main queue when the phone has stored a file.
    static let didReceiveFile = Notification.Name("RecordingTransfer.didReceiveFile")
    /// Posted on the main queue when the watch has removed a fully delivered recording.
    static let didDeliverRecording = Notification.Name("RecordingTransfer.didDeliverRecording")

    private enum Key {
        static let sessionId = "sessionId"
        static let file = "file"
        static let stored = "stored"
        static let settings = "settings"
        static let rawVersions = "rawVersions"
        static let queuedAt = "queuedAt"
        static let files = "files"
    }

    /// Which outstanding transfers a send cancels and queues again.
    enum Requeue {
        /// None: only files not in flight are queued.
        case none
        /// Those outstanding for `stuckAfter` (each launch).
        case stuck
        /// All of them ("Send again").
        case all
    }

    /// The recording files in `folder` and their sizes; nil if the folder cannot be read.
    /// The phone sends this with each acknowledgement, and the watch compares it with its own.
    static func recordingFiles(in folder: URL) -> [String: Int64]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        var files: [String: Int64] = [:]
        for name in names where RecordingStore.isRecordingFileName(name) {
            let url = folder.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value
            else { return nil }
            files[name] = size
        }
        return files
    }

    /// The phone's list of stored files from an acknowledgement; nil if it has none (a phone
    /// build from before the list) or it is malformed.
    static func phoneFiles(fromAcknowledgement userInfo: [String: Any]) -> [String: Int64]? {
        guard let raw = userInfo[Key.files] as? [String: Any] else { return nil }
        var files: [String: Int64] = [:]
        for (name, value) in raw {
            guard let size = (value as? NSNumber)?.int64Value else { return nil }
            files[name] = size
        }
        return files
    }

    /// Whether the phone holds every file of a recording the watch holds as `local`, at the
    /// same size. An empty recording is never delivered.
    static func isDelivered(local: [String: Int64], phone: [String: Int64]) -> Bool {
        !local.isEmpty && local.allSatisfy { phone[$0.key] == $0.value }
    }

    /// Why `phone` does not cover `local` yet, one line per file, for the diagnostics; empty
    /// exactly when `isDelivered`.
    static func deliveryGaps(local: [String: Int64], phone: [String: Int64]) -> [String] {
        if local.isEmpty { return ["no recording files on the watch"] }
        return local.sorted { $0.key < $1.key }.compactMap { name, size in
            guard let held = phone[name] else { return "\(name) missing on iPhone" }
            return held == size ? nil : "\(name) is \(held) bytes on iPhone, \(size) on the watch"
        }
    }

    /// A file transfer still queued or in progress, for the diagnostics.
    struct Outstanding: Hashable, Sendable {
        var file: String
        var queuedAt: Date?
        var fractionCompleted: Double
        var isTransferring: Bool
    }

    /// How long a file transfer may stay outstanding before a launch treats it as stuck and
    /// queues it again. Long enough for an hour of motion data over Bluetooth.
    static let stuckAfter: TimeInterval = 15 * 60

    /// Whether an outstanding transfer queued at `queuedAt` should be cancelled and queued
    /// again: always when the user asks (`.all`); at launch (`.stuck`) once it has been
    /// outstanding for `stuckAfter`. A transfer without a time (queued by an earlier build, which could
    /// not recover a stuck one) counts as stuck, as does one whose time is that far in the
    /// future (the clock was changed).
    static func shouldRequeue(queuedAt: Date?, now: Date, requeue: Requeue) -> Bool {
        switch requeue {
        case .none: return false
        case .all: return true
        case .stuck:
            guard let queuedAt else { return true }
            return abs(now.timeIntervalSince(queuedAt)) >= stuckAfter
        }
    }

    /// The time a transfer was queued, from its metadata.
    static func queuedAt(metadata: [String: Any]?) -> Date? {
        (metadata?[Key.queuedAt] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// The raw recording versions this build reads, as it tells the other device.
    static let readableRawVersions = RawFormat.readableVersions.sorted()

    /// The raw versions a phone reads, from its application context. Builds from before raw
    /// format 2 do not say, and read only version 1.
    static func phoneRawVersions(fromContext context: [String: Any]) -> Set<Int> {
        (context[Key.rawVersions] as? [Int]).map(Set.init) ?? [1]
    }

    /// Whether a recording of `version` may go to a phone that reads `phone`. Fails closed:
    /// a recording whose version could not be read stays on the watch (a phone build that
    /// predates the check would acknowledge it, and the watch would delete it).
    static func mayDeliver(version: Int?, toPhoneReading phone: Set<Int>) -> Bool {
        guard let version else { return false }
        return phone.contains(version)
    }

    /// Whether the recording in `folder` may go to a phone that reads `phone`: its
    /// `meta.json` names a raw format version the phone advertises.
    static func mayDeliver(folder: URL, toPhoneReading phone: Set<Int>) -> Bool {
        let data = try? Data(contentsOf: folder.appendingPathComponent(RawFormat.metaFileName))
        return mayDeliver(version: data.flatMap(metaVersion), toPhoneReading: phone)
    }

    /// The raw format version a `meta.json` declares, read from its header alone so a
    /// version this build cannot decode is still known; nil if it is not a raw recording's.
    static func metaVersion(_ data: Data) -> Int? {
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
            header.format == RawFormat.formatName
        else { return nil }
        return header.version
    }

    /// Whether the phone may acknowledge this `meta.json`: only a version it reads. Until
    /// then the watch keeps the recording.
    static func acknowledgesMeta(_ data: Data) -> Bool {
        guard let version = metaVersion(data) else { return false }
        return RawFormat.readableVersions.contains(version)
    }

    /// Whether settings go to and come from the other device. A Debug launch with
    /// `-demoSession` (UI tests, screenshots) keeps its settings to itself: it neither applies
    /// the paired device's settings (which would undo `-resetSettings` and leak one test's
    /// edits into the next) nor sends its own (which would overwrite the paired device's).
    let syncsSettings: Bool

    /// Whether a launch with these arguments syncs settings (`syncsSettings`).
    static func syncsSettings(arguments: [String]) -> Bool {
        !DemoFeed.isEnabled(arguments: arguments)
    }

    init(syncsSettings: Bool = RecordingTransfer.syncsSettings(arguments: ProcessInfo.processInfo.arguments)) {
        self.syncsSettings = syncsSettings
        super.init()
    }

    /// Folder names of recordings being written right now; never sent or deleted.
    private let active = Mutex<Set<String>>([])
    /// The phone's latest list of stored files per recording, for the diagnostics (watch side).
    private let phoneHolds = Mutex<[String: [String: Int64]]>([:])

    private var log: TransferLog { .shared }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Marks a recording as in progress (or not). Called by SessionRecorder on both devices.
    func markActive(_ folder: URL, _ isActive: Bool) {
        active.withLock { set in
            if isActive { set.insert(folder.lastPathComponent) } else { set.remove(folder.lastPathComponent) }
        }
    }

    private func isActive(_ name: String) -> Bool {
        active.withLock { $0.contains(name) }
    }

    /// Whether a recording folder is still being written on this device.
    func isRecording(_ folder: URL) -> Bool {
        isActive(folder.lastPathComponent)
    }

    // MARK: Watch: sending

    #if os(watchOS)
        /// Queues every file of `folder` that is not already in flight, after cancelling the
        /// outstanding transfers `requeue` selects (`shouldRequeue`).
        func send(folder: URL, requeue: Requeue = .none) {
            let session = WCSession.default
            let sessionId = folder.lastPathComponent
            guard !isActive(sessionId) else { return }
            guard session.activationState == .activated else {
                log.add("Not sent: the connection to iPhone is not active yet", sessionId: sessionId)
                return
            }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter(RecordingStore.isRecordingFileName)
            guard !files.isEmpty else {
                log.add("Not sent: no recording files in the folder", sessionId: sessionId)
                return
            }
            guard phoneReads(folder: folder) else {
                let phone = Self.phoneRawVersions(fromContext: session.receivedApplicationContext)
                let data = try? Data(contentsOf: folder.appendingPathComponent(RawFormat.metaFileName))
                if let version = data.flatMap(Self.metaVersion) {
                    log.add(
                        "Not sent: the iPhone app reads raw versions \(phone.sorted()), not \(version)",
                        sessionId: sessionId)
                } else {
                    log.add("Not sent: meta.json is missing or unreadable", sessionId: sessionId)
                }
                return
            }

            let now = Date()
            var inFlight = Set<String>()
            for transfer in session.outstandingFileTransfers
            where transfer.file.metadata?[Key.sessionId] as? String == sessionId {
                guard let name = transfer.file.metadata?[Key.file] as? String else { continue }
                let queuedAt = Self.queuedAt(metadata: transfer.file.metadata)
                if Self.shouldRequeue(queuedAt: queuedAt, now: now, requeue: requeue) {
                    transfer.cancel()
                    let age = queuedAt.map { "\(Int(now.timeIntervalSince($0) / 60)) min" } ?? "an earlier build"
                    log.add(
                        "Cancelled \(name) to send it again (queued \(age) ago, "
                            + "\(Int(transfer.progress.fractionCompleted * 100))% sent)",
                        sessionId: sessionId)
                } else {
                    inFlight.insert(name)
                }
            }
            let ordered = files.filter { $0 != RawFormat.metaFileName } + files.filter { $0 == RawFormat.metaFileName }
            let queued = ordered.filter { !inFlight.contains($0) }
            for name in queued {
                session.transferFile(
                    folder.appendingPathComponent(name),
                    metadata: [Key.sessionId: sessionId, Key.file: name, Key.queuedAt: now.timeIntervalSince1970])
            }
            if !queued.isEmpty { log.add("Queued \(queued.joined(separator: ", "))", sessionId: sessionId) }
            // Only when asked to send now (launch, Send again), not on every settings update.
            if !inFlight.isEmpty, requeue != .none {
                log.add("Still sending \(inFlight.sorted().joined(separator: ", "))", sessionId: sessionId)
            }
        }

        /// The transfers of one recording still queued or in progress.
        func outstanding(sessionId: String) -> [Outstanding] {
            WCSession.default.outstandingFileTransfers
                .filter { $0.file.metadata?[Key.sessionId] as? String == sessionId }
                .map { transfer in
                    Outstanding(
                        file: transfer.file.metadata?[Key.file] as? String ?? transfer.file.fileURL.lastPathComponent,
                        queuedAt: Self.queuedAt(metadata: transfer.file.metadata),
                        fractionCompleted: transfer.progress.fractionCompleted,
                        isTransferring: transfer.isTransferring)
                }
                .sorted { $0.file < $1.file }
        }

        /// The phone's latest list of stored files for a recording, since this launch.
        func phoneFiles(sessionId: String) -> [String: Int64]? {
            phoneHolds.withLock { $0[sessionId] }
        }

        /// Whether the paired phone's app reads this recording's raw format version. If not
        /// (or the version cannot be read), the recording stays on the watch, which asks for
        /// the phone app to be updated.
        func phoneReads(folder: URL) -> Bool {
            let phone = Self.phoneRawVersions(fromContext: WCSession.default.receivedApplicationContext)
            return Self.mayDeliver(folder: folder, toPhoneReading: phone)
        }

        /// Sends every finished recording still on the watch, including ones interrupted
        /// in an earlier launch (they have no `endedAt`, which readers handle).
        func sendAllPending(requeue: Requeue = .none) {
            for entry in RecordingStore.list() {
                send(folder: entry.folder, requeue: requeue)
            }
        }

        nonisolated func session(
            _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?
        ) {
            // Delivery is not storage: only the phone's acknowledgement allows deleting.
            let sessionId = fileTransfer.file.metadata?[Key.sessionId] as? String
            let name = fileTransfer.file.metadata?[Key.file] as? String ?? fileTransfer.file.fileURL.lastPathComponent
            if let error {
                let nsError = error as NSError
                log.add(
                    "Sending \(name) failed: \(error.localizedDescription) (\(nsError.domain) \(nsError.code))",
                    sessionId: sessionId)
            } else {
                log.add("Handed \(name) to iPhone; waiting for it to confirm", sessionId: sessionId)
            }
        }

        nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
            guard userInfo[Key.stored] as? Bool == true,
                let sessionId = userInfo[Key.sessionId] as? String,
                UUID(uuidString: sessionId) != nil
            else { return }
            guard let phone = Self.phoneFiles(fromAcknowledgement: userInfo) else {
                log.add(
                    "iPhone confirmed a file without listing its files (older iPhone build); ignored",
                    sessionId: sessionId)
                return
            }
            phoneHolds.withLock { $0[sessionId] = phone }
            log.add("iPhone holds \(TransferLog.describe(phone))", sessionId: sessionId)
            deleteIfDelivered(sessionId: sessionId, phone: phone)
        }

        /// Deletes the recording if `phone`, the phone's latest list for it, holds all of it.
        private func deleteIfDelivered(sessionId: String, phone: [String: Int64]) {
            guard !isActive(sessionId) else { return }
            let folder = RecordingStore.root.appendingPathComponent(sessionId, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            guard let local = Self.recordingFiles(in: folder) else {
                log.add("Kept on watch: could not list its files", sessionId: sessionId)
                return
            }
            let gaps = Self.deliveryGaps(local: local, phone: phone)
            guard gaps.isEmpty else {
                log.add("Kept on watch: \(gaps.joined(separator: "; "))", sessionId: sessionId)
                return
            }
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                log.add("Could not remove the delivered recording: \(error.localizedDescription)", sessionId: sessionId)
                return
            }
            log.add("Removed from watch: iPhone holds all \(local.count) files", sessionId: sessionId)
            // Copies re-queued after a stall have nothing left to send.
            for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.metadata?[Key.sessionId] as? String == sessionId {
                transfer.cancel()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didDeliverRecording, object: nil)
            }
        }
    #endif

    // MARK: Phone: receiving

    #if os(iOS)
        /// Stores the file before returning (WatchConnectivity deletes it afterwards), then
        /// acknowledges it. Nothing is acknowledged unless it is safely on disk.
        nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
            guard let sessionId = (file.metadata?[Key.sessionId] as? String)?.lowercased(),
                let name = file.metadata?[Key.file] as? String,
                UUID(uuidString: sessionId) != nil,
                RecordingStore.isRecordingFileName(name)
            else {
                log.add(
                    "Ignored a file without valid metadata (\(file.fileURL.lastPathComponent))",
                    sessionId: file.metadata?[Key.sessionId] as? String)
                return
            }
            if name == RawFormat.metaFileName {
                let data = (try? Data(contentsOf: file.fileURL)) ?? Data()
                if !Self.acknowledgesMeta(data) {
                    // A version this build cannot read: not stored, not acknowledged, so the
                    // watch keeps the recording until this app is updated.
                    let version = Self.metaVersion(data).map(String.init) ?? "unreadable"
                    log.add(
                        "Rejected meta.json (\(data.count) bytes): raw version \(version); this build reads "
                            + "\(RawFormat.readableVersions.sorted())",
                        sessionId: sessionId)
                    return
                }
            }
            let fm = FileManager.default
            let folder = RecordingStore.recordingsRoot.appendingPathComponent(sessionId, isDirectory: true)
            let destination = folder.appendingPathComponent(name)
            // Stage next to the destination (same volume) so replacing is atomic and an old
            // copy survives if anything fails.
            let staged = folder.appendingPathComponent("\(RecordingStore.stagingPrefix)\(UUID().uuidString)-\(name)")
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.moveItem(at: file.fileURL, to: staged)
                let incoming = Self.storedSize(at: staged)
                if let existing = Self.storedSize(at: destination) {
                    // A re-send of a file already stored: a finished recording's files never
                    // change, so the stored copy stays and is not put at risk by replacing.
                    if existing == incoming {
                        try? fm.removeItem(at: staged)
                        log.add("Already had \(name) (\(existing) bytes); kept it", sessionId: sessionId)
                    } else {
                        try Self.replace(destination, with: staged)
                        log.add(
                            "Replaced \(name): \(existing) bytes with \(incoming.map(String.init) ?? "?") bytes",
                            sessionId: sessionId)
                    }
                } else {
                    try fm.moveItem(at: staged, to: destination)
                    log.add("Stored \(name) (\(incoming.map(String.init) ?? "?") bytes)", sessionId: sessionId)
                }
            } catch {
                try? fm.removeItem(at: staged)
                let nsError = error as NSError
                log.add(
                    "Could not store \(name): \(error.localizedDescription) (\(nsError.domain) \(nsError.code))",
                    sessionId: sessionId)
                return
            }
            // What the phone holds now, so a file it lost since an earlier acknowledgement
            // keeps the watch's copy.
            guard let stored = Self.recordingFiles(in: folder) else {
                log.add("Could not list the recording after storing \(name); not confirmed", sessionId: sessionId)
                return
            }
            session.transferUserInfo([
                Key.stored: true, Key.sessionId: sessionId, Key.file: name, Key.files: stored,
            ])
            log.add("Confirmed to watch: \(TransferLog.describe(stored))", sessionId: sessionId)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didReceiveFile, object: nil)
            }
        }

        private static func storedSize(at url: URL) -> Int64? {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
        }

        /// Replaces `destination` with `staged`. If the replace fails after moving the stored
        /// copy aside, it is moved back, so a file the phone acknowledged stays in place
        /// (`NSFileManager.h` names the key only as a string).
        static func replace(_ destination: URL, with staged: URL) throws {
            let fm = FileManager.default
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } catch {
                if !fm.fileExists(atPath: destination.path),
                    let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL
                {
                    try? fm.moveItem(at: original, to: destination)
                }
                throw error
            }
        }

        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            // The user switched watches; activate for the new one.
            session.activate()
        }
    #endif

    // MARK: Settings (both ways)

    // Each device sends its whole settings snapshot as its application context (only the
    // latest is delivered). Every setting carries its own stamp; the receiver takes each
    // setting whose stamp is newer (`SettingsSync`) and answers with its own snapshot when
    // it holds something newer, so both converge. Settings the sender does not send are
    // left alone, so the two apps can run different builds without losing each other's
    // newer settings.
    // Applying runs on the main actor, like local edits, so the two never interleave.

    #if os(iOS)
        /// Resends settings when the watch app is installed (or the pairing changes): an
        /// earlier push returns early while the app is missing.
        nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
            pushSettingsOnMain()
        }
    #else
        /// Resends settings once the iPhone app is installed.
        nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
            pushSettingsOnMain()
        }
    #endif

    /// Sends this device's settings to the other one. If the session cannot send yet,
    /// activation (and the install callbacks above) send them later; the snapshot is read
    /// at that point, so nothing is lost. Main actor only, like every settings write, so a
    /// snapshot's values and revision always come from one consistent state.
    @MainActor
    func pushSettings() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        #if os(iOS)
            guard session.isPaired, session.isWatchAppInstalled else { return }
        #else
            guard session.isCompanionAppInstalled else { return }
        #endif
        var context: [String: Any] = [:]
        if syncsSettings { context[Key.settings] = UserSettings.snapshot() }
        #if os(iOS)
            // Tells the watch which recordings this build can receive.
            context[Key.rawVersions] = Self.readableRawVersions
        #endif
        guard !context.isEmpty else { return }
        do {
            try session.updateApplicationContext(context)
        } catch {
            print("RecordingTransfer: settings update failed: \(error)")
        }
    }

    /// For WatchConnectivity callbacks, which arrive off the main actor.
    nonisolated private func pushSettingsOnMain() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.pushSettings() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        receiveSettings(context)
        #if os(watchOS)
            // The phone may now read recordings it could not before.
            sendAllPending()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didDeliverRecording, object: nil)
            }
        #endif
    }

    /// Hops to the main actor (in arrival order) to apply a snapshot from the other device,
    /// then pushes this device's settings if the other side is behind, or if `alwaysPush`.
    nonisolated private func receiveSettings(_ context: [String: Any], alwaysPush: Bool = false) {
        let snapshot = SendableSnapshot(value: context[Key.settings] as? [String: Any])
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if self.applyReceivedSettings(snapshot.value, alwaysPush: alwaysPush) { self.pushSettings() }
            }
        }
    }

    /// Applies a settings snapshot from the other device (unless this launch keeps its
    /// settings to itself, `syncsSettings`) and returns whether to push this device's context.
    /// An isolated launch still honours `alwaysPush`: its push carries no settings, but the
    /// phone's still tells the watch which recording formats it can receive.
    @MainActor
    func applyReceivedSettings(_ snapshot: [String: Any]?, alwaysPush: Bool = false) -> Bool {
        guard syncsSettings else { return alwaysPush }
        var push = alwaysPush
        if let outcome = snapshot.map({ UserSettings.apply($0) }) {
            if outcome.changed {
                NotificationCenter.default.post(name: UserSettings.didChangeRemotely, object: nil)
                #if os(iOS)
                    // Keep the phone's outgoing context current, for a watch app
                    // reinstalled later.
                    push = true
                #endif
            }
            if outcome.replyNeeded { push = true }
        }
        return push
    }

    /// Property-list values from WatchConnectivity, handed to the main queue unchanged.
    private struct SendableSnapshot: @unchecked Sendable {
        let value: [String: Any]?
    }

    // MARK: Both

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            log.add("Connection to the other device failed: \(error.localizedDescription)")
        }
        guard activationState == .activated else { return }
        log.add("Connected to the other device")
        // Both sides send their settings on activation: an edit made before activation
        // (whose push returned early) goes out now, and the receiver keeps the newer.
        receiveSettings(session.receivedApplicationContext, alwaysPush: true)
        #if os(watchOS)
            // Transfers left stuck since an earlier launch go again.
            sendAllPending(requeue: .stuck)
        #endif
    }
}
