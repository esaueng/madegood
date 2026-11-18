import Foundation
import Observation
import WaterKit

enum VoyageSyncStep: String, Codable, Sendable {
    case voyage, leg, track
}

enum VoyageSyncStatus: Equatable, Sendable {
    case onIPhone
    case queued
    case waitingForConnection
    case syncing(VoyageSyncStep)
    case synced
    case retryableFailure(VoyageSyncStep)
    case needsAttention(VoyageSyncStep, status: Int?)
}

enum VoyageOutboxError: Error, Equatable {
    case invalidTrack
    case snapshotChanged
    case invalidJournal
}

@MainActor @Observable
final class VoyageOutbox {
    private struct Journal: Codable {
        let binding: VoyageAccountBinding
        var voyages: [UUID: VoyageEntry] = [:]
        var legs: [LegEntry] = []
    }

    private struct VoyageEntry: Codable {
        let snapshot: VoyageSnapshot
        var acknowledged = false
    }

    private struct LegEntry: Codable {
        let id: UUID
        let voyageID: UUID
        let snapshot: VoyageLegSnapshot
        var metadataSent = false
        var trackSent = false
        var failure: Failure?
    }

    private struct Failure: Codable {
        let step: VoyageSyncStep
        let status: Int?
        let offline: Bool
        let attempts: Int
        let retryAt: Date?
    }

    private let root: URL
    private let account: VoyageAccount
    private let api: VoyageAPI
    private let now: () -> Date
    private var journal: Journal?
    private var activeLeg: UUID?
    @ObservationIgnored private var draining = false

    init(root: URL, account: VoyageAccount, api: VoyageAPI, now: @escaping () -> Date = { .now }) {
        self.root = root
        self.account = account
        self.api = api
        self.now = now
    }

    // The recorder calls this only after an explicit private sync decision, passing
    // the binding captured with that decision. The caller still owns its source file.
    func enqueue(
        _ completed: CompletedVoyageLeg, for binding: VoyageAccountBinding, gzipTrack: () throws -> Data
    ) throws {
        var journal = try load(for: binding)
        if let existing = journal.legs.first(where: { $0.id == completed.legID }) {
            guard existing.voyageID == completed.voyageID, existing.snapshot == completed.leg,
                journal.voyages[completed.voyageID]?.snapshot == completed.voyage
            else { throw VoyageOutboxError.snapshotChanged }
            return
        }
        if let parent = journal.voyages[completed.voyageID], parent.snapshot != completed.voyage {
            throw VoyageOutboxError.snapshotChanged
        }

        let track = try gzipTrack()
        guard track.count <= 8 * 1024 * 1024, Gzip.isGzipped(track),
            let json = try? Gzip.decompress(track, limit: 64 * 1024 * 1024),
            let decoded = try? TrackCodec.decode(json), decoded.sessionId == completed.legID
        else { throw VoyageOutboxError.invalidTrack }

        try createPrivateDirectory(for: binding)
        try track.write(to: trackURL(completed.legID, for: binding), options: Self.privateWriteOptions)
        if journal.voyages[completed.voyageID] == nil {
            journal.voyages[completed.voyageID] = VoyageEntry(snapshot: completed.voyage)
        }
        journal.legs.append(LegEntry(id: completed.legID, voyageID: completed.voyageID, snapshot: completed.leg))
        try save(journal)
    }

    func restore(for binding: VoyageAccountBinding) throws {
        journal = try load(for: binding)
    }

    func status(for legID: UUID) -> VoyageSyncStatus {
        statuses[legID] ?? .onIPhone
    }

