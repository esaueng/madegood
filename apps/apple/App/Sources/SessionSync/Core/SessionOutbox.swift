import Foundation
import Observation
import WaterKit

enum SessionSyncStep: String, Codable, Sendable {
    case metadata, track
}

/// Why a session stopped retrying on its own. Retry clears it.
enum SessionSyncFailure: Codable, Equatable, Sendable {
    /// Transient failures (offline excepted) reached `SessionOutbox.maxAttempts`.
    case retriesExhausted(status: Int?)
    /// 409: another account already has a session with this ID.
    case conflict
    /// 413: the track is larger than the API accepts.
    case tooLarge
    /// Another 4xx, for example a body the API rejects.
    case rejected(status: Int)
    /// 410: the user deleted the session from their account. It is never sent again.
    case deletedFromCloud
}

/// One session's place in the upload queue.
enum SessionSyncStatus: Equatable, Sendable {
    case pending
    case uploading(SessionSyncStep)
    case synced
    /// A transient failure; the queue retries at `retryAt`.
    case retrying(at: Date, offline: Bool)
    case failed(SessionSyncFailure)
}

/// What a queued snapshot was made from. `trim` covers the part of the recording that is
/// shared; `analysis` covers everything else that shapes the upload (raw files, settings,
/// analyzer). Both are opaque fingerprints from the app.
struct SessionUploadRevision: Codable, Equatable, Sendable {
    var trim: String
    var analysis: String

    static let unversioned = SessionUploadRevision(trim: "", analysis: "")
}

enum SessionOutboxError: Error, Equatable {
    case invalidTrack
    case invalidJournal
}

/// The durable upload queue for finished sessions. A journal per sign-in records each
/// session's frozen metadata and acknowledged steps; a frozen copy of the gzipped track
/// makes every retry send the same bytes. Metadata goes first, then the track.
@MainActor @Observable
final class SessionOutbox {
    /// Transient failures before a session stops retrying on its own. Offline attempts
    /// do not count: the queue waits for a connection instead.
    static let maxAttempts = 8
    /// The API's track limit (web/src/server/lib/track.ts).
    static let maxTrackBytes = 8 * 1024 * 1024
    static let firstRetryDelay: TimeInterval = 10
    static let maxRetryDelay: TimeInterval = 3600
    static let offlineRetryDelay: TimeInterval = 60

    private struct Journal: Codable {
        let binding: VoyageAccountBinding
        var entries: [Entry] = []
    }

    private struct Entry: Codable {
        var snapshot: SessionUploadSnapshot
        var revision: SessionUploadRevision
        /// Changes whenever the snapshot is replaced, so a request for an older snapshot
        /// can never acknowledge the new one. The frozen track is stored per generation.
        var generation = UUID()
        /// Sent as `revision` with both PUTs; increases with each replacement, so the
        /// server rejects a delayed request for an older snapshot (412).
        var uploadRevision: Int64
        var metadataSent = false
        var trackSent = false
        var attempts = 0
        var retryAt: Date?
        var offline = false
        var failure: SessionSyncFailure?
        var id: UUID { snapshot.sessionID }
    }

    private let root: URL
    private let account: VoyageAccount
    private let api: SessionAPI
    private let now: () -> Date
    private let networkAvailable: @MainActor (SessionNetworkPolicy) -> Bool
    private var journal: Journal?
    private var active: (id: UUID, generation: UUID, step: SessionSyncStep)?
    @ObservationIgnored private var draining = false

    /// `networkAvailable` reports whether the current network path can carry an upload
    /// under the policy (NWPathMonitor in the app). Connection errors count as offline only
    /// when it says no; otherwise they use up attempts like any transient failure.
    init(
        root: URL, account: VoyageAccount, api: SessionAPI, now: @escaping () -> Date = { .now },
        networkAvailable: @escaping @MainActor (SessionNetworkPolicy) -> Bool = { _ in true }
    ) {
        self.root = root
        self.account = account
        self.api = api
        self.now = now
        self.networkAvailable = networkAvailable
    }

