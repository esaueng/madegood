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
        let snapshot: SessionUploadSnapshot
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
    private var journal: Journal?
    private var active: (id: UUID, step: SessionSyncStep)?
    @ObservationIgnored private var draining = false

    init(root: URL, account: VoyageAccount, api: SessionAPI, now: @escaping () -> Date = { .now }) {
        self.root = root
        self.account = account
        self.api = api
        self.now = now
    }

    // MARK: Queue

    /// Session IDs this sign-in has queued, synced or not.
    var queuedIDs: Set<UUID> {
        guard let journal, journal.binding == account.binding else { return [] }
        return Set(journal.entries.map(\.id))
    }

    /// Queues a finished session. `gzipTrack` is its track v1 file; the outbox keeps its
    /// own copy. Queuing a session that is already queued does nothing.
    func enqueue(_ snapshot: SessionUploadSnapshot, for binding: VoyageAccountBinding, gzipTrack: () throws -> Data)
        throws
    {
        var journal = try load(for: binding)
        guard !journal.entries.contains(where: { $0.id == snapshot.sessionID }) else { return }
        let track = try gzipTrack()
        var entry = Entry(snapshot: snapshot)
        if track.count > Self.maxTrackBytes {
            // Queue it as failed, so History says why it never reaches the account.
            entry.failure = .tooLarge
        } else {
            guard Gzip.isGzipped(track), let decoded = try? TrackCodec.decode(track),
                decoded.sessionId == snapshot.sessionID
            else { throw SessionOutboxError.invalidTrack }
            try createPrivateDirectory(for: binding)
            try track.write(to: trackURL(snapshot.sessionID, for: binding), options: Self.privateWriteOptions)
        }
        journal.entries.append(entry)
        try save(journal)
    }

    /// Drops sessions that are not synced yet (their recording was deleted on the phone).
    /// Synced ones stay, so they are not uploaded again.
    func forget(_ ids: Set<UUID>, for binding: VoyageAccountBinding) throws {
        var journal = try load(for: binding)
        let removed = journal.entries.filter { ids.contains($0.id) && !$0.trackSent }
        guard !removed.isEmpty else { return }
        journal.entries.removeAll { entry in removed.contains { $0.id == entry.id } }
        try save(journal)
        for entry in removed { try? FileManager.default.removeItem(at: trackURL(entry.id, for: binding)) }
    }

    func restore(for binding: VoyageAccountBinding) throws {
        journal = try load(for: binding)
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
        for index in journal.entries.indices where !journal.entries[index].trackSent {
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
            active = (entry.id, step)
            var outcome: Result<Void, Error> = .success(())
            do {
                try await account.authorized(for: binding) { bearer in
                    switch step {
                    case .metadata:
                        try await api.putSession(entry.snapshot, bearer: bearer, policy: policy)
                    case .track:
                        try await api.putTrack(
                            file: trackURL(entry.id, for: binding), sessionID: entry.id,
                            taskDescription: Self.taskDescription(binding: binding, sessionID: entry.id),
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
            guard let index = updated.entries.firstIndex(where: { $0.id == entry.id }) else {
                // Forgotten while uploading (the recording was deleted).
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
                record(error, step: step, in: &updated.entries[index])
            }
            try save(updated)
            if updated.entries[index].trackSent {
                try? FileManager.default.removeItem(at: trackURL(entry.id, for: binding))
            }
            active = nil
        }
        return nil
    }

    /// The background upload's task description: the sign-in first, so a sign-out can
    /// cancel exactly that sign-in's uploads (`VoyageTransport.cancelStaleUploads`).
    static func taskDescription(binding: VoyageAccountBinding, sessionID: UUID) -> String {
        binding.signInID.uuidString.lowercased() + "/session/" + sessionID.uuidString.lowercased()
    }

    private func isDue(_ entry: Entry) -> Bool {
        guard !entry.trackSent, entry.failure == nil else { return false }
        return entry.retryAt.map { $0 <= now() } ?? true
    }

    private func status(of entry: Entry) -> SessionSyncStatus {
        if entry.trackSent { return .synced }
        if let active, active.id == entry.id { return .uploading(active.step) }
        if let failure = entry.failure { return .failed(failure) }
        if let retryAt = entry.retryAt { return .retrying(at: retryAt, offline: entry.offline) }
        return .pending
    }

    /// The state machine for a failed step: permanent HTTP errors stop the session,
    /// transient ones back off exponentially up to `maxAttempts`, and offline waits.
    private func record(_ error: Error, step: SessionSyncStep, in entry: inout Entry) {
        let urlError = error as? URLError
        let status = (error as? VoyageAPIError)?.status
        entry.offline = false

        if let urlError, Self.offlineCodes.contains(urlError.code) {
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
        case 404 where step == .track:
            // The server lost the metadata (or never stored it): send it again first.
            entry.metadataSent = false
        case let status? where (400..<500).contains(status) && ![401, 404, 408, 425, 429].contains(status):
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

    private static let offlineCodes: Set<URLError.Code> = [
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
        for folder in folders where folder.lastPathComponent != keep {
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

    private func trackURL(_ id: UUID, for binding: VoyageAccountBinding) -> URL {
        directory(for: binding).appending(path: id.uuidString.lowercased() + ".track.json.gz")
    }

    private static var privateWriteOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            [.atomic]
        #endif
    }
}