    var statuses: [UUID: VoyageSyncStatus] {
        guard let journal, journal.binding == account.binding else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: journal.legs.map { entry in
                let step = nextStep(entry, in: journal)
                let status: VoyageSyncStatus
                if entry.trackSent {
                    status = .synced
                } else if activeLeg == entry.id {
                    status = .syncing(step)
                } else if let failure = entry.failure {
                    if failure.retryAt == nil {
                        status = .needsAttention(failure.step, status: failure.status)
                    } else if failure.offline {
                        status = .waitingForConnection
                    } else {
                        status = .retryableFailure(failure.step)
                    }
                } else {
                    status = .queued
                }
                return (entry.id, status)
            })
    }

    func retryFailures(for binding: VoyageAccountBinding) throws {
        var journal = try load(for: binding)
        for index in journal.legs.indices where journal.legs[index].failure?.retryAt != nil {
            journal.legs[index].failure = nil
        }
        try save(journal)
    }

    /// Advance all due legs and return the next retry deadline, if any.
    func drain(for binding: VoyageAccountBinding) async throws -> Date? {
        guard !draining else { return nil }
        draining = true
        defer {
            draining = false
            activeLeg = nil
        }
        while !Task.isCancelled, account.binding == binding {
            let journal = try load(for: binding)
            guard
                let entry = journal.legs.first(where: { entry in
                    guard !entry.trackSent else { return false }
                    guard let failure = entry.failure else { return true }
                    return failure.retryAt.map { $0 <= now() } ?? false
                })
            else {
                return journal.legs.compactMap { $0.failure?.retryAt }.min()
            }
            guard let parent = journal.voyages[entry.voyageID] else { throw VoyageOutboxError.invalidJournal }
            let step = nextStep(entry, in: journal)
            activeLeg = entry.id
            var failure: Failure?
            do {
                try await account.authorized(for: binding) { bearer in
                    switch step {
                    case .voyage:
                        try await api.putVoyage(parent.snapshot, id: entry.voyageID, bearer: bearer)
                    case .leg:
                        try await api.putLeg(entry.snapshot, voyageID: entry.voyageID, legID: entry.id, bearer: bearer)
                    case .track:
                        let key = VoyageUploadKey(signInID: binding.signInID, voyageID: entry.voyageID, legID: entry.id)
                        try await api.putTrack(file: trackURL(entry.id, for: binding), key: key, bearer: bearer)
                    }
                }
            } catch {
                if error is VoyageAccountError { return nil }
                guard !Task.isCancelled, account.binding == binding else { return nil }
                if account.storageUnavailable { throw error }
                failure = classify(error, step: step, previous: entry.failure)
            }
            // Another leg may have been queued during the request.
            var updated = try load(for: binding)
            guard let index = updated.legs.firstIndex(where: { $0.id == entry.id }) else {
                throw VoyageOutboxError.invalidJournal
            }
            if failure == nil {
                switch step {
                case .voyage: updated.voyages[entry.voyageID]?.acknowledged = true
                case .leg: updated.legs[index].metadataSent = true
                case .track: updated.legs[index].trackSent = true
                }
            }
            updated.legs[index].failure = failure
            try save(updated)
            activeLeg = nil
        }
        return nil
    }

    private func nextStep(_ entry: LegEntry, in journal: Journal) -> VoyageSyncStep {
        if journal.voyages[entry.voyageID]?.acknowledged != true { return .voyage }
        return entry.metadataSent ? .track : .leg
    }

    private func classify(_ error: Error, step: VoyageSyncStep, previous: Failure?) -> Failure {
        let urlError = error as? URLError
        let offline = urlError?.code == .notConnectedToInternet || urlError?.code == .networkConnectionLost
        let http = error as? VoyageAPIError
        let status = http?.status
        let retryable =
            (urlError != nil && urlError?.code != .fileDoesNotExist)
            || status == 408 || status == 425 || status == 429 || status.map { (500...599).contains($0) } == true
        let attempts = previous?.step == step ? min((previous?.attempts ?? 0) + 1, 7) : 1
        let delay = min(300, pow(2, Double(attempts - 1)) * 5)
        var retryAt: Date?
        if retryable {
            var serverDelay: TimeInterval = 0
            if case .http(_, _, let retryAfter) = http, let retryAfter, retryAfter.isFinite {
                serverDelay = min(retryAfter, 86_400)
            }
            retryAt = now().addingTimeInterval(max(delay, serverDelay))
        }
        return Failure(step: step, status: status, offline: offline, attempts: attempts, retryAt: retryAt)
    }

    private func load(for binding: VoyageAccountBinding) throws -> Journal {
        guard account.binding == binding else { throw VoyageAccountError.accountChanged }
        if let journal, journal.binding == binding { return journal }
        let result: Journal
        do {
            result = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL(for: binding)))
        } catch CocoaError.fileReadNoSuchFile {
            return Journal(binding: binding)
        }
        guard result.binding == binding, Set(result.legs.map(\.id)).count == result.legs.count else {
            throw VoyageOutboxError.invalidJournal
        }
        return result
    }

    private func save(_ updated: Journal) throws {
        guard account.binding == updated.binding else { throw VoyageAccountError.accountChanged }
        try createPrivateDirectory(for: updated.binding)
        try JSONEncoder().encode(updated).write(to: journalURL(for: updated.binding), options: Self.privateWriteOptions)
        journal = updated
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

    private func trackURL(_ legID: UUID, for binding: VoyageAccountBinding) -> URL {
        directory(for: binding).appending(path: legID.uuidString.lowercased() + ".track.json.gz")
    }

    private static var privateWriteOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            [.atomic]
        #endif
    }
}
