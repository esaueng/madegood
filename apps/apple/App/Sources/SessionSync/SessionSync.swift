import Foundation
import Network
import Observation
import UIKit
import WaterKit

/// Uploads finished sessions to the signed-in MadeGood account (docs/PLAN.md §4.1): the
/// durable `SessionOutbox`, a background URLSession for the track files, and the Settings
/// switches. Nothing is uploaded until the user has signed in and turned sync on.
/// Uploaded sessions take the account's default visibility, which starts private.
@MainActor @Observable
final class SessionSync {
    /// Nil when this build has no API URL (`MADEGOOD_API_URL`) and no demo was requested.
    static let shared: SessionSync? = makeShared()

    let account: VoyageAccount
    let outbox: SessionOutbox
    let isDemo: Bool
    private(set) var queueUnavailable = false
    /// Finished sessions still being prepared (analyzed and frozen) for the queue.
    private(set) var preparing = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            preferences.set(isEnabled, forKey: Self.enabledKey)
            Task { await settingsDidChange() }
        }
    }

    var wifiOnly: Bool {
        didSet {
            guard wifiOnly != oldValue else { return }
            preferences.set(wifiOnly, forKey: Self.wifiOnlyKey)
            // Uploads in flight keep the old policy; restart them under the new one.
            Task { await settingsDidChange() }
        }
    }

    private let transport: any SessionSyncTransport
    private let preferences: UserDefaults
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var rescan = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    static let enabledKey = "sessionSync.enabled"
    static let wifiOnlyKey = "sessionSync.wifiOnly"

    init(
        apiRoot: URL, root: URL, transport: any SessionSyncTransport, store: any VoyageCredentialStore,
        preferences: UserDefaults = .standard, isDemo: Bool = false
    ) {
        account = VoyageAccount(store: store, api: VoyageAPI(baseURL: apiRoot, transport: transport))
        outbox = SessionOutbox(root: root, account: account, api: SessionAPI(baseURL: apiRoot, transport: transport))
        self.transport = transport
        self.preferences = preferences
        self.isDemo = isDemo
        isEnabled = preferences.bool(forKey: Self.enabledKey)
        wifiOnly = preferences.bool(forKey: Self.wifiOnlyKey)
    }

    private var isActive: Bool { isEnabled && account.binding != nil }

    /// The session's place in the queue, or nil when sync is off or it is not queued.
    func status(for sessionID: UUID) -> SessionSyncStatus? {
        guard isActive else { return nil }
        return outbox.status(for: sessionID)
    }

    // MARK: Lifecycle

    func start() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.connectionRestored() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    func accountDidChange() async {
        let binding = account.binding
        if binding == nil { stopWork() }
        // Uploads started by an earlier sign-in must not finish under this one.
        await transport.cancelStaleUploads { account.binding?.signInID }
        guard !Task.isCancelled, account.binding == binding else { return }
        outbox.removeOtherSignIns(keeping: binding)
        guard let binding else { return }
        do {
            try outbox.restore(for: binding)
            queueUnavailable = false
        } catch {
            queueUnavailable = true
            return
        }
        recordingsChanged()
    }

    func signOut() async throws {
        do {
            try account.signOut()
        } catch {
            await accountDidChange()
            throw error
        }
        await accountDidChange()
    }

    private func settingsDidChange() async {
        stopWork()
        // Cancelling every upload task interrupts the drain; the journal keeps its place.
        await transport.cancelStaleUploads { nil }
        guard isActive else { return }
        recordingsChanged()
    }

    /// Cancels the scan, drain and retry timer. A cancelled drain or scan restarts itself
    /// when it ends if sync is still active (a settings change), so two never overlap.
    private func stopWork() {
        worker?.cancel()
        wake?.cancel()
        wake = nil
        scan?.cancel()
    }

    // MARK: Queue

    /// Queues finished recordings that are not queued yet and forgets deleted ones, then
    /// uploads. Call it whenever the library changes.
    func recordingsChanged() {
        guard isActive, let binding = account.binding else { return }
        guard scan == nil else {
            rescan = true
            return
        }
        preparing = true
        scan = Task {
            defer {
                scan = nil
                preparing = false
                let again = rescan || Task.isCancelled
                rescan = false
                if again { recordingsChanged() }
            }
            await enqueueFinishedRecordings(for: binding)
            guard !Task.isCancelled else { return }
            kick()
        }
    }

    func retry(_ sessionID: UUID? = nil) {
        guard isActive, let binding = account.binding else { return }
        do {
            try outbox.retry(sessionID, for: binding)
            kick()
        } catch {
            queueUnavailable = true
        }
    }

    func kick() {
        guard isActive, worker == nil, let binding = account.binding else { return }
        wake?.cancel()
        let policy = SessionNetworkPolicy(allowsCellular: !wifiOnly)
        worker = Task {
            defer {
                worker = nil
                if Task.isCancelled || account.binding != binding { kick() }
            }
            do {
                let retryAt = try await outbox.drain(for: binding, policy: policy)
                guard !Task.isCancelled, account.binding == binding else { return }
                queueUnavailable = false
                if let retryAt {
                    wake = Task {
                        do {
                            try await Task.sleep(for: .seconds(max(1, retryAt.timeIntervalSinceNow)))
                        } catch { return }
                        kick()
                    }
                }
            } catch {
                if account.binding == binding { queueUnavailable = true }
            }
        }
    }

    private func connectionRestored() {
        guard isActive, let binding = account.binding else { return }
        try? outbox.connectionRestored(for: binding)
        kick()
    }

    func reconnect(completion: @escaping () -> Void) {
        guard let transport = transport as? VoyageURLSession else {
            completion()
            return
        }
        transport.reconnect(completion: completion)
        Task { await accountDidChange() }
    }

    /// Freezes each finished recording's analyzed track (trimmed, if the user trimmed it)
    /// into the queue. Analysis runs off the main actor.
    private func enqueueFinishedRecordings(for binding: VoyageAccountBinding) async {
        let entries = RecordingStore.list()
        let present = Set(entries.compactMap { $0.meta?.sessionId })
        do {
            try outbox.forget(outbox.queuedIDs.subtracting(present), for: binding)
        } catch {
            queueUnavailable = true
            return
        }
        for entry in entries {
            guard !Task.isCancelled, account.binding == binding else { return }
            guard let meta = entry.meta, meta.endedAt != nil, !outbox.queuedIDs.contains(meta.sessionId) else {
                continue
            }
            let folder = entry.folder
            let prepared = await Task.detached(priority: .utility) { Self.prepare(folder: folder) }.value
            guard let prepared, !Task.isCancelled, account.binding == binding else { continue }
            do {
                try outbox.enqueue(prepared.snapshot, for: binding) { prepared.gzip }
            } catch is VoyageAccountError {
                return
            } catch {
                // One unreadable recording must not stop the rest; it is tried again on
                // the next library change.
                continue
            }
        }
    }

    private struct Prepared: Sendable {
        let snapshot: SessionUploadSnapshot
        let gzip: Data
    }

    private nonisolated static func prepare(folder: URL) -> Prepared? {
        // A trim that cannot be read waits: uploading the original could share the part
        // the user removed.
        guard let source = SessionLibrary.source(for: folder), let loaded = source.analyze(),
            !loaded.trimUnavailable, let endedAt = loaded.session.meta.endedAt
        else { return nil }
        let selection = loaded.selection
        let track = selection.replay.analyzedTrack(from: selection.track)
        let end =
            loaded.trim == nil
            ? Date(timeIntervalSince1970: endedAt) : track.startedAt.addingTimeInterval(selection.duration)
        guard let gzip = try? TrackCodec.encode(track) else { return nil }
        return Prepared(snapshot: SessionUploadSnapshot(track: track, endedAt: end), gzip: gzip)
    }
}

extension SessionSync {
    /// The API this build talks to: `MADEGOOD_API_URL` in Config/Local.xcconfig, for
    /// example `https:/$()/example.com/api` (xcconfig treats `//` as a comment).
    static var configuredAPIRoot: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MadeGoodAPIURL") as? String,
            let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
            url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost"
        else { return nil }
        return url
    }

    private static func makeShared() -> SessionSync? {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demoSessionSync") { return makeDemo() }
        #endif
        // Demos and UI tests never reach a real account.
        let arguments = ProcessInfo.processInfo.arguments
        guard DemoOffWater.storage == nil, !arguments.contains("-demoSession"), let apiRoot = configuredAPIRoot
        else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "app.madegood"
        return SessionSync(
            apiRoot: apiRoot,
            root: support.appending(path: "SessionSync", directoryHint: .isDirectory),
            transport: VoyageURLSession(backgroundIdentifier: VoyageURLSession.sessionTrackIdentifier),
            store: VoyageKeychain(service: bundle + ".account", account: "madegood-account")
        )
    }
}
