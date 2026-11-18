import CZlib
import Foundation

/// An immutable, synthetic-only local pack. A failed import yields no evidence
/// anywhere. A successful import is safe to reuse across a session's fixes.
public struct PackedWaterBoundarySource: WaterBoundarySource {
    public struct Manifest: Decodable, Sendable {
        public struct Provenance: Decodable, Sendable {
            public let kind: String
            public let source: String
            public let revision: String
            public let license: String
        }

        public let formatVersion: Int
        public let packID: String
        public let revision: Int
        public let provenance: Provenance
        /// Combined source, transformation and quantization allowance for all edges.
        public let uncertaintyMeters: Double
    }

    public enum ImportError: Error, Equatable, Sendable {
        case unreadable
        case oversized
        case corrupt
        case unsupportedVersion(Int)
        case unsupportedProvenance
        case invalidManifest
        case invalidGeometry
    }

    private static let byteLimit = 256 * 1024
    private static let magic = Data("MGWB ".utf8)
    private static let headerSize = 14
    private let pack: Result<Pack, ImportError>

    public var validation: Result<Manifest, ImportError> {
        pack.map(\.manifest)
    }

    public init(data: Data) {
        do {
            pack = .success(try Self.decode(data))
        } catch {
            pack = .failure(error)
        }
    }

    /// Reads only the supplied local file, with a bounded read before decoding.
    public init(contentsOf url: URL) {
        guard url.isFileURL else {
            self.init(failure: .unreadable)
            return
        }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            let limit = Self.byteLimit + 1
            while data.count < limit, let chunk = try file.read(upToCount: limit - data.count), !chunk.isEmpty {
                data.append(chunk)
            }
            self.init(data: data)
        } catch {
            self.init(failure: .unreadable)
        }
    }

    private init(failure: ImportError) {
        pack = .failure(failure)
    }

    public func evidence(latitude: Double, longitude: Double) -> WaterBoundaryEvidence? {
        guard case .success(let pack) = pack, latitude.isFinite, longitude.isFinite else { return nil }
        return pack.evidence(at: BoundaryPoint(x: longitude * 1_000_000, y: latitude * 1_000_000))
    }

    private struct Header: Decodable {
        struct Version: Decodable {
            let formatVersion: Int
        }
        let manifest: Version
    }

    private static func decode(_ data: Data) throws(ImportError) -> Pack {
        guard data.count <= byteLimit else { throw .oversized }
        guard data.count > headerSize, data.starts(with: magic) else { throw .corrupt }

        let checksumBytes = data.dropFirst(magic.count).prefix(8)
        guard data.dropFirst(headerSize - 1).first == 10,
            checksumBytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let expected = UInt32(String(decoding: checksumBytes, as: UTF8.self), radix: 16)
        else { throw .corrupt }

        let payload = data.dropFirst(headerSize)
        let actual = payload.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        // JSONDecoder can also accept UTF-16/32. The v1 wire payload is strictly UTF-8 JSON.
        guard actual == expected, !payload.contains(0), String(data: payload, encoding: .utf8) != nil else {
            throw .corrupt
        }

        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: payload) else { throw .corrupt }
        let version = header.manifest.formatVersion
        guard version == 1 else { throw .unsupportedVersion(version) }
        guard let pack = try? decoder.decode(Pack.self, from: payload) else { throw .corrupt }
        let manifest = pack.manifest
        guard manifest.provenance.kind == "synthetic" else { throw .unsupportedProvenance }
        let labels = [
            manifest.packID, manifest.provenance.source, manifest.provenance.revision, manifest.provenance.license,
        ]
        guard labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            manifest.revision > 0, manifest.uncertaintyMeters.isFinite, manifest.uncertaintyMeters >= 0
        else { throw .invalidManifest }
        guard pack.hasValidGeometry else { throw .invalidGeometry }
        return pack
    }

    private struct Coverage: Decodable, Sendable {
        let westE6: Int
        let eastE6: Int
        let southE6: Int
        let northE6: Int

        var isValid: Bool {
            // V1 covers at most a one-degree rectangle away from wrapping and the poles.
            let supportedLongitudes = -179_999_999...179_999_999
            let supportedLatitudes = -80_000_000...80_000_000
            return supportedLongitudes.contains(westE6) && supportedLongitudes.contains(eastE6)
                && supportedLatitudes.contains(southE6) && supportedLatitudes.contains(northE6)
                && (1...1_000_000).contains(eastE6 - westE6) && (1...1_000_000).contains(northE6 - southE6)
        }

        func contains(_ vertex: BoundaryVertex) -> Bool {
            (westE6...eastE6).contains(vertex.x) && (southE6...northE6).contains(vertex.y)
        }

        var longitudeScale: Double {
            let maximumLatitude = Double(max(abs(southE6), abs(northE6))) / 1_000_000
            return BoundaryPoint.latitudeScale * cos(maximumLatitude * .pi / 180)
        }

        func clearance(to point: BoundaryPoint, longitudeScale: Double) -> Double {
            let longitudeDelta = min(point.x - Double(westE6), Double(eastE6) - point.x)
            let latitudeDelta = min(point.y - Double(southE6), Double(northE6) - point.y)
            return min(longitudeDelta * longitudeScale, latitudeDelta * BoundaryPoint.latitudeScale)
        }
    }

    private struct Pack: Decodable, Sendable {
        let manifest: Manifest
        let coverage: Coverage
        let coastalWater: [BoundaryPolygon]
        let inlandWater: [BoundaryPolygon]
        let docks: [BoundaryPolygon]
        let bridges: [BoundaryPolygon]
        let unverified: [BoundaryPolygon]

        var hasValidGeometry: Bool {
            guard coverage.isValid else { return false }
            let polygons = coastalWater + inlandWater + docks + bridges + unverified
            var totalVertices = 0
            for polygon in polygons {
                let rings = [polygon.outer] + polygon.holes
                let count = rings.reduce(0) { $0 + $1.count }
                totalVertices += count
                guard count <= 256, totalVertices <= 4096,
                    rings.allSatisfy({ $0.count >= 3 && $0.allSatisfy(coverage.contains) }),
                    polygon.isValid()
                else { return false }
            }
            return true
        }

        func evidence(at point: BoundaryPoint) -> WaterBoundaryEvidence? {
            let longitudeScale = coverage.longitudeScale
            // Subtract one millimetre beyond the source allowance for arithmetic roundoff.
            let allowance = manifest.uncertaintyMeters + 0.001
            var clearance = coverage.clearance(to: point, longitudeScale: longitudeScale)
            guard clearance > allowance else { return nil }

            for polygon in unverified {
                let result = polygon.measure(at: point, longitudeScale: longitudeScale)
                guard !result.inside, result.distance > allowance else { return nil }
                clearance = min(clearance, result.distance)
            }

            for layer in [docks, bridges] {
                for polygon in layer {
                    let result = polygon.measure(at: point, longitudeScale: longitudeScale)
                    guard !result.inside, result.distance > allowance else { return .ambiguous }
                    clearance = min(clearance, result.distance)
                }
            }

            var inWater = false
            for layer in [coastalWater, inlandWater] {
                for polygon in layer {
                    let result = polygon.measure(at: point, longitudeScale: longitudeScale)
                    guard result.distance > allowance else { return .ambiguous }
                    inWater = inWater || result.inside
                    clearance = min(clearance, result.distance)
                }
            }

            clearance -= allowance
            return inWater ? .water(clearanceMeters: clearance) : .land(clearanceMeters: clearance)
        }
    }
}
