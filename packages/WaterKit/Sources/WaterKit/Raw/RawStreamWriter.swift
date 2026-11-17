import Foundation
import Synchronization

/// Buffers NDJSON lines for one raw-format stream and appends them to `<stream>.ndjson.gz`, one gzip
/// member per flush. A crash or dead battery loses at most the lines since the last flush;
/// everything already flushed stays readable (docs/formats.md).
///
/// Write failures (for example a full disk) are never silent:
/// - a partly written member is cut back off the file, so earlier members stay intact;
/// - the unwritten lines are kept and retried on the next flush, up to `maxRetainedBytes`;
/// - lines that still can't be kept are counted as dropped, and `lastError` is set.
///
/// `append` is safe to call from any thread (sensor callbacks run on their own queues).
public final class RawStreamWriter: Sendable {
    public struct Status: Sendable, Equatable {
        /// Lines accepted for writing.
        public var lines = 0
        /// Lines lost: unencodable, or discarded after repeated write failures.
        public var dropped = 0
        /// The most recent write error, cleared by a later successful write.
        public var lastError: String?
    }

    /// Default limit on unwritten data kept for retry; beyond it, lines are dropped.
    public static let defaultMaxRetainedBytes = 32 * 1024 * 1024

    public let stream: RawFormat.Stream
    public let url: URL
    private let maxRetainedBytes: Int
    private let buffer = Mutex(Data())
    private let state = Mutex(Status())
    private let io: DispatchQueue

    public init(stream: RawFormat.Stream, folder: URL, maxRetainedBytes: Int = defaultMaxRetainedBytes) {
        self.stream = stream
        self.url = folder.appendingPathComponent(stream.gzippedFileName)
        self.maxRetainedBytes = maxRetainedBytes
        self.io = DispatchQueue(label: "app.madegood.rawstream.\(stream.rawValue)", qos: .utility)
    }

    public var status: Status { state.withLock { $0 } }

    public func append(_ line: some Encodable) {
        guard let data = try? RawFormat.line(line) else {
            state.withLock { $0.dropped += 1 }
            return
        }
        buffer.withLock { $0.append(data) }
        state.withLock { $0.lines += 1 }
    }

    /// Compresses and appends buffered lines on the writer's queue.
    public func flush() {
        io.async { self.writeBuffered() }
    }

    /// Flushes and waits. Returns false if anything is still unwritten (the error is in
    /// `status.lastError`).
    @discardableResult
    public func flushAndWait() -> Bool {
        io.sync { self.writeBuffered() }
    }

    /// Runs on `io` only, so writes never interleave.
    private func writeBuffered() -> Bool {
        let chunk = buffer.withLock { data in
            let chunk = data
            data = Data()
            return chunk
        }
        guard !chunk.isEmpty else { return state.withLock { $0.lastError == nil } }
        do {
            try Self.appendMember(chunk, to: url)
            state.withLock { $0.lastError = nil }
            return true
        } catch {
            retain(chunk, after: error)
            return false
        }
    }

    /// Puts an unwritten chunk back in front of newer lines, or drops it if too much is waiting.
    private func retain(_ chunk: Data, after error: any Error) {
        let droppedLines = buffer.withLock { data -> Int in
            guard chunk.count + data.count <= maxRetainedBytes else {
                return chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            }
            data = chunk + data
            return 0
        }
        state.withLock { status in
            status.dropped += droppedLines
            status.lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private static func appendMember(_ chunk: Data, to url: URL) throws {
        let member = try Gzip.compress(chunk)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let start = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: member)
            try handle.synchronize()
        } catch {
            // Cut off a partly written member so the members before it stay readable.
            try? handle.truncate(atOffset: start)
            throw error
        }
    }
}
