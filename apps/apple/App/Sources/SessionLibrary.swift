import Foundation
import Observation
import WaterKit

/// The recordings on this phone with their analyzed summaries, newest first. Summaries
/// come from replaying each recording through the session engine (without the motion
/// stream) in the background, and are cached until the recording's files change.
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
    private var cache: [URL: (bytes: Int64, summary: Summary)] = [:]

    func reload() {
        let entries = RecordingStore.list()
        items = entries.map { Item(entry: $0, summary: cachedSummary(for: $0)) }
        let missing = entries.filter { $0.meta != nil && cachedSummary(for: $0) == nil }
        guard !missing.isEmpty else { return }
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                missing.map { entry in (entry, Self.summarize(entry)) }
            }.value
            for (entry, summary) in results {
                if let summary { cache[entry.folder] = (entry.bytes, summary) }
            }
            items = RecordingStore.list().map { Item(entry: $0, summary: cachedSummary(for: $0)) }
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
        guard let cached = cache[entry.folder], cached.bytes == entry.bytes else { return nil }
        return cached.summary
    }

    nonisolated static func summarize(_ entry: RecordingStore.Entry) -> Summary? {
        guard let session = try? RawSessionReader.read(folder: entry.folder, includeMotion: false) else { return nil }
        let replay = SessionReplay(track: session.track(), profile: UserSettings.profile(for: session.meta.sport))
        return Summary(sport: session.meta.sport, startedAt: session.startedAt, metrics: replay.metrics)
    }
}
