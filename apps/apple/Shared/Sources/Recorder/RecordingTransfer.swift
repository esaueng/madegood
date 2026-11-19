import Foundation
import Synchronization
import WatchConnectivity
import WaterKit

/// Moves finished recordings from the watch to the phone.
///
/// - The watch sends each file with `WCSession.transferFile` (each stream is already
///   gzipped), `meta.json` last.
/// - The phone stores each file durably (atomic replace for duplicates) and only then
///   acknowledges it with `transferUserInfo`, which is queued and delivered even if the
///   watch app isn't running.
/// - The watch deletes a recording only when the phone has acknowledged **every** file in
///   it. A transfer that "finished" but wasn't stored is never acknowledged, so the watch
///   keeps the recording and sends it again on the next launch.
/// - The recording in progress is never sent or deleted (`markActive`).
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
    }

    /// Folder names of recordings being written right now; never sent or deleted.
    private let active = Mutex<Set<String>>([])
    /// Files the phone has confirmed storing, by folder name (watch side).
    private let acknowledged = Mutex<[String: Set<String>]>([:])

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
        /// Queues every file of `folder` that is not already in flight.
        func send(folder: URL) {
            let session = WCSession.default
            let sessionId = folder.lastPathComponent
            guard session.activationState == .activated, !isActive(sessionId) else { return }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter(RecordingStore.isRecordingFileName)
            guard !files.isEmpty else { return }

            let inFlight = Set(
                session.outstandingFileTransfers
                    .filter { $0.file.metadata?[Key.sessionId] as? String == sessionId }
                    .compactMap { $0.file.metadata?[Key.file] as? String })
            let ordered = files.filter { $0 != RawFormat.metaFileName } + files.filter { $0 == RawFormat.metaFileName }
            for name in ordered where !inFlight.contains(name) {
                session.transferFile(
                    folder.appendingPathComponent(name),
                    metadata: [Key.sessionId: sessionId, Key.file: name])
            }
        }

        /// Sends every finished recording still on the watch, including ones interrupted
        /// in an earlier launch (they have no `endedAt`, which readers handle).
        func sendAllPending() {
            for entry in RecordingStore.list() {
                send(folder: entry.folder)
            }
        }

        nonisolated func session(
            _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?
        ) {
            // Delivery is not storage: only the phone's acknowledgement allows deleting.
            if let error { print("RecordingTransfer: transfer failed, will retry on next launch: \(error)") }
        }

        nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
            guard userInfo[Key.stored] as? Bool == true,
                let sessionId = userInfo[Key.sessionId] as? String,
                let name = userInfo[Key.file] as? String,
                UUID(uuidString: sessionId) != nil
            else { return }
            let all = acknowledged.withLock { acked -> Set<String> in
                acked[sessionId, default: []].insert(name)
                return acked[sessionId] ?? []
            }
            deleteIfFullyAcknowledged(sessionId: sessionId, acknowledged: all)
        }

        private func deleteIfFullyAcknowledged(sessionId: String, acknowledged acked: Set<String>) {
            guard !isActive(sessionId) else { return }
            let folder = RecordingStore.root.appendingPathComponent(sessionId, isDirectory: true)
            let files = Set(
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter(RecordingStore.isRecordingFileName))
            guard !files.isEmpty, files.isSubset(of: acked) else { return }
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                print("RecordingTransfer: could not remove delivered recording: \(error)")
                return
            }
            acknowledged.withLock { $0[sessionId] = nil }
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
                print("RecordingTransfer: ignoring unexpected file \(file.fileURL.lastPathComponent)")
                return
            }
            let fm = FileManager.default
            let folder = RecordingStore.recordingsRoot.appendingPathComponent(sessionId, isDirectory: true)
            let destination = folder.appendingPathComponent(name)
            // Stage next to the destination (same volume) so replacing is atomic and an old
            // copy survives if anything fails.
            let staged = folder.appendingPathComponent(".incoming-\(UUID().uuidString)-\(name)")
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.moveItem(at: file.fileURL, to: staged)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: destination)
                }
            } catch {
                try? fm.removeItem(at: staged)
                print("RecordingTransfer: could not store \(name); the watch keeps its copy: \(error)")
                return
            }
            session.transferUserInfo([Key.stored: true, Key.sessionId: sessionId, Key.file: name])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didReceiveFile, object: nil)
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
    // latest is delivered). The receiver keeps whichever carries the higher revision
    // (`SettingsSync`) and answers an older one with its own, so both converge. A snapshot
    // lists the keys its sender's build knows, and applying it touches only those, so the
    // two apps can run different builds without losing each other's newer settings.
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
        do {
            try session.updateApplicationContext([Key.settings: UserSettings.snapshot()])
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
    }

    /// Hops to the main actor (in arrival order) to apply a snapshot from the other device,
    /// then pushes this device's settings if the other side is behind, or if `alwaysPush`.
    nonisolated private func receiveSettings(_ context: [String: Any], alwaysPush: Bool = false) {
        let snapshot = SendableSnapshot(value: context[Key.settings] as? [String: Any])
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var push = alwaysPush
                switch snapshot.value.map({ UserSettings.apply($0) }) {
                case .applied:
                    NotificationCenter.default.post(name: UserSettings.didChangeRemotely, object: nil)
                    #if os(iOS)
                        // Keep the phone's outgoing context current, for a watch app
                        // reinstalled later.
                        push = true
                    #endif
                case .merged:
                    // Kept values the other build does not know, under a newer revision.
                    NotificationCenter.default.post(name: UserSettings.didChangeRemotely, object: nil)
                    push = true
                case .keptLocalNewer:
                    push = true
                case .unchanged, nil:
                    break
                }
                if push { self.pushSettings() }
            }
        }
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
        if let error { print("RecordingTransfer: activation failed: \(error)") }
        guard activationState == .activated else { return }
        // Both sides send their settings on activation: an edit made before activation
        // (whose push returned early) goes out now, and the receiver keeps the newer.
        receiveSettings(session.receivedApplicationContext, alwaysPush: true)
        #if os(watchOS)
            sendAllPending()
        #endif
    }
}
