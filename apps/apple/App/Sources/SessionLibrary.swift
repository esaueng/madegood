import Foundation
import Observation
import WaterKit

/// The recordings on this phone with their analyzed summaries, newest first. Summaries
/// come from replaying each recording through the session engine (without the motion
/// stream) in the background, and are cached until the recording's files or the
/// sport's auto-pause setting change.
@MainActor
@Observable
final class SessionLibrary {
    struct Summary: Sendable, Hashable {
        var sport: Sport
        var startedAt: Date
        var metrics: LiveMetrics
    }

    struct Item: Identifiable, Hashable {
        var id: URL { entry.folder }
        var entry: RecordingStore.Entry
        var summary: Summary?
    }

    private(set) var items: [Item] = []
    /// What a cached summary was computed from; it is reused only while both still hold.
    private struct CacheKey: Equatable {
        var bytes: Int64
        var autoPause: Bool
    }

    private var cache: [URL: (key: CacheKey, summary: Summary)] = [:]

    func reload() {
        let entries = RecordingStore.list()
        items = entries.map { Item(entry: $0, summary: cachedSummary(for: $0)) }
        let missing = entries.filter { $0.meta != nil && cachedSummary(for: $0) == nil }
        guard !missing.isEmpty else { return }
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                missing.map { entry in (entry, Self.summarize(entry)) }
            }.value
            // Files may have changed while this ran (a recording arriving from the watch),
            // and a newer reload may already have finished. Keep a result only if it
            // still describes the recording as it is now.
            let current = RecordingStore.list()
            let currentBytes = Dictionary(current.map { ($0.folder, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            for (entry, summary) in results {
                guard let summary, currentBytes[entry.folder] == entry.bytes else { continue }
                cache[entry.folder] = (key(for: entry, sport: summary.sport), summary)
            }
            items = current.map { Item(entry: $0, summary: cachedSummary(for: $0)) }
        }
    }

    func delete(_ item: Item) {
        try? RecordingStore.delete(item.entry)
        cache[item.entry.folder] = nil
        reload()
    }

    /// Totals over the given items with summaries.
    static func totals(_ items: [Item]) -> (count: Int, distance: Double, movingTime: Double) {
        let summaries = items.compactMap(\.summary)
        return (
            summaries.count, summaries.reduce(0) { $0 + $1.metrics.distance },
            summaries.reduce(0) { $0 + $1.metrics.movingTime }
        )
    }

    private func cachedSummary(for entry: RecordingStore.Entry) -> Summary? {
        guard let cached = cache[entry.folder], cached.key == key(for: entry, sport: cached.summary.sport) else {
            return nil
        }
        return cached.summary
    }

    private func key(for entry: RecordingStore.Entry, sport: Sport) -> CacheKey {
        CacheKey(bytes: entry.bytes, autoPause: UserSettings.profile(for: sport).autoPause.enabled)
    }

    nonisolated static func summarize(_ entry: RecordingStore.Entry) -> Summary? {
        guard let session = try? RawSessionReader.read(folder: entry.folder, includeMotion: false) else { return nil }
        let track = session.track()
        let replay = SessionReplay(track: track, profile: UserSettings.profile(for: session.meta.sport))
        // A finished recording also gets its track v1 file (docs/formats.md), the form
        // that is stored and uploaded. Rewritten when the analysis changes.
        if session.meta.endedAt != nil {
            writeTrackFile(replay.analyzedTrack(from: track), folder: entry.folder)
        }
        return Summary(sport: session.meta.sport, startedAt: session.startedAt, metrics: replay.metrics)
    }

    nonisolated static func writeTrackFile(_ track: Track, folder: URL) {
        let url = folder.appendingPathComponent(RecordingStore.trackFileName)
        do {
            let data = try TrackCodec.encode(track)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        } catch {
            print("SessionLibrary: could not write the track file: \(error)")
        }
    }
}
