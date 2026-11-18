import Foundation
import Testing

@testable import WaterKit

@Suite struct OffWaterSuggestionsTests {
    // Synthetic metre-space polygons centred at (0°, 0°). The fixtures are small
    // enough for the equatorial planar approximation; there is no real map input.
    private static let degreesPerMeter = 180 / (Double.pi * Geo.earthRadius)

    private struct Rectangle: Sendable {
        let x: ClosedRange<Double>
        let y: ClosedRange<Double>

        func signedDistance(x px: Double, y py: Double) -> Double {
            let dx = max(x.lowerBound - px, px - x.upperBound)
            let dy = max(y.lowerBound - py, py - y.upperBound)
            if dx <= 0 && dy <= 0 { return max(dx, dy) }
            return hypot(max(dx, 0), max(dy, 0))
        }
    }

    private struct SyntheticBoundaries: WaterBoundarySource {
        let coverage = Rectangle(x: -1000...1000, y: -1000...1000)
        var water = [Rectangle(x: 0...200, y: -250...250), Rectangle(x: -1200 ... -650, y: -1200...1200)]
        var masks = [Rectangle(x: -30...125, y: 100...160)]
        var coverageHoles: [Rectangle] = []

        func evidence(latitude: Double, longitude: Double) -> WaterBoundaryEvidence? {
            let x = longitude / degreesPerMeter
            let y = latitude / degreesPerMeter
            let edge = -coverage.signedDistance(x: x, y: y)
            let hole = coverageHoles.map { $0.signedDistance(x: x, y: y) }.min() ?? .infinity
            guard edge > 0, hole > 0 else { return nil }
            let mask = masks.map { $0.signedDistance(x: x, y: y) }.min() ?? .infinity
            guard mask > 0 else { return .ambiguous }
            let boundary = water.map { $0.signedDistance(x: x, y: y) }.min() ?? .infinity
            let clearance = min(abs(boundary), edge, hole, mask)
            return boundary < 0 ? .water(clearanceMeters: clearance) : .land(clearanceMeters: clearance)
        }
    }

    private static func fix(_ t: Int, x: Int, y: Int = 0, accuracy: Double? = 4, speed: Double = 0) -> GPSFix {
        GPSFix(
            t: Double(t), latitude: Double(y) * degreesPerMeter, longitude: Double(x) * degreesPerMeter,
            horizontalAccuracy: accuracy, speed: speed)
    }

    private static func hold(
        _ times: ClosedRange<Int>, x: Int, y: Int = 0, accuracy: Double? = 4
    ) -> [GPSFix] {
        times.map { fix($0, x: x, y: y, accuracy: accuracy) }
    }

    private static func transect(
        _ start: Int, from x1: Int, to x2: Int, y: Int = 0, accuracy: Double? = 4
    ) -> [GPSFix] {
        let step = x2 > x1 ? 2 : -2
        return (0..<abs((x2 - x1) / step)).map {
            fix(start + $0, x: x1 + $0 * step, y: y, accuracy: accuracy, speed: 2)
        }
    }

    private static func session(_ gps: [GPSFix], end: Double? = nil) -> RawSession {
        let meta = RawSessionReaderTests.meta(endedAt: end.map { RawSessionReaderTests.startUnix + $0 })
        return RawSession(meta: meta, gps: gps)
    }

    private static let launch = hold(4...63, x: -100) + transect(64, from: -100, to: 100) + hold(164...200, x: 100)
    private static let landing = hold(0...30, x: 100) + transect(31, from: 100, to: -100) + hold(131...190, x: -100)

    @Test func suggestsOnlyObservedLandBeforeAnInlandLake() throws {
        let raw = Self.session(Self.launch, end: 230)
        let suggestions = OffWaterSuggestions.suggest(in: raw, using: SyntheticBoundaries())
        let proposal = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(proposal.originalClockRange == 4...102)
        #expect(proposal.confidence == .supported)
        #expect(proposal.reason.waterContext == .after)
        #expect(proposal.reason.landFixCount == 99)
        #expect(abs(proposal.reason.minimumClearanceMeters - 1) < 0.001)
    }

    @Test func findsTrailingLandWithoutExtendingAcrossAQuietTail() throws {
        let raw = Self.session(Self.landing, end: 400)
        let suggestions = OffWaterSuggestions.suggest(in: raw, using: SyntheticBoundaries())
        let proposal = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(proposal.originalClockRange == 93...190)
        #expect(proposal.reason.waterContext == .before)
    }

    @Test func acceptsTheSameEvidenceAtACoastalBoundary() throws {
        let gps =
            Self.hold(0...60, x: -550) + Self.transect(61, from: -550, to: -750)
            + Self.hold(161...200, x: -750)
        let proposals = OffWaterSuggestions.suggest(in: Self.session(gps), using: SyntheticBoundaries())
        let proposal = try #require(proposals.first)
        #expect(proposals.count == 1)
        #expect(proposal.originalClockRange == 0...99)
    }

