import Foundation
import WatchConnectivity
import WaterKit

/// The fast path (docs/watch-transfer.md): while the watch app is open and the phone is
/// reachable, the watch sends what the phone lacks of a recording (whole files and parts,
/// the same units `RecordingTransfer.units` plans) as a series of `sendMessageData` chunks,
/// one unit at a time, each chunk waiting for the phone's reply before the next goes.
/// `transferFile` stays the fallback and the only path in the background.
///
/// - Chunks are an inner layer of a unit: a 1 MiB part is still a 1 MiB part of the same
///   layout (`file|total|partSize`). The phone writes chunks into a staging file per unit
///   (`.messages/` in the recording folder) and, once the unit is complete and its CRC-32
///   matches, hands that file to the same store, join and acknowledge path as a file
///   transfer. Bytes in a staging file are never acknowledged; only stored parts and placed
///   files are.
/// - Each reply says how many bytes of the unit the phone's staging file holds (`have`), so
///   a chunk lost, repeated or cut off by reachability dropping costs nothing: the next
///   attempt, by message, continues where the phone is. A repeated chunk is ignored.
/// - The chunk size starts at `largestChunk` and halves on `WCErrorCodePayloadTooLarge`
///   (the limit is undocumented), down to `smallestChunk`; below that the fast path is off
///   for the process and the files carry on.
enum MessageTransfer {
    // MARK: Chunk size

    /// The first chunk size tried. The limit for a message is undocumented; reports put it
    /// near 64 KB, and a chunk carries a few hundred bytes of header.
    static let largestChunk = 60 << 10
    /// The smallest chunk tried before the fast path gives up for the process.
    static let smallestChunk = 4 << 10

    /// The chunk size to try after `size` was too large, or nil when it was the smallest.
    static func smallerChunk(after size: Int) -> Int? {
        guard size > smallestChunk else { return nil }
        return max(smallestChunk, size / 2)
    }

    // MARK: When

    /// The chunk protocol this build speaks. The phone advertises it in its application
    /// context (`RecordingTransfer.phoneTakesMessages`); a phone build without it has no
    /// handler for chunks, and the watch sends it files only.
    static let version = 1

    /// How long a unit in flight by message may go without a reply or an error before it no
    /// longer blocks the file path or a new run (a callback that never came).
    static let claimGrace: TimeInterval = 60

    /// Whether the watch sends by message now: the app is open, the session is active, the
    /// phone reachable and its app takes chunks, the fast path has not been turned off for
    /// the process (`disabled`), and no pause after a failure is still running.
    static func mayUse(
        foreground: Bool, activated: Bool, reachable: Bool, phoneTakesMessages: Bool, disabled: Bool,
        pausedUntil: Date?, now: Date
    ) -> Bool {
        foreground && activated && reachable && phoneTakesMessages && !disabled
            && (pausedUntil.map { $0 <= now } ?? true)
    }

    /// The order the fast path takes `units` (as `RecordingTransfer.units` returns them,
    /// with nothing left out by the window): first what is not queued as a file at all, then
    /// what is queued as a file but has not started (`queuedAsFiles`), the last queued
    /// first, so the file the queue starts next is the least likely to be sent both ways;
    /// `meta.json` stays last. Files moving are not in `units` (they are in flight).
    static func order(_ units: [RecordingTransfer.Unit], queuedAsFiles: Set<RecordingTransfer.UnitKey>)
        -> [RecordingTransfer.Unit]
    {
        let meta = units.filter { $0.file == RawFormat.metaFileName }
        let rest = units.filter { $0.file != RawFormat.metaFileName }
        let fresh = rest.filter { !queuedAsFiles.contains($0.key) }
        let queued = rest.filter { queuedAsFiles.contains($0.key) }
        return fresh + queued.reversed() + meta
    }

    // MARK: Watch: reading

