import Foundation
import Synchronization
import WaterKit

/// Buffers NDJSON lines for one stream and appends them to `<stream>.ndjson.gz`, one gzip
/// member per flush. A crash or dead battery loses at most the lines since the last flush;
/// everything already flushed stays readable (docs/formats.md).
///
/// `append` is safe to call from any thread (sensor callbacks run on their own queues).
final class StreamWriter: Sendable {
    let stream: RawFormat.Stream
    let url: URL
    private let buffer = Mutex(Data())
    private let counters = Mutex((lines: 0, dropped: 0))
    private let io: DispatchQueue

    init(stream: RawFormat.Stream, folder: URL) {
        self.stream = stream
        self.url = folder.appendingPathComponent(stream.gzippedFileName)
        self.io = DispatchQueue(label: "app.madegood.recorder.\(stream.rawValue)", qos: .utility)
    }

    /// Lines accepted so far, and lines dropped because they could not be encoded.
    var counts: (lines: Int, dropped: Int) { counters.withLock { $0 } }

    func append(_ line: some Encodable) {
        guard let data = try? RawFormat.line(line) else {
            counters.withLock { $0.dropped += 1 }
            return
        }
        buffer.withLock { $0.append(data) }
        counters.withLock { $0.lines += 1 }
    }

    /// Compresses and appends buffered lines on the writer's queue.
    func flush() {
        let chunk = takeBuffer()
        guard !chunk.isEmpty else { return }
        let url = url
        io.async { Self.appendMember(chunk, to: url) }
    }

    /// Flushes and waits until everything is on disk.
    func flushAndWait() {
        let chunk = takeBuffer()
        let url = url
        io.sync {
            if !chunk.isEmpty { Self.appendMember(chunk, to: url) }
        }
    }

    private func takeBuffer() -> Data {
        buffer.withLock { data in
            let chunk = data
            data = Data()
            return chunk
        }
    }

    private static func appendMember(_ chunk: Data, to url: URL) {
        do {
            let member = try Gzip.compress(chunk)
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: member)
        } catch {
            // Nothing sensible to do mid-session; the reader reports missing data as gaps.
            print("StreamWriter: failed to write \(url.lastPathComponent): \(error)")
        }
    }
}
