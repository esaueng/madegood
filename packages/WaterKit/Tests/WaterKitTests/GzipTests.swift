import Foundation
import Testing

@testable import WaterKit

@Suite struct GzipTests {
    @Test func roundTripsSmallEmptyAndLargeInputs() throws {
        var generator = SeededGenerator(seed: 42)
        let large = Data((0..<1_500_000).map { _ in UInt8.random(in: 0...15, using: &generator) })
        for input in [Data(), Data("hello".utf8), large] {
            let compressed = try Gzip.compress(input)
            #expect(try Gzip.decompress(compressed) == input)
        }
    }

    @Test func writesGzipContainerWithCorrectTrailer() throws {
        let input = Data("{\"t\":0,\"lat\":0.0001}\n".utf8)
        let output = [UInt8](try Gzip.compress(input))
        // RFC 1952 header: magic, CM = 8 (deflate).
        #expect(Array(output.prefix(3)) == [0x1f, 0x8b, 0x08])
        // Trailer: CRC-32 then ISIZE, little-endian, checked with an independent CRC.
        let trailer = Array(output.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        #expect(crc == CRC32.checksum([UInt8](input)))
        #expect(size == UInt32(input.count))
    }

    @Test func readsGzipWrittenByAnotherImplementation() throws {
        // Created with Python's gzip module (mtime=0).
        let data = try Fixtures.data("python-gzip.ndjson.gz")
        let text = String(decoding: try Gzip.decompress(data), as: UTF8.self)
        #expect(text == String(repeating: "{\"hello\":\"water\"}\n", count: 3))
    }

    @Test func readsConcatenatedMembers() throws {
        let joined = try Gzip.compress(Data("a\n".utf8)) + Gzip.compress(Data("b\n".utf8))
        #expect(try Gzip.decompress(joined) == Data("a\nb\n".utf8))
    }

    @Test func truncatedInputThrowsOrReturnsPrefix() throws {
        let first = try Gzip.compress(Data("first\n".utf8))
        let second = try Gzip.compress(Data(String(repeating: "second line\n", count: 200).utf8))
        let cut = first + second.prefix(second.count / 2)

        #expect(throws: Gzip.Error.truncated) { try Gzip.decompress(cut) }
        let partial = try Gzip.decompressAvailable(cut)
        #expect(!partial.complete)
        #expect(partial.data.starts(with: Data("first\nsecond line\n".utf8)))
    }

    @Test func rejectsNonGzipData() {
        #expect(throws: Gzip.Error.invalidData) { try Gzip.decompress(Data("plain text".utf8)) }
        #expect(throws: Gzip.Error.invalidData) { try Gzip.decompress(Data()) }
    }

    @Test func enforcesOutputLimit() throws {
        let compressed = try Gzip.compress(Data(repeating: 0, count: 1_000_000))
        #expect(throws: Gzip.Error.outputTooLarge(limit: 1000)) { try Gzip.decompress(compressed, limit: 1000) }
    }

    @Test func ignoresTrailingZeroPadding() throws {
        let padded = try Gzip.compress(Data("x".utf8)) + Data(repeating: 0, count: 16)
        #expect(try Gzip.decompress(padded) == Data("x".utf8))
    }
}

/// Bitwise CRC-32 (IEEE 802.3), independent of zlib, for checking gzip trailers.
enum CRC32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

/// Deterministic random numbers for reproducible tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}
