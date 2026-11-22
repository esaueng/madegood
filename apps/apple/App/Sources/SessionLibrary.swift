import Foundation
import Observation
import WaterKit

/// The recordings on this phone, newest first. Summaries and History previews share
/// a background analysis and cache keyed by the recording, analysis settings and trim.
@MainActor
@Observable
final class SessionLibrary {
    struct Summary: Sendable, Hashable {
        var sport: Sport
        var startedAt: Date
        var metrics: LiveMetrics
        var historyRoute: HistoryRoute?
        var isTrimmed: Bool
        var trimUnavailable: Bool

        init(selection: SessionSelection, isTrimmed: Bool, trimUnavailable: Bool = false) {
            sport = selection.track.sport
            startedAt = selection.track.startedAt
            metrics = selection.replay.metrics
            historyRoute = HistoryRoute(fixSpans: selection.replay.fixSpans)
            self.isTrimmed = isTrimmed
            self.trimUnavailable = trimUnavailable
        }
    }

    struct Item: Identifiable, Hashable {
        var id: URL { entry.folder }
        var entry: RecordingStore.Entry
        var summary: Summary?
        /// The name and notes the user gave it; empty when there are none.
        var details = SessionDetails()
        /// A saved name and notes file this version can't read (a newer app wrote it).
        /// It is kept, and editing waits until an update can read it.
        var detailsUnreadable = false

        /// The user's name for the session, or its sport's.
        var title: String {
            details.name.isEmpty ? entry.meta?.sport.displayName ?? "Receiving…" : details.name
        }
    }

    private(set) var items: [Item] = []
    /// Posted on the main actor after a trim is saved or removed.
    static let didChangeTrim = Notification.Name("SessionLibrary.didChangeTrim")
    enum SavedTrim: Hashable, Sendable {
        case original
        case trimmed(SessionTrim)
        case unreadable

        var trim: SessionTrim? {
            if case .trimmed(let trim) = self { return trim }
            return nil
        }
    }

    struct Source: Hashable, Sendable {
        var entry: RecordingStore.Entry
        var autoPause: Bool
        var savedTrim: SavedTrim
        var planingSpeedThreshold = SportSettings.defaultPlaningSpeedThreshold

        func analyze() -> LoadedSession? {
            guard let session = try? RawSessionReader.read(folder: entry.folder, includeMotion: false),
                session.meta == entry.meta
            else { return nil }
            var profile = SportProfile.standard(for: session.meta.sport)
            profile.autoPause.enabled = autoPause
            profile.planingSpeedThreshold = planingSpeedThreshold
            guard let original = try? SessionSelection(session: session, profile: profile) else { return nil }
            let trimmed = savedTrim.trim.flatMap {
                try? SessionSelection(session: session, trim: $0, profile: profile)
            }
            if session.meta.endedAt != nil {
                SessionLibrary.writeTrackFile(
                    original.replay.analyzedTrack(from: original.track), folder: entry.folder,
                    analyzedRevision: entry.revision, analyzedAutoPause: autoPause)
            }
            return LoadedSession(
                session: session, profile: profile, original: original, selection: trimmed ?? original,
                trim: trimmed == nil ? nil : savedTrim.trim,
                trimUnavailable: savedTrim == .unreadable || (savedTrim.trim != nil && trimmed == nil))
        }
    }

    struct LoadedSession: Sendable {
        let session: RawSession
        let profile: SportProfile
        let original: SessionSelection
        var selection: SessionSelection
        var trim: SessionTrim?
        var trimUnavailable: Bool
    }

    enum EditError: Error {
        case recordingChanged
        case detailsUnreadable
    }

    private nonisolated static var trimStore: SessionTrimStore {
        let support =
            DemoOffWater.storage
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let trims = support.appendingPathComponent("SessionTrims", isDirectory: true)
        if let namespace = RecordingStore.demoNamespace {
            return SessionTrimStore(directory: trims.appendingPathComponent(namespace.uuidString, isDirectory: true))
        }
        return SessionTrimStore(directory: trims)
    }