    // MARK: Queue

    /// Session IDs this sign-in has queued, synced or not.
    var queuedIDs: Set<UUID> {
        guard let journal, journal.binding == account.binding else { return [] }
        return Set(journal.entries.map(\.id))
    }

    /// Whether `revision` needs a new snapshot: the session is not queued, or any recorded
    /// input differs, whether or not the old snapshot already synced (both PUTs replace
    /// what the account stores, at a higher upload revision). A session deleted from the
    /// account never does.
    func needsSnapshot(_ id: UUID, revision: SessionUploadRevision) -> Bool {
        guard let journal, journal.binding == account.binding,
            let entry = journal.entries.first(where: { $0.id == id })
        else { return true }
        return entry.failure != .deletedFromCloud && entry.revision != revision
    }

    /// Sessions the server reported as deleted from the account (410).
    var deletedFromCloudIDs: Set<UUID> {
        guard let journal, journal.binding == account.binding else { return [] }
        return Set(journal.entries.filter { $0.failure == .deletedFromCloud }.map(\.id))
    }

    /// Queues a finished session, or replaces its snapshot when `needsSnapshot` says so.
    /// `gzipTrack` is its track v1 file; the outbox keeps its own copy. A replaced session
    /// starts over with metadata, then the track. Returns true when the replaced session
    /// was being uploaded, so the caller can cancel that request.
    @discardableResult
    func enqueue(
        _ snapshot: SessionUploadSnapshot, revision: SessionUploadRevision = .unversioned,
        for binding: VoyageAccountBinding, gzipTrack: () throws -> Data
    ) throws -> Bool {
        var journal = try load(for: binding)
        let index = journal.entries.firstIndex { $0.id == snapshot.sessionID }
        if index != nil, !needsSnapshot(snapshot.sessionID, revision: revision) { return false }
        let track = try gzipTrack()
        let previous = index.map { journal.entries[$0] }
        let millis = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        var entry = Entry(
            snapshot: snapshot, revision: revision,
            uploadRevision: max(millis, (previous?.uploadRevision ?? 0) + 1))
        // The new generation's file is written first and the old one removed only after
        // the journal points at the new one, so a crash never pairs a track with the
        // wrong snapshot.
        let file = trackURL(snapshot.sessionID, generation: entry.generation, for: binding)
        if track.count > Self.maxTrackBytes {
            // Queue it as failed, so History says why it never reaches the account.
            entry.failure = .tooLarge
        } else {
            guard Gzip.isGzipped(track), let decoded = try? TrackCodec.decode(track),
                decoded.sessionId == snapshot.sessionID
            else { throw SessionOutboxError.invalidTrack }
            try createPrivateDirectory(for: binding)
            try track.write(to: file, options: Self.privateWriteOptions)
        }
        let wasActive = active?.id == snapshot.sessionID
        if let index {
            journal.entries[index] = entry
        } else {
            journal.entries.append(entry)
        }
        do {
            try save(journal)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        if let previous {
            try? FileManager.default.removeItem(at: trackURL(previous.id, generation: previous.generation, for: binding))
        }
        return wasActive
    }

    /// Drops sessions that are not synced yet (their recording was deleted on the phone).
    /// Synced ones stay, so they are not uploaded again.
    @discardableResult
    func forget(_ ids: Set<UUID>, for binding: VoyageAccountBinding) throws -> Bool {
        var journal = try load(for: binding)
        let removed = journal.entries.filter { ids.contains($0.id) && !$0.trackSent }
        guard !removed.isEmpty else { return false }
        let wasActive = active.map { active in removed.contains { $0.id == active.id } } ?? false
        journal.entries.removeAll { entry in removed.contains { $0.id == entry.id } }
        try save(journal)
        for entry in removed {
            try? FileManager.default.removeItem(at: trackURL(entry.id, generation: entry.generation, for: binding))
        }
        return wasActive
    }

    func restore(for binding: VoyageAccountBinding) throws {
        let restored = try load(for: binding)
        journal = restored
        // Frozen tracks the journal no longer points at (a crash between writing a new
        // generation and removing the old one).
        let keep = Set(
            restored.entries.filter { !$0.trackSent }.map {
                trackURL($0.id, generation: $0.generation, for: binding).lastPathComponent
            })
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory(for: binding), includingPropertiesForKeys: nil))
            ?? []
        for file in files where file.lastPathComponent.hasSuffix(".track.json.gz") && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func status(for id: UUID) -> SessionSyncStatus? {
        guard let journal, journal.binding == account.binding,
            let entry = journal.entries.first(where: { $0.id == id })
        else { return nil }
        return status(of: entry)
    }

