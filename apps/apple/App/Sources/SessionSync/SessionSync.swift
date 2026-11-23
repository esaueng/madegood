import Foundation
import Network
import Observation
import UIKit
import WaterKit

/// Uploads finished sessions to the signed-in MadeGood account (docs/PLAN.md §4.1): the
/// durable `SessionOutbox`, a background URLSession for the track files, and the Settings
/// switches. Nothing is uploaded until the user has signed in and turned sync on for that
/// sign-in, and only recordings that account consented to (`SessionSyncConsent`).
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
    /// Finished recordings this account may receive only by explicit choice.
    private(set) var earlierSessions: [UUID] = []
    private let ledger: SessionConsentLedger
    var consent: SessionSyncConsent { ledger.consent }

    /// "Sync sessions": on only for the sign-in that turned it on.
    var isEnabled: Bool {
        get { consent.isEnabled(for: account.binding) }
        set {
            guard let binding = account.binding, newValue != isEnabled else { return }
            do {
                try ledger.update { $0.setEnabled(newValue, for: binding) }
            } catch {
                queueUnavailable = true
                return
            }
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
    private let api: SessionAPI
    private let preferences: UserDefaults
    private let network: NetworkState
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var reconciled: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var rescan = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    static let wifiOnlyKey = "sessionSync.wifiOnly"

    /// Whether History has a finished recording of the session, as the scan that queues it
    /// requires: not deleted, nor in Recently Deleted. By its metadata, not its folder name,
    /// which the Files app can change.
    static func isInHistory(_ id: UUID) -> Bool {
        RecordingStore.list().contains { $0.meta?.sessionId == id && $0.meta?.endedAt != nil }
    }

    init(
        apiRoot: URL, root: URL, transport: any SessionSyncTransport, store: any VoyageCredentialStore,
        preferences: UserDefaults = .standard, isDemo: Bool = false,
        isOnPhone: @escaping @MainActor (UUID) -> Bool = SessionSync.isInHistory
    ) {
        let network = NetworkState()
        // Consent is recorded before credentials change (write-ahead).
        let guarded = ConsentRecordingStore(store)
        let ledger = SessionConsentLedger(url: root.appending(path: "consent.json"))
        let account = VoyageAccount(store: guarded, api: VoyageAPI(baseURL: apiRoot, transport: transport))
        ledger.guardCredentials(guarded, now: { .now }, isSignedIn: { [weak account] in account?.binding != nil })
        self.account = account
        self.ledger = ledger
        let api = SessionAPI(baseURL: apiRoot, transport: transport)
        self.api = api
        outbox = SessionOutbox(
            root: root, account: account, api: api, networkAvailable: { network.canUpload(under: $0) },
            isOnPhone: isOnPhone)
        self.network = network
        self.transport = transport
        self.preferences = preferences
        self.isDemo = isDemo
        wifiOnly = preferences.bool(forKey: Self.wifiOnlyKey)
    }

    /// True from the start of Delete Account until it fails or the sign-out completes: no
    /// scan, drain or retry may start (review of #78).
    @ObservationIgnored private(set) var deletingAccount = false

    private var isActive: Bool { isEnabled && account.binding != nil && !deletingAccount }
    private var policy: SessionNetworkPolicy { SessionNetworkPolicy(allowsCellular: !wifiOnly) }

    /// The session's place in the queue, or nil when sync is off or it is not queued.
    func status(for sessionID: UUID) -> SessionSyncStatus? {
        guard isActive, let binding = account.binding else { return nil }
        if consent.deletedFromCloud[binding.accountID]?.contains(sessionID) == true {
            return .failed(.deletedFromCloud)
        }
        return outbox.status(for: sessionID)
    }

    // MARK: Lifecycle

    /// Call at every launch, including a background relaunch for finished uploads, before
    /// anything else: creates the background session with its delegate, then cancels every
    /// upload the current settings no longer allow (sync turned off, a sign-out or Wi-Fi
    /// only saved just before the process ended).
    func launch() {
        guard !launched else { return }
        launched = true
        transport.activate { [weak self] description, status in
            self?.outbox.recordBackgroundCompletion(taskDescription: description, statusCode: status)
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in self?.pathChanged(satisfied: satisfied, expensive: expensive) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        reconciled = Task { await reconcileUploads() }
    }

    func accountDidChange() async {
        launch()
        await reconciled?.value
        let binding = account.binding
        if binding == nil {
            // A lost sign-in (failed refresh) never went through the store's sign-out;
            // the window is opened only when credentials are saved, never here.
            try? ledger.update { $0.signedOut(at: .now) }
            stopWork()
        }
        // Uploads started by an earlier sign-in must not finish under this one.
        await reconcileUploads()
        guard !Task.isCancelled, account.binding == binding else { return }
        // A sign-out drops that sign-in's queue and frozen tracks.
        outbox.removeOtherSignIns(keeping: binding)
        guard let binding else {
            earlierSessions = []
            return
        }
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

    /// Deletes the account on the server, then signs out: the upload queue, frozen tracks,
    /// saved tokens and this account's sync consent are removed. Recordings stay on the
    /// device. On failure the sign-in is kept (unless its token could not be refreshed).
    func deleteAccount() async throws {
        // Sync is off for the whole request: nothing may be uploaded to an account that is
        // going away. `deletingAccount` keeps the cancelled worker's own restart (its defer
        // calls kick) and any retry or scan from starting a drain, and background track
        // uploads are cancelled before DELETE is sent. A failure turns sync back on.
        deletingAccount = true
        stopWork()
        await worker?.value
        await scan?.value
        await transport.reconcileUploads { _, _ in false }
        do {
            try await AccountDeletion.delete(account: account, api: api, ledger: ledger)
        } catch {
            deletingAccount = false
            await accountDidChange()
            throw error
        }
        await accountDidChange()
        deletingAccount = false
    }

    /// Runs one account request (Settings → Sharing) with the signed-in account's token,
    /// refreshed once if the server refuses it. Throws `signInRequired` when signed out or
    /// when the account changed before it ran.
    func withAccount<Result>(_ operation: (SessionAPI, String) async throws -> Result) async throws -> Result {
        guard let binding = account.binding else { throw VoyageAccountError.signInRequired }
        var result: Result?
        try await account.authorized(for: binding) { token in result = try await operation(api, token) }
        guard let result else { throw VoyageAPIError.invalidResponse }
        return result
    }

    private func settingsDidChange() async {
        stopWork()
        // The drain is interrupted; the journal keeps its place.
        await reconcileUploads()
        guard account.binding != nil else { return }
        recordingsChanged()
    }

    private func reconcileUploads() async {
        let binding = account.binding
        let enabled = isActive
        let policy = policy
        // The journal decides which generation of each session may still be uploading.
        if let binding { try? outbox.restore(for: binding) }
        let outbox = outbox
        await transport.reconcileUploads { description, request in
            outbox.shouldKeepUpload(
                taskDescription: description, allowsCellular: request?.allowsCellularAccess ?? true,
                binding: binding, syncEnabled: enabled, policy: policy)
        }
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

    /// Queues or re-snapshots finished recordings this account may receive, forgets deleted
    /// ones, then uploads. Call it whenever the library or a trim changes.
    func recordingsChanged() {
        guard account.binding != nil, launched, !deletingAccount else { return }
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
            await reconciled?.value
            guard let binding = account.binding else { return }
            await updateQueue(for: binding)
            guard !Task.isCancelled else { return }
            kick()
        }
    }

    /// The user chose to upload the earlier sessions to the signed-in account.
    func uploadEarlierSessions() {
        guard let binding = account.binding, !earlierSessions.isEmpty else { return }
        let chosen = earlierSessions
        do {
            try ledger.update { $0.adopt(chosen, for: binding) }
        } catch {
            queueUnavailable = true
            return
        }
        earlierSessions = []
        recordingsChanged()
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
        guard isActive, launched, worker == nil, let binding = account.binding else { return }
        wake?.cancel()
        let policy = policy
        worker = Task {
            defer {
                worker = nil
                if Task.isCancelled || account.binding != binding { kick() }
            }
            await reconciled?.value
            guard !Task.isCancelled else { return }
            do {
                let retryAt: Date?
                do {
                    retryAt = try await outbox.drain(for: binding, policy: policy)
                } catch {
                    if outbox.takeDroppedDeleted() { await reconcileUploads() }
                    throw error
                }
                if outbox.takeDroppedDeleted() { await reconcileUploads() }
                // Deleted on the server: never queued for this account again.
                let deleted = outbox.deletedFromCloudIDs
                if account.binding == binding { try? ledger.update { $0.markDeleted(deleted, for: binding) } }
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

    private func pathChanged(satisfied: Bool, expensive: Bool) {
        network.update(satisfied: satisfied, expensive: expensive)
        guard network.canUpload(under: policy), isActive, let binding = account.binding else { return }
        try? outbox.connectionRestored(for: binding)
        kick()
    }

    func reconnect(completion: @escaping () -> Void) {
        launch()
        guard let transport = transport as? VoyageURLSession else {
            completion()
            return
        }
        transport.reconnect(completion: completion)
        Task { await accountDidChange() }
    }

    /// Freezes each consented, finished recording's analyzed track (trimmed, if the user
    /// trimmed it) into the queue, and re-freezes one whose trim or analysis inputs
    /// changed. Analysis runs off the main actor.
    private func updateQueue(for binding: VoyageAccountBinding) async {
        let entries = RecordingStore.list()
        var earlier: [UUID] = []
        var allowed: Set<UUID> = []
        var held: Set<UUID> = []
        for entry in entries {
            guard let meta = entry.meta, let endedAt = meta.endedAt else { continue }
            switch consent.eligibility(
                sessionID: meta.sessionId, startedAt: Date(timeIntervalSince1970: meta.startedAt),
                endedAt: Date(timeIntervalSince1970: endedAt), for: binding)
            {
            case .automatic: allowed.insert(meta.sessionId)
            case .earlier: earlier.append(meta.sessionId)
            case .otherAccount, .deletedFromCloud: break
            }
        }
        earlierSessions = earlier
        do {
            // Deleted recordings, and any the account may not receive, leave the queue.
            try await forgetAndCancel(outbox.queuedIDs.subtracting(allowed), for: binding)
        } catch {
            queueUnavailable = true
            return
        }
        guard isEnabled else { return }

        for entry in entries {
            guard !Task.isCancelled, account.binding == binding else { return }
            guard let id = entry.meta?.sessionId, allowed.contains(id) else { continue }
            let folder = entry.folder
            guard
                let source = await Task.detached(priority: .utility, operation: { SessionLibrary.source(for: folder) })
                    .value
            else { continue }
            // A trim that cannot be read holds the session: uploading the original could
            // share the part the user removed.
            if source.savedTrim == .unreadable {
                held.insert(id)
                continue
            }
            let revision = Self.revision(of: source)
            guard outbox.needsSnapshot(id, revision: revision) else { continue }
            let prepared = await Task.detached(priority: .utility) { Self.prepare(source) }.value
            // The trim or recording may have changed while it was analyzed; the next scan
            // picks that up.
            guard let prepared, !Task.isCancelled, account.binding == binding,
                SessionLibrary.source(for: folder).map(Self.revision(of:)) == revision
            else { continue }
            do {
                let replacedActive = try outbox.enqueue(prepared.snapshot, revision: revision, for: binding) {
                    prepared.gzip
                }
                // The upload in flight carries the old snapshot: stop it; the drain restarts.
                if replacedActive { worker?.cancel() }
            } catch is VoyageAccountError {
                return
            } catch {
                // One unreadable recording must not stop the rest; it is tried again on
                // the next library change.
                continue
            }
        }
        try? await forgetAndCancel(held, for: binding)
    }

    /// Drops unsynced sessions and stops every upload of them: this process's drain, and a
    /// background track upload a previous process left running (kept at launch while the
    /// session was still queued).
    private func forgetAndCancel(_ ids: Set<UUID>, for binding: VoyageAccountBinding) async throws {
        // Synced sessions stay in the journal and have nothing to stop.
        let queued = ids.intersection(outbox.queuedIDs).filter { outbox.status(for: $0) != .synced }
        guard !queued.isEmpty else { return }
        if try outbox.forget(queued, for: binding) { worker?.cancel() }
        await reconcileUploads()
    }

    private struct Prepared: Sendable {
        let snapshot: SessionUploadSnapshot
        let gzip: Data
    }

    /// The trim and everything else the uploaded snapshot is computed from.
    private nonisolated static func revision(of source: SessionLibrary.Source) -> SessionUploadRevision {
        let trim: String
        switch source.savedTrim {
        case .original: trim = "original"
        case .unreadable: trim = "unreadable"
        case .trimmed(let value):
            trim = value.retainedRanges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
        }
        let analysis = [
            String(describing: source.entry.revision), "autoPause=\(source.autoPause)",
            "analyzer=\(SessionReplay.analyzerVersion)",
        ].joined(separator: "|")
        return SessionUploadRevision(trim: trim, analysis: analysis)
    }

    private nonisolated static func prepare(_ source: SessionLibrary.Source) -> Prepared? {
        guard let loaded = source.analyze(), !loaded.trimUnavailable, let endedAt = loaded.session.meta.endedAt
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

/// The latest network path, for telling "offline" apart from a server that can't be
/// reached on a working network.
@MainActor
private final class NetworkState {
    private var satisfied = true
    private var expensive = false

    func update(satisfied: Bool, expensive: Bool) {
        self.satisfied = satisfied
        self.expensive = expensive
    }

    func canUpload(under policy: SessionNetworkPolicy) -> Bool {
        satisfied && (policy.allowsCellular || !expensive)
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
