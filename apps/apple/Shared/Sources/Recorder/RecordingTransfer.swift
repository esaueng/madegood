import Foundation
import Synchronization
import WatchConnectivity
import WaterKit

/// Moves finished recordings from the watch to the phone with `WCSession.transferFile`,
/// one file per transfer (each stream is already gzipped). The watch keeps a recording
/// until every file has been delivered, and re-sends unfinished ones on the next launch;
/// the phone overwrites duplicates, so re-sending is safe.
///
/// The watch never talks to the API (docs/PLAN.md §4.1); the phone is the hub.
final class RecordingTransfer: NSObject, WCSessionDelegate, Sendable {
    static let shared = RecordingTransfer()

    /// Posted on the main queue when the phone has received a file.
    static let didReceiveFile = Notification.Name("RecordingTransfer.didReceiveFile")
    /// Posted on the main queue when the watch has delivered every file of a recording.
    static let didDeliverRecording = Notification.Name("RecordingTransfer.didDeliverRecording")

    private enum Key {
        static let sessionId = "sessionId"
        static let file = "file"
    }

    /// Files still in flight, by session folder name (watch side).
    private let pending = Mutex<[String: Set<String>]>([:])

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Watch: sending

    #if os(watchOS)
        /// Queues every file of `folder`. Call after a recording stops, and on launch for
        /// recordings that were not fully delivered.
        func send(folder: URL) {
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            let sessionId = folder.lastPathComponent
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter(RecordingStore.isRecordingFileName)
            guard !files.isEmpty else { return }

            let inFlight = Set(
                session.outstandingFileTransfers
                    .filter { $0.file.metadata?[Key.sessionId] as? String == sessionId }
                    .compactMap { $0.file.metadata?[Key.file] as? String })
            pending.withLock { $0[sessionId, default: []].formUnion(files) }
            // meta.json last: the phone lists a recording once its meta.json arrives.
            let ordered = files.filter { $0 != RawFormat.metaFileName } + files.filter { $0 == RawFormat.metaFileName }
            for name in ordered where !inFlight.contains(name) {
                session.transferFile(
                    folder.appendingPathComponent(name),
                    metadata: [Key.sessionId: sessionId, Key.file: name])
            }
        }

        /// Re-sends every recording still on the watch.
        func sendAllPending() {
            for entry in RecordingStore.list() {
                send(folder: entry.folder)
            }
        }

        nonisolated func session(
            _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?
        ) {
            guard error == nil,
                  let sessionId = fileTransfer.file.metadata?[Key.sessionId] as? String,
                  let name = fileTransfer.file.metadata?[Key.file] as? String
            else {
                if let error { print("RecordingTransfer: transfer failed: \(error)") }
                return
            }
            let done = pending.withLock { pending -> Bool in
                pending[sessionId, default: []].remove(name)
                guard pending[sessionId]?.isEmpty == true else { return false }
                pending[sessionId] = nil
                return true
            }
            guard done else { return }
            // Delivered: the phone now holds the copy.
            try? FileManager.default.removeItem(at: RecordingStore.root.appendingPathComponent(sessionId))
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didDeliverRecording, object: nil)
            }
        }
    #endif

    // MARK: Phone: receiving

    #if os(iOS)
        /// Must move the file before returning: WatchConnectivity deletes it afterwards.
        nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
            guard let sessionId = file.metadata?[Key.sessionId] as? String,
                  let name = file.metadata?[Key.file] as? String,
                  UUID(uuidString: sessionId) != nil,
                  RecordingStore.isRecordingFileName(name)
            else {
                print("RecordingTransfer: ignoring unexpected file \(file.fileURL.lastPathComponent)")
                return
            }
            let fm = FileManager.default
            let folder = RecordingStore.root.appendingPathComponent(sessionId.lowercased(), isDirectory: true)
            let destination = folder.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: file.fileURL, to: destination)
            } catch {
                print("RecordingTransfer: could not store \(name): \(error)")
                return
            }
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

    // MARK: Both

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        if let error { print("RecordingTransfer: activation failed: \(error)") }
        #if os(watchOS)
            if activationState == .activated { sendAllPending() }
        #endif
    }
}