    var statuses: [UUID: SessionSyncStatus] {
        guard let journal, journal.binding == account.binding else { return [:] }
        return Dictionary(uniqueKeysWithValues: journal.entries.map { ($0.id, status(of: $0)) })
    }

    /// Clears the failure and backoff of one session (or of all that are not synced), so
    /// the next drain sends it right away.
    func retry(_ id: UUID? = nil, for binding: VoyageAccountBinding) throws {
        var journal = try load(for: binding)
        for index in journal.entries.indices
        where !journal.entries[index].trackSent && journal.entries[index].failure != .deletedFromCloud {
            guard id == nil || journal.entries[index].id == id else { continue }
            journal.entries[index].failure = nil
            journal.entries[index].retryAt = nil
            journal.entries[index].attempts = 0
            journal.entries[index].offline = false
        }
        try save(journal)
    }

    /// A connection came back: sessions that were waiting for one are due now. Their
    /// attempt counts are unchanged.
    func connectionRestored(for binding: VoyageAccountBinding) throws {
        var journal = try load(for: binding)
        var changed = false
        for index in journal.entries.indices
        where journal.entries[index].offline && !journal.entries[index].trackSent {
            journal.entries[index].retryAt = nil
            journal.entries[index].offline = false
            changed = true
        }
        if changed { try save(journal) }
    }

    // MARK: Draining

    /// Uploads every due session in queue order and returns the next retry time, if any.
    func drain(for binding: VoyageAccountBinding, policy: SessionNetworkPolicy) async throws -> Date? {
        guard !draining else { return nil }
        draining = true
        defer {
            draining = false
            active = nil
        }
        while !Task.isCancelled, account.binding == binding {
            let journal = try load(for: binding)
            guard let entry = journal.entries.first(where: isDue) else {
                return journal.entries.filter { !$0.trackSent && $0.failure == nil }.compactMap(\.retryAt).min()
            }
            let step: SessionSyncStep = entry.metadataSent ? .track : .metadata
            active = (entry.id, entry.generation, step)
            var outcome: Result<Void, Error> = .success(())
            do {
                try await account.authorized(for: binding) { bearer in
                    switch step {
                    case .metadata:
                        try await api.putSession(
                            entry.snapshot, revision: entry.uploadRevision, bearer: bearer, policy: policy)
                    case .track:
                        try await api.putTrack(
                            file: trackURL(entry.id, generation: entry.generation, for: binding),
                            sessionID: entry.id, revision: entry.uploadRevision,
                            taskDescription: Self.taskDescription(
                                binding: binding, sessionID: entry.id, generation: entry.generation),
                            bearer: bearer, policy: policy)
                    }
                }
            } catch {
                // Signed out, or the account changed: the journal belongs to that sign-in.
                if error is VoyageAccountError { return nil }
                guard !Task.isCancelled, account.binding == binding else { return nil }
                if account.storageUnavailable { throw error }
                outcome = .failure(error)
            }
            // Re-read: another session may have been queued during the request.
            var updated = try load(for: binding)
            guard
                let index = updated.entries.firstIndex(where: {
                    $0.id == entry.id && $0.generation == entry.generation
                })
            else {
                // Forgotten (the recording was deleted) or replaced (re-trimmed) while
                // uploading: this request's result belongs to the old snapshot.
                active = nil
                continue
            }
            switch outcome {
            case .success:
                switch step {
                case .metadata: updated.entries[index].metadataSent = true
                case .track: updated.entries[index].trackSent = true
                }
                updated.entries[index].attempts = 0
                updated.entries[index].retryAt = nil
                updated.entries[index].offline = false
                updated.entries[index].failure = nil
            case .failure(let error):
                record(error, step: step, policy: policy, in: &updated.entries[index])
            }
            try save(updated)
            if updated.entries[index].trackSent {
                try? FileManager.default.removeItem(at: trackURL(entry.id, generation: entry.generation, for: binding))
            }
            active = nil
        }
        return nil
    }

