import CZlib
import Foundation
import Testing

@testable import WaterKit

@Suite struct WaterBoundaryPackTests {
    private static func fixtureURL() throws -> URL {
        let url = Bundle.module.url(
            forResource: "synthetic-water-boundaries", withExtension: "mgwb", subdirectory: "Resources")
        return try #require(url)
    }

    private static func fixturePayload() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL())
        let newline = try #require(data.firstIndex(of: 10))
        let payload = try JSONSerialization.jsonObject(with: data.dropFirst(newline + 1))
        return try #require(payload as? [String: Any])
    }

    // Generate checksummed invalid variants so each test reaches the intended validator.
    private static func frame(_ contents: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys])
        return frame(payload)
    }

    private static func frame(_ payload: Data) -> Data {
        let checksum = payload.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        return Data(String(format: "MGWB %08x\n", UInt32(checksum)).utf8) + payload
    }

    private static func evidence(
        _ source: PackedWaterBoundarySource, x: Double, y: Double = 0
    ) -> WaterBoundaryEvidence? {
        source.evidence(latitude: y / 1_000_000, longitude: x / 1_000_000)
    }

    private static func expectClearance(
        _ actual: WaterBoundaryEvidence?, expected: WaterBoundaryEvidence,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch (actual, expected) {
        case (.land(let observed), .land(let target)), (.water(let observed), .water(let target)):
            #expect(abs(observed - target) < 0.0001, sourceLocation: sourceLocation)
        default:
            Issue.record("Expected \(expected), got \(String(describing: actual))", sourceLocation: sourceLocation)
        }
    }

    private static func expectRejected(
        _ source: PackedWaterBoundarySource, as expected: PackedWaterBoundarySource.ImportError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .failure(let error) = source.validation else {
            Issue.record("Invalid pack accepted", sourceLocation: sourceLocation)
            return
        }
        #expect(error == expected, sourceLocation: sourceLocation)
        #expect(evidence(source, x: 1000) == nil, sourceLocation: sourceLocation)
    }

    @Test func importsFixtureWithProvenanceAndClassifiesBothWatersAndAnIsland() throws {
        let source = PackedWaterBoundarySource(contentsOf: try Self.fixtureURL())
        let manifest = try source.validation.get()
        #expect(manifest.formatVersion == 1)
        #expect(manifest.packID == "madegood-synthetic-boundaries")
        #expect(manifest.revision == 1)
        #expect(manifest.provenance.kind == "synthetic")
        #expect(manifest.provenance.revision == "fixture-v1")
        #expect(manifest.provenance.license == "Apache-2.0")
        #expect(manifest.uncertaintyMeters == 8)

        Self.expectClearance(Self.evidence(source, x: -8000), expected: .water(clearanceMeters: 156.998994))
        Self.expectClearance(
            Self.evidence(source, x: 1000), expected: .water(clearanceMeters: hypot(44, 99) - 8.001))
        Self.expectClearance(Self.evidence(source, x: 2350), expected: .land(clearanceMeters: 30.498999))
        Self.expectClearance(Self.evidence(source, x: -1000), expected: .land(clearanceMeters: 101.998996))
        #expect(Self.evidence(source, x: 2000) == .ambiguous)
        #expect(Self.evidence(source, x: 2050) == .ambiguous)
    }

    @Test func masksDocksBridgesAndShorelineAndCapsClearanceNearThem() throws {
        let source = PackedWaterBoundarySource(contentsOf: try Self.fixtureURL())
        #expect(Self.evidence(source, x: -200, y: 1100) == .ambiguous)
        #expect(Self.evidence(source, x: 200, y: 1100) == .ambiguous)
        #expect(Self.evidence(source, x: -400, y: 1100) == .ambiguous)
        #expect(Self.evidence(source, x: 1200, y: -1400) == .ambiguous)
        #expect(Self.evidence(source, x: 1200, y: -2700) == .ambiguous)
        #expect(Self.evidence(source, x: 950, y: -1400) == .ambiguous)
        #expect(Self.evidence(source, x: -6500) == .ambiguous)
        #expect(Self.evidence(source, x: -6450) == .ambiguous)

        Self.expectClearance(Self.evidence(source, x: -500, y: 1100), expected: .land(clearanceMeters: 8.499))
        Self.expectClearance(Self.evidence(source, x: 900, y: -1400), expected: .water(clearanceMeters: 2.999))
        // Nearest point is the dock corner, not a point along either adjacent edge.
        Self.expectClearance(
            Self.evidence(source, x: -450, y: 1550), expected: .land(clearanceMeters: 11 * sqrt(2) - 8.001))
    }

    @Test func abstainsAtCoverageEdgesAndUnverifiedAreas() throws {
        let source = PackedWaterBoundarySource(contentsOf: try Self.fixtureURL())
        for x in [Double.nan, .infinity, 15_100, 15_000, 14_950, 5000, 4500, 4450] {
            #expect(Self.evidence(source, x: x) == nil)
        }
        #expect(source.evidence(latitude: -.infinity, longitude: 0) == nil)
        Self.expectClearance(Self.evidence(source, x: 14_900), expected: .land(clearanceMeters: 2.999))
        Self.expectClearance(Self.evidence(source, x: 4400), expected: .land(clearanceMeters: 2.999))
        // An unverified area takes precedence even when another layer offers positive evidence.
        var payload = try Self.fixturePayload()
        payload["unverified"] = payload["inlandWater"]
        let overlapping = PackedWaterBoundarySource(data: try Self.frame(payload))
        #expect(Self.evidence(overlapping, x: 1000) == nil)
    }

    @Test func usesConservativeLongitudeScaleAtMaximumAbsoluteLatitude() throws {
        var payload = try Self.fixturePayload()
        payload["coverage"] = ["westE6": -15_000, "eastE6": 15_000, "southE6": -60_000_000, "northE6": -59_970_000]
        for field in ["coastalWater", "inlandWater", "docks", "bridges", "unverified"] {
            payload[field] = []
        }
        let source = PackedWaterBoundarySource(data: try Self.frame(payload))
        _ = try source.validation.get()
        Self.expectClearance(
            Self.evidence(source, x: 14_800, y: -59_985_000), expected: .land(clearanceMeters: 2.999))
        #expect(Self.evidence(source, x: 14_900, y: -59_985_000) == nil)
    }

    @Test func corruptMissingAndOversizedPacksFailClosed() throws {
        let fixture = try Data(contentsOf: Self.fixtureURL())
        var altered = fixture
        let digit = try #require(altered.lastIndex(of: UInt8(ascii: "0")))
        altered[digit] = UInt8(ascii: "1")  // Still valid JSON.
        let newline = try #require(fixture.firstIndex(of: 10))
        let json = String(decoding: fixture.dropFirst(newline + 1), as: UTF8.self)
        let utf16 = try #require(json.data(using: .utf16))
        for broken in [Data(), Data(fixture.dropLast()), fixture + Data([0x20]), altered, Self.frame(utf16)] {
            Self.expectRejected(PackedWaterBoundarySource(data: broken), as: .corrupt)
        }
        let oversized = Data(repeating: 0, count: 256 * 1024 + 1)
        Self.expectRejected(PackedWaterBoundarySource(data: oversized), as: .oversized)
        let missing = try Self.fixtureURL().appendingPathComponent("missing")
        Self.expectRejected(PackedWaterBoundarySource(contentsOf: missing), as: .unreadable)
        let remote = try #require(URL(string: "https://example.invalid/synthetic"))
        Self.expectRejected(PackedWaterBoundarySource(contentsOf: remote), as: .unreadable)
    }

    @Test func rejectsUnsupportedVersionProvenanceAndMissingLayers() throws {
        var payload = try Self.fixturePayload()
        var manifest = try #require(payload["manifest"] as? [String: Any])
        manifest["formatVersion"] = 2
        Self.expectRejected(
            PackedWaterBoundarySource(data: try Self.frame(["manifest": manifest])), as: .unsupportedVersion(2))

        manifest["formatVersion"] = 1
        manifest["uncertaintyMeters"] = -1
        payload["manifest"] = manifest
        Self.expectRejected(PackedWaterBoundarySource(data: try Self.frame(payload)), as: .invalidManifest)

        manifest["uncertaintyMeters"] = 8
        var provenance = try #require(manifest["provenance"] as? [String: Any])
        provenance["kind"] = "regional"
        manifest["provenance"] = provenance
        payload["manifest"] = manifest
        Self.expectRejected(PackedWaterBoundarySource(data: try Self.frame(payload)), as: .unsupportedProvenance)

        payload = try Self.fixturePayload()
        payload.removeValue(forKey: "inlandWater")
        Self.expectRejected(PackedWaterBoundarySource(data: try Self.frame(payload)), as: .corrupt)
    }

    @Test func rejectsInvalidGeometryWithoutKeepingOtherLayers() throws {
        var payload = try Self.fixturePayload()
        let outer = [[0, 0], [500, 0], [500, 500], [0, 500]]
        let inside = [[100, 100], [400, 100], [400, 400], [100, 400]]
        let nested = [[200, 200], [300, 200], [300, 300], [200, 300]]
        let touching = [[0, 100], [200, 100], [200, 200], [0, 200]]
        let outside = [[600, 600], [700, 600], [700, 700], [600, 700]]
        let bowTie = [[0, 0], [500, 500], [0, 500], [500, 0]]
        let beyondCoverage = [[0, 0], [500, 0], [500, Int.max], [0, 500]]

        for (outline, holes) in [
            (outer, [inside, nested]), (outer, [touching]), (outer, [outside]), (bowTie, []), (beyondCoverage, []),
            (outer + [outer[0]], []),
        ] {
            payload["inlandWater"] = [["outer": outline, "holes": holes]]
            Self.expectRejected(PackedWaterBoundarySource(data: try Self.frame(payload)), as: .invalidGeometry)
        }

        payload = try Self.fixturePayload()
        payload["coverage"] = ["westE6": 179_990_000, "eastE6": -179_990_000, "southE6": -15_000, "northE6": 15_000]
        Self.expectRejected(PackedWaterBoundarySource(data: try Self.frame(payload)), as: .invalidGeometry)
    }

    @Test func feedsOriginalClockSuggestionsUsingTheImportedPack() throws {
        let source = PackedWaterBoundarySource(contentsOf: try Self.fixtureURL())
        let gps = (0...220).map { second in
            let x = max(-1000, min(1000, (second - 120) * 20))
            return GPSFix(
                t: Double(second), latitude: 0, longitude: Double(x) / 1_000_000,
                horizontalAccuracy: 4, speed: second > 70 && second <= 170 ? 2.2 : 0)
        }
        let session = RawSession(meta: RawSessionReaderTests.meta(endedAt: nil), gps: gps)
        let suggestions = OffWaterSuggestions.suggest(in: session, using: source)
        let suggestion = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(suggestion.originalClockRange == 0...105)
        #expect(suggestion.reason.waterContext == .after)
        #expect(
            OffWaterSuggestions.suggest(in: session, using: PackedWaterBoundarySource(data: Data())).isEmpty)
    }
}