    /// Names and notes, beside the trims and likewise outside the recording folders, so
    /// sharing a raw recording never carries them.
    private nonisolated static var detailsStore: SessionDetailsStore {
        let support =
            DemoOffWater.storage
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let details = support.appendingPathComponent("SessionDetails", isDirectory: true)
        if let namespace = RecordingStore.demoNamespace {
            return SessionDetailsStore(
                directory: details.appendingPathComponent(namespace.uuidString, isDirectory: true))
        }
        return SessionDetailsStore(directory: details)
    }

    private var cache: [URL: (key: Source, summary: Summary)] = [:]
    private var inFlight: Set<Source> = []

    func reload() {
        let entries = RecordingStore.list()
        let folders = Set(entries.map(\.folder))
        cache = cache.filter { folders.contains($0.key) }
        let currentKeys = Self.sources(for: entries)
        updateItems(entries, sources: currentKeys)
        let missing = currentKeys.values.filter { key in
            cache[key.entry.folder]?.key != key && inFlight.insert(key).inserted
        }
        guard !missing.isEmpty else { return }
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                missing.map { key in
                    let summary = key.analyze().map {
                        Summary(selection: $0.selection, isTrimmed: $0.trim != nil, trimUnavailable: $0.trimUnavailable)
                    }
                    return (key, summary)
                }
            }.value
            let current = RecordingStore.list()
            let currentKeys = Self.sources(for: current)
            // A recording, setting or trim can change while the replay is running.
            for (key, summary) in results {
                inFlight.remove(key)
                let folder = key.entry.folder
                guard let summary, currentKeys[folder] == key else { continue }
                cache[folder] = (key, summary)
            }
            updateItems(current, sources: currentKeys)
        }
    }

    func updateTrim(
        _ trim: SessionTrim?, for session: RawSession, source: Source, summary: Summary
    ) throws -> Source {
        guard Self.source(for: source.entry.folder) == source else { throw EditError.recordingChanged }
        if let trim {
            try Self.trimStore.save(trim, for: session)
        } else {
            try Self.trimStore.restoreOriginal(sessionId: session.meta.sessionId)
        }
        var updated = source
        updated.savedTrim = trim.map(SavedTrim.trimmed) ?? .original
        cache[source.entry.folder] = (updated, summary)
        reload()
        NotificationCenter.default.post(name: Self.didChangeTrim, object: nil)
        return updated
    }

    /// Saves a session's name and notes (empty details remove them). Refuses when the
    /// recording is gone (deleted from another screen), so no file outlives it, and while a
    /// newer app's file is there, so it isn't overwritten.
    func updateDetails(_ details: SessionDetails, sessionId: UUID, folder: URL) throws {
        defer { reload() }
        // Under the transfer's lock, as `delete` removes the folder under it: either the
        // recording is still there when this saves, or the delete removes the file after.
        try RecordingTransfer.storageLock.withLock {
            guard (try? RawSessionReader.readMeta(folder: folder))?.sessionId == sessionId else {
                throw EditError.recordingChanged
            }
            if case .failure = Self.loadDetails(sessionId: sessionId) { throw EditError.detailsUnreadable }
            try Self.detailsStore.save(details, sessionId: sessionId)
        }
    }

    /// Deletes a recording, unless its files changed since `item` was read (a file arrived
    /// from the watch): the user saw something else. The watch deletes its copy once the
    /// phone holds all of it, so deleting a "Receiving…" row that just completed would lose
    /// the recording on both devices.
    func delete(_ item: Item) throws {
        // Under the transfer's lock, so a file from the watch can't be stored (and the
        // recording acknowledged as complete) between this check and the delete.
        let sessionId: UUID?
        do {
            sessionId = try RecordingTransfer.storageLock.withLock { () throws -> UUID? in
                guard RawSessionReader.revision(of: item.entry.folder) == item.entry.revision else {
                    throw EditError.recordingChanged
                }
                let sessionId =
                    (try? RawSessionReader.readMeta(folder: item.entry.folder))?.sessionId
                    ?? UUID(uuidString: item.entry.folder.lastPathComponent)
                try RecordingStore.delete(item.entry)
                return sessionId
            }
        } catch EditError.recordingChanged {
            reload()
            throw EditError.recordingChanged
        }
        // Its prepared copies for sharing go with it.
        ZipExport.removePrepared(for: item.entry.folder)
        defer {
            cache[item.entry.folder] = nil
            reload()
        }
        if let sessionId, !FileManager.default.fileExists(atPath: item.entry.folder.path) {
            // Try both, so a failed trim removal doesn't leave the name and notes behind.
            let details = Result { try Self.detailsStore.remove(sessionId: sessionId) }
            try Self.trimStore.restoreOriginal(sessionId: sessionId)
            try details.get()
        }
    }

    /// Totals over the given items with summaries.
    static func totals(_ items: [Item]) -> (count: Int, distance: Double, movingTime: Double) {
        let summaries = items.compactMap(\.summary)
        return (
            summaries.count, summaries.reduce(0) { $0 + $1.metrics.distance },
            summaries.reduce(0) { $0 + $1.metrics.movingTime }
        )
    }

    private func updateItems(_ entries: [RecordingStore.Entry], sources: [URL: Source]) {
        items = entries.map { entry in
            let cached = cache[entry.folder]
            let summary = cached?.key == sources[entry.folder] ? cached?.summary : nil
            var item = Item(entry: entry, summary: summary)
            if let sessionId = entry.meta?.sessionId {
                switch Self.loadDetails(sessionId: sessionId) {
                case .success(let details): item.details = details ?? SessionDetails()
                case .failure: item.detailsUnreadable = true
                }
            }
            return item
        }
    }

    private nonisolated static func loadDetails(sessionId: UUID) -> Result<SessionDetails?, Error> {
        Result { try detailsStore.load(sessionId: sessionId) }
    }

    nonisolated static func source(for folder: URL) -> Source? {
        RecordingStore.list().first { $0.folder == folder }.flatMap(source(for:))
    }

    private nonisolated static func sources(for entries: [RecordingStore.Entry]) -> [URL: Source] {
        Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                source(for: entry).map { (entry.folder, $0) }
            })
    }

    private nonisolated static func source(for entry: RecordingStore.Entry) -> Source? {
        guard let meta = entry.meta else { return nil }
        let savedTrim: SavedTrim
        do {
            savedTrim = try trimStore.load(sessionId: meta.sessionId).map(SavedTrim.trimmed) ?? .original
        } catch {
            savedTrim = .unreadable
        }
        let profile = UserSettings.profile(for: meta.sport)
        return Source(
            entry: entry, autoPause: profile.autoPause.enabled, savedTrim: savedTrim,
            planingSpeedThreshold: profile.planingSpeedThreshold)
    }

    /// Serializes track-file writes, so the freshness check and the write happen together.
    private nonisolated static let trackWrites = NSLock()

    /// Only publish a track for the raw files and settings used by its analysis.
    private nonisolated static func writeTrackFile(
        _ track: Track, folder: URL, analyzedRevision: [RawSessionReader.FileRevision], analyzedAutoPause: Bool
    ) {
        let url = folder.appendingPathComponent(RecordingStore.trackFileName)
        trackWrites.lock()
        defer { trackWrites.unlock() }
        guard FileManager.default.fileExists(atPath: folder.path),
            RawSessionReader.revision(of: folder) == analyzedRevision,
            analyzedAutoPause == UserSettings.profile(for: track.sport).autoPause.enabled
        else { return }
        do {
            let data = try TrackCodec.encode(track)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        } catch {
            print("SessionLibrary: could not write the track file: \(error)")
        }
    }
}