    /// The background upload's task description: `<sign-in>/session/<id>/<generation>`.
    /// The sign-in comes first, so a sign-out can cancel exactly that sign-in's uploads.
    static func taskDescription(binding: VoyageAccountBinding, sessionID: UUID, generation: UUID) -> String {
        [binding.signInID.uuidString, "session", sessionID.uuidString, generation.uuidString]
            .joined(separator: "/").lowercased()
    }

    private static func parse(taskDescription: String) -> (signIn: UUID, session: UUID, generation: UUID)? {
        let parts = taskDescription.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[1] == "session", let signIn = UUID(uuidString: parts[0]),
            let session = UUID(uuidString: parts[2]), let generation = UUID(uuidString: parts[3])
        else { return nil }
        return (signIn, session, generation)
    }

    /// A background track upload finished, possibly while no drain was waiting for it (the
    /// app was relaunched in the background). A success is journalled directly, so the
    /// track is not sent again; anything else is left for the drain to retry.
    func recordBackgroundCompletion(taskDescription: String, statusCode: Int?) {
        guard let statusCode, (200..<300).contains(statusCode),
            let parsed = Self.parse(taskDescription: taskDescription), let binding = account.binding,
            binding.signInID == parsed.signIn, var journal = try? load(for: binding),
            let index = journal.entries.firstIndex(where: {
                $0.id == parsed.session && $0.generation == parsed.generation
            }),
            journal.entries[index].metadataSent, !journal.entries[index].trackSent
        else { return }
        journal.entries[index].trackSent = true
        journal.entries[index].attempts = 0
        journal.entries[index].retryAt = nil
        journal.entries[index].offline = false
        journal.entries[index].failure = nil
        guard (try? save(journal)) != nil else { return }
        try? FileManager.default.removeItem(
            at: trackURL(parsed.session, generation: parsed.generation, for: binding))
    }

    /// Whether a background upload task may keep running: it belongs to the signed-in
    /// sign-in, sync is on, it was started under the current network policy, and it
    /// carries the journal's current, unsent generation of that session. Everything else
    /// is cancelled at launch and on every change, so after a crash no older snapshot's
    /// upload can still be running next to the current one.
    func shouldKeepUpload(
        taskDescription: String?, allowsCellular: Bool, binding: VoyageAccountBinding?, syncEnabled: Bool,
        policy: SessionNetworkPolicy
    ) -> Bool {
        guard syncEnabled, let binding, let taskDescription,
            let parsed = Self.parse(taskDescription: taskDescription), parsed.signIn == binding.signInID,
            allowsCellular == policy.allowsCellular, let journal = try? load(for: binding),
            let entry = journal.entries.first(where: { $0.id == parsed.session })
        else { return false }
        return entry.generation == parsed.generation && entry.metadataSent && !entry.trackSent
            && entry.failure == nil
    }

    private func isDue(_ entry: Entry) -> Bool {
        guard !entry.trackSent, entry.failure == nil else { return false }
        return entry.retryAt.map { $0 <= now() } ?? true
    }

    private func status(of entry: Entry) -> SessionSyncStatus {
        if entry.trackSent { return .synced }
        if let active, active.id == entry.id, active.generation == entry.generation { return .uploading(active.step) }
        if let failure = entry.failure { return .failed(failure) }
        if let retryAt = entry.retryAt { return .retrying(at: retryAt, offline: entry.offline) }
        return .pending
    }

