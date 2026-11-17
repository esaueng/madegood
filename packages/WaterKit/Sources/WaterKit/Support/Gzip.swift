import CZlib
import Foundation

/// Gzip (RFC 1952) compression backed by the system zlib.
///
/// Output always uses the gzip container, not a raw zlib stream, so files open with
/// `gzip -d`, browsers' `DecompressionStream("gzip")`, and the Worker runtime.
/// Decompression handles multi-member files (gzip members appended one after another,
/// as the recorder writes them) and can return the readable prefix of a truncated file.
public enum Gzip {
    public enum Error: Swift.Error, Equatable {
        case initFailed(Int32)
        case streamError(Int32)
        /// The input is not gzip data, or is corrupt before any output was produced.
        case invalidData
        /// The input ended before the last gzip member was complete.
        case truncated
        case inputTooLarge
        case outputTooLarge(limit: Int)
    }

    /// Default ceiling for decompressed output, guarding against decompression bombs.
    public static let defaultOutputLimit = 2 << 30

    private static let chunkSize = 64 * 1024

    /// True if `data` starts with the gzip magic bytes.
    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Compresses `data` into a single gzip member.
    public static func compress(_ data: Data, level: Int32 = 6) throws -> Data {
        guard data.count <= Int(UInt32.max) else { throw Error.inputTooLarge }
        var stream = z_stream()
        let initStatus = czlib_deflate_init_gzip(&stream, level)
        guard initStatus == Z_OK else { throw Error.initFailed(initStatus) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var status: Int32 = Z_OK
            repeat {
                try buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw Error.streamError(status)
                    }
                    output.append(out.baseAddress!, count: out.count - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    /// Decompresses gzip data, throwing `Error.truncated` if the last member is incomplete.
    public static func decompress(_ data: Data, limit: Int = defaultOutputLimit) throws -> Data {
        let result = try decompressAvailable(data, limit: limit)
        guard result.complete else { throw Error.truncated }
        return result.data
    }

    /// Decompresses as much as possible. `complete` is false when the input ends inside a
    /// member or a later member is corrupt (for example a file cut off by a crash); `data`
    /// then holds everything decoded before that point.
    public static func decompressAvailable(
        _ data: Data, limit: Int = defaultOutputLimit
    ) throws -> (data: Data, complete: Bool) {
        try inflateMembers(data, limit: limit, memberStart: { _ in })
    }

    /// The fixed 10-byte header of one gzip member (RFC 1952 §2.3).
    public struct MemberHeader: Sendable, Equatable {
        /// FLG byte: FTEXT 0x01, FHCRC 0x02, FEXTRA 0x04, FNAME 0x08, FCOMMENT 0x10.
        public var flags: UInt8
        /// MTIME, Unix seconds (0 when not set).
        public var modificationTime: UInt32

        /// True if the member stores a file name, comment, or extra field.
        public var hasOptionalFields: Bool { flags & 0x1C != 0 }
    }

    /// The header of every member, in order. Optional header fields (file name, comment,
    /// extra data) and MTIME are not part of the decompressed data, so callers that must
    /// vet everything in a file inspect them here.
    public static func memberHeaders(_ data: Data) throws -> [MemberHeader] {
        var starts: [Int] = []
        _ = try inflateMembers(data, limit: defaultOutputLimit, memberStart: { starts.append($0) })
        return starts.compactMap { start in
            guard start + 10 <= data.count else { return nil }
            let base = data.startIndex + start
            let time = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + 4 + $1]) << (8 * UInt32($1)) }
            return MemberHeader(flags: data[base + 3], modificationTime: time)
        }
    }

    private static func inflateMembers(
        _ data: Data, limit: Int, memberStart: (Int) -> Void
    ) throws -> (data: Data, complete: Bool) {
        guard isGzipped(data) else { throw Error.invalidData }
        guard data.count <= Int(UInt32.max) else { throw Error.inputTooLarge }

        var stream = z_stream()
        let initStatus = czlib_inflate_init_gzip(&stream)
        guard initStatus == Z_OK else { throw Error.initFailed(initStatus) }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        return try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> (Data, Bool) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            memberStart(0)

            while true {
                var status: Int32 = Z_OK
                var produced = 0
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    produced = out.count - Int(stream.avail_out)
                    output.append(out.baseAddress!, count: produced)
                }
                if output.count > limit { throw Error.outputTooLarge(limit: limit) }

                switch status {
                case Z_STREAM_END:
                    // End of one member. Another member may follow; zero padding ends the
                    // stream cleanly; anything else (a partial header from an interrupted
                    // write, or garbage) means the data did not end cleanly.
                    let remaining = Int(stream.avail_in)
                    guard remaining > 0, let next = stream.next_in else { return (output, true) }
                    let rest = UnsafeBufferPointer(start: next, count: remaining)
                    if rest.allSatisfy({ $0 == 0 }) { return (output, true) }
                    guard remaining >= 2, rest[0] == 0x1f, rest[1] == 0x8b else { return (output, false) }
                    memberStart(input.count - remaining)
                    let resetStatus = inflateReset(&stream)
                    guard resetStatus == Z_OK else { throw Error.streamError(resetStatus) }
                case Z_OK:
                    continue
                case Z_BUF_ERROR:
                    // No progress possible: the input ran out inside a member.
                    if stream.avail_in == 0 || produced == 0 { return (output, false) }
                case Z_DATA_ERROR, Z_NEED_DICT:
                    if output.isEmpty { throw Error.invalidData }
                    return (output, false)
                default:
                    throw Error.streamError(status)
                }
            }
        }
    }
}