    @Test func corroboratesAnInteriorSpanAndLeavesWaterOnBothSides() throws {
        let gps = Self.landing + Self.transect(191, from: -100, to: 100) + Self.hold(291...330, x: 100)
        let raw = Self.session(gps)
        let suggestions = OffWaterSuggestions.suggest(in: raw, using: SyntheticBoundaries())
        let proposal = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(proposal.originalClockRange == 93...229)
        #expect(proposal.confidence == .corroborated)
        #expect(proposal.reason.waterContext == .beforeAndAfter)
    }

    @Test func slowStopsAndSparseFixesOnWaterGiveNoLandEvidence() {
        let gps = Self.hold(0...60, x: 100) + Self.hold(200...260, x: 100)
        var raw = Self.session(gps, end: 300)
        raw.events = [.init(t: 50, type: .pause), .init(t: 200, type: .resume), .init(t: 300, type: .stop)]
        #expect(OffWaterSuggestions.suggest(in: raw, using: SyntheticBoundaries()).isEmpty)
    }

    @Test func skipsAnEntirelyLandSessionAndInsufficientWaterContext() {
        let land = Self.session(Self.hold(0...120, x: -100))
        #expect(OffWaterSuggestions.suggest(in: land, using: SyntheticBoundaries()).isEmpty)

        // End 14 seconds after the first well-inside-water fix.
        let shortWater = Self.session(Self.launch, end: 140)
        #expect(OffWaterSuggestions.suggest(in: shortWater, using: SyntheticBoundaries()).isEmpty)
    }

    @Test func rejectsBriefLandAndDistantWaterRuns() {
        let shortLand = Self.session(Self.launch.filter { $0.t >= 70 })
        #expect(OffWaterSuggestions.suggest(in: shortLand, using: SyntheticBoundaries()).isEmpty)

        let approach = Self.launch.filter { $0.t < 114 }
        let shoreline = Self.hold(114...240, x: 0)
        let departure = Self.transect(241, from: 0, to: 100) + Self.hold(291...330, x: 100)
        let remoteWater = Self.session(approach + shoreline + departure)
        #expect(OffWaterSuggestions.suggest(in: remoteWater, using: SyntheticBoundaries()).isEmpty)
    }

    @Test func noGPSOrUnusableTimestampsAbstain() {
        let empty = Self.session([], end: 230)
        #expect(OffWaterSuggestions.suggest(in: empty, using: SyntheticBoundaries()).isEmpty)

        var gps = Self.launch
        gps.insert(Self.fix(4, x: 100), at: 1)
        let conflicting = Self.session(gps)
        #expect(OffWaterSuggestions.suggest(in: conflicting, using: SyntheticBoundaries()).isEmpty)
    }

    @Test func poorAccuracyAndDockGeometrySuppressLandClaims() {
        for (y, accuracy, waterX) in [(0, 12.0, 100), (130, 4.0, 164)] {
            let arrival = 70 + (waterX + 36) / 2
            let gps =
                Self.hold(0...69, x: -36, y: y, accuracy: accuracy)
                + Self.transect(70, from: -36, to: waterX, y: y, accuracy: accuracy)
                + Self.hold(arrival...(arrival + 40), x: waterX, y: y, accuracy: accuracy)
            let raw = Self.session(gps)
            #expect(OffWaterSuggestions.suggest(in: raw, using: SyntheticBoundaries()).isEmpty)
        }
    }

    @Test func uncoveredTransitionsAndInaccurateFixesBreakWaterContext() {
        var boundaries = SyntheticBoundaries()
        boundaries.coverageHoles = [Rectangle(x: -10...10, y: -20...20)]
        let raw = Self.session(Self.launch)
        #expect(OffWaterSuggestions.suggest(in: raw, using: boundaries).isEmpty)

        var gps = Self.launch
        gps[110 - 4].horizontalAccuracy = nil
        #expect(OffWaterSuggestions.suggest(in: Self.session(gps), using: SyntheticBoundaries()).isEmpty)
    }

    @Test func sparseLandAndDamagedStreamsDoNotSupportASuggestion() {
        let sparse = stride(from: 4, through: 63, by: 3).map { Self.fix($0, x: -100) }
        let gps = sparse + Self.transect(64, from: -100, to: 100) + Self.hold(164...200, x: 100)
        #expect(OffWaterSuggestions.suggest(in: Self.session(gps), using: SyntheticBoundaries()).isEmpty)

        var damaged = Self.session(Self.launch)
        damaged.issues = [.init(file: RawFormat.Stream.gps.gzippedFileName, line: nil, kind: .truncatedFile)]
        #expect(OffWaterSuggestions.suggest(in: damaged, using: SyntheticBoundaries()).isEmpty)
    }

    @Test func doesNotSpanAWaterChannelBetweenTwoLandFixes() throws {
        var boundaries = SyntheticBoundaries()
        boundaries.water.append(Rectangle(x: -155 ... -145, y: -250...250))
        let crossing = [Self.fix(191, x: -120, speed: 5), Self.fix(193, x: -180, speed: 11)]
        let raw = Self.session(Self.landing + crossing + Self.hold(202...260, x: -180))
        let suggestions = OffWaterSuggestions.suggest(in: raw, using: boundaries)
        let proposal = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(proposal.originalClockRange == 93...191)
    }
}