    /// The state machine for a failed step: permanent HTTP errors stop the session,
    /// transient ones back off exponentially up to `maxAttempts`, and offline waits.
    private func record(
        _ error: Error, step: SessionSyncStep, policy: SessionNetworkPolicy, in entry: inout Entry
    ) {
        let urlError = error as? URLError
        let status = (error as? VoyageAPIError)?.status
        entry.offline = false

        // DNS and refused connections also happen with a working network (a server or
        // configuration problem); only a path that can't carry the upload means offline.
        if let urlError, Self.connectionCodes.contains(urlError.code), !networkAvailable(policy) {
            entry.offline = true
            entry.retryAt = now().addingTimeInterval(Self.offlineRetryDelay)
            return
        }
        switch status {
        case 409:
            entry.failure = .conflict
            entry.retryAt = nil
            return
        case 413:
            entry.failure = .tooLarge
            entry.retryAt = nil
            return
        case 410:
            entry.failure = .deletedFromCloud
            entry.retryAt = nil
            return
        case 404 where step == .track, 412 where step == .track:
            // The server lost the metadata, or holds another revision's: send it first.
            entry.metadataSent = false
        case let status? where (400..<500).contains(status) && ![401, 404, 408, 412, 425, 429].contains(status)
            || (status == 412 && step == .metadata):
            entry.failure = .rejected(status: status)
            entry.retryAt = nil
            return
        default:
            break
        }

        entry.attempts += 1
        guard entry.attempts < Self.maxAttempts else {
            entry.failure = .retriesExhausted(status: status)
            entry.retryAt = nil
            return
        }
        var delay = min(Self.maxRetryDelay, Self.firstRetryDelay * pow(2, Double(entry.attempts - 1)))
        if case .http(_, _, let retryAfter?) = error as? VoyageAPIError, retryAfter.isFinite {
            delay = max(delay, min(retryAfter, 86_400))
        }
        entry.retryAt = now().addingTimeInterval(delay)
    }

    private static let connectionCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]

    // MARK: Storage

    private func load(for binding: VoyageAccountBinding) throws -> Journal {
        guard account.binding == binding else { throw VoyageAccountError.accountChanged }
        if let journal, journal.binding == binding { return journal }
        let result: Journal
        do {
            result = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL(for: binding)))
        } catch CocoaError.fileReadNoSuchFile {
            return Journal(binding: binding)
        }
        guard result.binding == binding, Set(result.entries.map(\.id)).count == result.entries.count else {
            throw SessionOutboxError.invalidJournal
        }
        return result
    }

    private func save(_ updated: Journal) throws {
        guard account.binding == updated.binding else { throw VoyageAccountError.accountChanged }
        try createPrivateDirectory(for: updated.binding)
        try JSONEncoder().encode(updated).write(to: journalURL(for: updated.binding), options: Self.privateWriteOptions)
        journal = updated
    }

    /// Removes the queues of every sign-in except `binding` (all of them when nil).
    func removeOtherSignIns(keeping binding: VoyageAccountBinding?) {
        let keep = binding?.signInID.uuidString.lowercased()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // Only sign-in folders (UUIDs); other files in the root (the consent record) stay.
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil && folder.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: folder)
        }
        if binding == nil { journal = nil }
    }

    private func createPrivateDirectory(for binding: VoyageAccountBinding) throws {
        var directory = directory(for: binding)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func directory(for binding: VoyageAccountBinding) -> URL {
        root.appending(path: binding.signInID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func journalURL(for binding: VoyageAccountBinding) -> URL {
        directory(for: binding).appending(path: "outbox.json")
    }

    private func trackURL(_ id: UUID, generation: UUID, for binding: VoyageAccountBinding) -> URL {
        directory(for: binding).appending(
            path: id.uuidString.lowercased() + "." + generation.uuidString.lowercased() + ".track.json.gz")
    }

    private static var privateWriteOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            [.atomic]
        #endif
    }
}
