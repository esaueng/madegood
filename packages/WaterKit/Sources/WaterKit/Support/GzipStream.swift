import CZlib
import Foundation

extension Gzip {
    /// Inflates gzip data read chunk by chunk, handing each piece of output to `emit`, so a
    /// long stream never sits in memory whole. Handles concatenated members (one per
    /// recorder flush) and returns false, after emitting everything readable, when the
    /// input ends inside a member or a later member is damaged, as `decompressAvailable`.
    /// `read` returns nil (or empty) at the end of the input.
    public static func inflateStream(
        reading read: () throws -> Data?, emit: (Data) throws -> Void, limit: Int = defaultOutputLimit
    ) throws -> Bool {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer {
            inflateEnd(stream)
            stream.deinitialize(count: 1)
            stream.deallocate()
        }
        let initStatus = czlib_inflate_init_gzip(stream)
        guard initStatus == Z_OK else { throw Error.initFailed(initStatus) }

        var pending = Data()
        var eof = false
        var total = 0
        var betweenMembers = false
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        func fill(atLeast count: Int) throws {
            while pending.count < count, !eof {
                if let next = try read(), !next.isEmpty { pending.append(next) } else { eof = true }
            }
        }
        try fill(atLeast: 2)
        guard pending.count >= 2, pending[pending.startIndex] == 0x1f, pending[pending.startIndex + 1] == 0x8b
        else { throw Error.invalidData }

        while true {
            if betweenMembers {
                // Another member, zero padding, or the end; anything else did not end cleanly.
                try fill(atLeast: 2)
                if pending.isEmpty { return true }
                if pending.allSatisfy({ $0 == 0 }) {
                    // Padding: it must run to the end of the input.
                    while !eof {
                        pending.removeAll(keepingCapacity: true)
                        try fill(atLeast: 1)
                        if !pending.allSatisfy({ $0 == 0 }) { return false }
                    }
                    return true
                }
                guard pending.count >= 2, pending[pending.startIndex] == 0x1f,
                    pending[pending.startIndex + 1] == 0x8b
                else { return false }
                let reset = inflateReset(stream)
                guard reset == Z_OK else { throw Error.streamError(reset) }
                betweenMembers = false
            }
            try fill(atLeast: 1)
            if pending.isEmpty { return false }  // the input ended inside a member

            var status: Int32 = Z_OK
            var consumed = 0
            try pending.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                stream.pointee.next_in = UnsafeMutablePointer(
                    mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.pointee.avail_in = uInt(input.count)
                var produced = 0
                repeat {
                    try output.withUnsafeMutableBufferPointer { out in
                        stream.pointee.next_out = out.baseAddress
                        stream.pointee.avail_out = uInt(out.count)
                        status = inflate(stream, Z_NO_FLUSH)
                        produced = out.count - Int(stream.pointee.avail_out)
                        if produced > 0 {
                            total += produced
                            if total > limit { throw Error.outputTooLarge(limit: limit) }
                            try emit(Data(out[0..<produced]))
                        }
                    }
                } while status == Z_OK && (stream.pointee.avail_in > 0 || produced == output.count)
                consumed = input.count - Int(stream.pointee.avail_in)
            }
            pending.removeFirst(consumed)
            switch status {
            case Z_STREAM_END:
                betweenMembers = true
            case Z_OK, Z_BUF_ERROR:
                // Needs more input; at the end of the input that means a cut-off member.
                if pending.isEmpty, eof { return false }
                if consumed == 0, status == Z_BUF_ERROR {
                    if eof { return false }
                    try fill(atLeast: pending.count + 1)
                }
            case Z_DATA_ERROR, Z_NEED_DICT:
                if total == 0 { throw Error.invalidData }
                return false
            default:
                throw Error.streamError(status)
            }
        }
    }

    /// Writes one gzip member incrementally: data goes through `write` and out through
    /// `output` in compressed chunks, so the uncompressed data is never held whole.
    public final class Writer {
        private let stream: UnsafeMutablePointer<z_stream>
        private let output: (Data) throws -> Void
        private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        private var finished = false

        public init(level: Int32 = 6, output: @escaping (Data) throws -> Void) throws {
            stream = .allocate(capacity: 1)
            stream.initialize(to: z_stream())
            self.output = output
            let status = czlib_deflate_init_gzip(stream, level)
            guard status == Z_OK else {
                stream.deinitialize(count: 1)
                stream.deallocate()
                throw Error.initFailed(status)
            }
        }

        deinit {
            deflateEnd(stream)
            stream.deinitialize(count: 1)
            stream.deallocate()
        }

        public func write(_ data: Data) throws {
            guard !data.isEmpty else { return }
            try run(data, flush: Z_NO_FLUSH)
        }

        /// Ends the member. Nothing can be written after it.
        public func finish() throws {
            guard !finished else { return }
            finished = true
            try run(Data(), flush: Z_FINISH)
        }

        private func run(_ data: Data, flush: Int32) throws {
            try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                stream.pointee.next_in = UnsafeMutablePointer(
                    mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.pointee.avail_in = uInt(input.count)
                var status: Int32 = Z_OK
                repeat {
                    var produced = 0
                    buffer.withUnsafeMutableBufferPointer { out in
                        stream.pointee.next_out = out.baseAddress
                        stream.pointee.avail_out = uInt(out.count)
                        status = deflate(stream, flush)
                        produced = out.count - Int(stream.pointee.avail_out)
                    }
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw Error.streamError(status)
                    }
                    if produced > 0 { try output(Data(buffer[0..<produced])) }
                    if flush == Z_FINISH, status == Z_STREAM_END { break }
                } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0 || flush == Z_FINISH
            }
        }
    }
}