    /// The bytes of `unit` (a part's slice of its file, or a whole file), read from the
    /// recording; throws unless exactly the unit's length is there.
    static func read(_ unit: RecordingTransfer.Unit, in recording: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: recording.appendingPathComponent(unit.file))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(unit.part?.offset ?? 0))
        let data = try handle.read(upToCount: Int(unit.length)) ?? Data()
        guard Int64(data.count) == unit.length else {
            throw TransferParts.PartError.wrongSize(expected: unit.length, actual: Int64(data.count))
        }
        return data
    }

    // MARK: Errors

    enum Failure: Equatable {
        /// The message was too large: try a smaller chunk.
        case tooLarge
        /// The phone stopped being reachable: files take over until it is again, with no
        /// pause.
        case unreachable
        /// Anything else (timed out, delivery failed, the phone app failed to reply): files
        /// take over, and the fast path pauses.
        case other
    }

    static func classify(_ error: NSError) -> Failure {
        guard error.domain == WCErrorDomain else { return .other }
        switch error.code {
        case WCError.Code.payloadTooLarge.rawValue: return .tooLarge
        case WCError.Code.notReachable.rawValue: return .unreachable
        default: return .other
        }
    }

    // MARK: Sender steps

    /// What the watch does after the phone replied to a chunk.
    enum Step: Equatable {
        /// Send the chunk starting here next.
        case send(from: Int64)
        /// The phone stored the unit.
        case delivered
        /// The phone refused the chunk or makes no progress.
        case failed(String)
    }

    /// The step after the chunk sent from `offset` of a unit of `length` bytes got `reply`.
    /// `stalls` counts replies in a row that did not move the phone forward; the third is a
    /// failure, so a phone that keeps refusing to write cannot keep the watch busy.
    static func step(after reply: Reply, sentFrom offset: Int64, length: Int64, stalls: inout Int) -> Step {
        if let error = reply.error { return .failed("iPhone refused it: \(error)") }
        if reply.done { return .delivered }
        guard reply.have >= 0, reply.have <= length else {
            return .failed("iPhone holds \(reply.have) bytes of \(length)")
        }
        // The phone holds everything but has not stored it: it would have said `done`.
        guard reply.have < length else { return .failed("iPhone holds the whole unit but did not store it") }
        if reply.have > offset {
            stalls = 0
        } else {
            stalls += 1
            if stalls >= 3 { return .failed("iPhone did not take the chunk at \(offset) three times") }
        }
        return .send(from: reply.have)
    }

    // MARK: Frames

    /// One chunk of a unit, as a message.
    struct Chunk: Equatable {
        var sessionId: String
        var file: String
        var part: TransferParts.Part?
        /// The unit's length: the part's, or the whole file's.
        var length: Int64
        /// The CRC-32 of the whole unit, checked once the phone holds all of it.
        var crc: UInt32
        var offset: Int64
        var data: Data
    }

    enum FrameError: Error, Equatable, CustomStringConvertible {
        case notAChunk
        case invalid(String)
        case checksumMismatch

        var description: String {
            switch self {
            case .notAChunk: "not a recording chunk"
            case .invalid(let why): "invalid chunk: \(why)"
            case .checksumMismatch: "the unit's checksum does not match"
            }
        }
    }

    private static let magic = Data("MGT1".utf8)
    /// The largest unit a chunk may belong to, so a malformed message can't make the phone
    /// hold something absurd.
    static let maximumUnitLength = TransferParts.maximumPartSize
    private static let maximumHeaderLength = 4096

    private enum Key {
        static let sessionId = "sessionId"
        static let file = "file"
        static let length = "length"
        static let crc = "crc"
        static let offset = "offset"
        static let have = "have"
        static let done = "done"
        static let error = "error"
    }

    /// `MGT1`, the header's length (4 bytes, big-endian), the header (a binary property list
    /// with the same part keys as a file transfer's metadata), then the chunk's bytes.
    static func encode(_ chunk: Chunk) -> Data {
        var header: [String: Any] = [
            Key.sessionId: chunk.sessionId, Key.file: chunk.file, Key.length: chunk.length,
            Key.crc: Int64(chunk.crc), Key.offset: chunk.offset,
        ]
        if let part = chunk.part { header.merge(TransferParts.metadata(for: part)) { $1 } }
        let encoded =
            (try? PropertyListSerialization.data(fromPropertyList: header, format: .binary, options: 0)) ?? Data()
        var data = magic
        var count = UInt32(encoded.count).bigEndian
        data.append(Data(bytes: &count, count: 4))
        data.append(encoded)
        data.append(chunk.data)
        return data
    }

    /// The chunk a message carries; throws when it is not one or cannot be right.
    static func decode(_ data: Data) throws -> Chunk {
        let bytes = Data(data)
        guard bytes.count >= 8, bytes.prefix(4) == magic else { throw FrameError.notAChunk }
        let headerLength = bytes.subdata(in: 4..<8).reduce(0) { $0 << 8 | Int($1) }
        guard headerLength > 0, headerLength <= maximumHeaderLength, bytes.count >= 8 + headerLength else {
            throw FrameError.invalid("header length")
        }
        guard
            let header = try? PropertyListSerialization.propertyList(
                from: bytes.subdata(in: 8..<(8 + headerLength)), format: nil) as? [String: Any],
            let sessionId = header[Key.sessionId] as? String,
            let file = header[Key.file] as? String,
            let length = (header[Key.length] as? NSNumber)?.int64Value,
            let crc = (header[Key.crc] as? NSNumber)?.int64Value,
            let offset = (header[Key.offset] as? NSNumber)?.int64Value
        else { throw FrameError.invalid("header") }
        let payload = bytes.subdata(in: (8 + headerLength)..<bytes.count)
        guard length >= 0, length <= maximumUnitLength else { throw FrameError.invalid("length \(length)") }
        guard crc >= 0, crc <= Int64(UInt32.max) else { throw FrameError.invalid("checksum") }
        // Compared without adding, so a huge offset cannot overflow.
        guard offset >= 0, Int64(payload.count) <= length, offset <= length - Int64(payload.count) else {
            throw FrameError.invalid("offset \(offset)")
        }
        let part: TransferParts.Part?
        do {
            part = try TransferParts.part(file: file, metadata: header)
        } catch {
            throw FrameError.invalid("part")
        }
        if let part, part.length != length { throw FrameError.invalid("part length") }
        // Whole files over a part's size are always sent in parts.
        if part == nil, length > TransferParts.partSize { throw FrameError.invalid("whole file of \(length) bytes") }
        return Chunk(
            sessionId: sessionId, file: file, part: part, length: length, crc: UInt32(crc), offset: offset,
            data: payload)
    }

    /// The phone's reply to a chunk: how many bytes of the unit it holds, whether it has
    /// stored the unit (durably, like a received file), or why it refused the chunk.
    struct Reply: Equatable {
        var have: Int64
        var done = false
        var error: String?
    }

    static func encode(_ reply: Reply) -> Data {
        var plist: [String: Any] = [Key.have: reply.have, Key.done: reply.done]
        if let error = reply.error { plist[Key.error] = error }
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
    }

    static func decodeReply(_ data: Data) -> Reply? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let have = (plist[Key.have] as? NSNumber)?.int64Value
        else { return nil }
        return Reply(have: have, done: plist[Key.done] as? Bool ?? false, error: plist[Key.error] as? String)
    }

    // MARK: Phone: assembling

    /// The hidden folder in a recording that holds units arriving by message.
    static let folderName = ".messages"

    /// Where the phone assembles the unit a chunk belongs to. The name carries the file, the
    /// layout (or the whole file's length) and the CRC, so chunks of a unit cut another way,
    /// or of other content, never mix.
    static func stagingURL(_ chunk: Chunk, in recording: URL) -> URL {
        let unit =
            chunk.part.map { "\($0.total)-\($0.partSize).\($0.index)" } ?? "whole-\(chunk.length)"
        return recording.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("\(chunk.file)~\(unit)~\(String(chunk.crc, radix: 16))")
    }

    enum Assembled: Equatable {
        /// The unit is not complete; the phone holds this many bytes of it.
        case partial(have: Int64)
        /// The unit is complete and its checksum matches: hand this file to the store.
        case complete(URL)
    }

    /// Adds a chunk to its unit's staging file. Chunks are expected in order: one that starts
    /// past what is held is not written (the reply's `have` brings the watch back), and bytes
    /// already held are not written again. Once the unit is complete it is synced to disk,
    /// every time (a sync that failed earlier must not pass on a retry), and checked against
    /// its CRC; a failed sync or a mismatch removes it and throws. The caller holds
    /// `RecordingTransfer.storageLock`.
    static func write(_ chunk: Chunk, in recording: URL) throws -> Assembled {
        let fm = FileManager.default
        let url = stagingURL(chunk, in: recording)
        var have = TransferParts.size(of: url) ?? 0
        if have > chunk.length {
            try? fm.removeItem(at: url)
            have = 0
        }
        let end = chunk.offset + Int64(chunk.data.count)
        if chunk.offset <= have, end > have {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(have))
            try handle.write(contentsOf: chunk.data.subdata(in: Int(have - chunk.offset)..<chunk.data.count))
            have = end
        } else if chunk.length == 0, !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        guard have == chunk.length else { return .partial(have: have) }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        let data = try Data(contentsOf: url)
        guard Int64(data.count) == chunk.length, crc32(data) == chunk.crc else {
            try? fm.removeItem(at: url)
            throw FrameError.checksumMismatch
        }
        return .complete(url)
    }

    /// Removes the staging files of `file` (it is in place, or a file transfer stored the
    /// part), and the folder once empty.
    static func removeStaging(file: String, in recording: URL) {
        let fm = FileManager.default
        let folder = recording.appendingPathComponent(folderName, isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("\(file)~") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }

    /// Removes the staging file of one part (a file transfer stored it), leaving the others.
    static func removeStaging(of part: TransferParts.Part, in recording: URL) {
        let fm = FileManager.default
        let folder = recording.appendingPathComponent(folderName, isDirectory: true)
        let prefix = "\(part.file)~\(part.total)-\(part.partSize).\(part.index)~"
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Removes what is staged of the unit a chunk belongs to (the phone holds it already).
    static func removeStaging(of chunk: Chunk, in recording: URL) {
        if let part = chunk.part {
            removeStaging(of: part, in: recording)
        } else {
            removeStaging(file: chunk.file, in: recording)
        }
    }

    // MARK: Checksum

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (IEEE, as gzip and zip use).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
