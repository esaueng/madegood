import Foundation
import Synchronization

/// A short on-device log of watch-to-phone recording transfers, for the diagnostics screens
/// (watch: Settings → iPhone; iPhone: a recording that is still arriving). It holds session
/// IDs, file names, sizes, counts and errors, never locations or other recorded values, and
/// stays on the device. Kept across launches, so a failure in a background launch shows up
/// later.
final class TransferLog: Sendable {
    static let shared = TransferLog()

    struct Entry: Codable, Hashable, Sendable, Identifiable {
        var id = UUID()
        var date: Date
        var sessionId: String?
        var message: String
    }

    /// The most entries kept; the oldest go first.
    static let limit = 200
    static let defaultsKey = "transferLog"

    /// The defaults suite (tests); nil for the standard defaults. UserDefaults itself is not
    /// Sendable, so it is looked up each time.
    private let suiteName: String?
    private let entries: Mutex<[Entry]>

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
        entries = Mutex(stored ?? [])
    }

    /// Adds an entry (and prints it, for a debugger).
    func add(_ message: String, sessionId: String? = nil, at date: Date = Date()) {
        print("RecordingTransfer: \(sessionId.map { "\(Self.short($0)) " } ?? "")\(message)")
        let snapshot = entries.withLock { entries -> [Entry] in
            entries.append(Entry(date: date, sessionId: sessionId, message: message))
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
            return entries
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Entries, newest first; only one session's when `sessionId` is given.
    func recent(sessionId: String? = nil) -> [Entry] {
        let all = entries.withLock { $0 }
        return all.reversed().filter { sessionId == nil || $0.sessionId == sessionId }
    }

    /// The first block of a session ID, enough to tell recordings apart on screen.
    static func short(_ sessionId: String) -> String {
        String(sessionId.prefix(8))
    }

    /// Files and exact sizes for a log line, sorted by name, so sizes compare across devices.
    static func describe(_ files: [String: Int64]) -> String {
        guard !files.isEmpty else { return "none" }
        return files.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) B" }.joined(separator: ", ")
    }
}
