/// Local evidence at a fix. Clearance is a conservative lower bound in metres to
/// the opposite surface, an ambiguous feature, or the edge of verified coverage.
/// The provider accounts for its map error when computing this bound.
public enum WaterBoundaryEvidence: Sendable, Hashable {
    case land(clearanceMeters: Double)
    case water(clearanceMeters: Double)
    case ambiguous
}

/// A locally installed boundary dataset. Queries must stay on device. Return nil
/// for unavailable or unverified coverage, and `.ambiguous` for known uncertainty
/// within coverage, such as docks, bridges and tidal flats.
public protocol WaterBoundarySource: Sendable {
    func evidence(latitude: Double, longitude: Double) -> WaterBoundaryEvidence?
}

/// A candidate interval to review for removal from the original recording.
public struct OffWaterSuggestion: Sendable, Hashable {
    public enum Confidence: Sendable, Hashable {
        /// Sustained land with nearby sustained water on one side.
        case supported
        /// Sustained land with nearby sustained water before and after.
        case corroborated
    }

    public enum WaterContext: Sendable, Hashable {
        case before, after, beforeAndAfter
    }

    public struct Reason: Sendable, Hashable {
        public let landFixCount: Int
        /// Smallest clearance left after the shoreline and GPS accuracy buffers.
        public let minimumClearanceMeters: Double
        public let waterContext: WaterContext
    }

    /// Inclusive timestamps of the first and last supported land fixes, in seconds
    /// since the original recording started. No extrapolation to the session edges.
    public let originalClockRange: ClosedRange<Double>
    /// An evidence level for review. It has no probabilistic interpretation.
    public let confidence: Confidence
    public let reason: Reason
}

/// Conservative post-session analysis. The result is advisory and has no storage or
/// editing side effects. Always provide the original recording on its original clock.
public enum OffWaterSuggestions {
    private static let maximumFixGapSeconds = 2.5
    private static let shorelineBufferMeters = 15.0
    private static let accuracyMultiplier = 2.0
    private static let maximumTransitionSeconds = 120.0

    public static func suggest(in session: RawSession, using boundaries: any WaterBoundarySource)
        -> [OffWaterSuggestion]
    {
        let availableEnd = SessionTrim.availableEnd(in: session)
        guard availableEnd.isFinite, availableEnd > 0 else { return [] }
        guard
            !session.issues.contains(where: { issue in
                issue.file == RawFormat.Stream.gps.fileName || issue.file == RawFormat.Stream.gps.gzippedFileName
                    || issue.file == RawFormat.Stream.clock.fileName
                    || issue.file == RawFormat.Stream.clock.gzippedFileName
            })
        else { return [] }

        let runs = evidenceRuns(session.gps, through: availableEnd, using: boundaries)
        return runs.indices.compactMap { index in
            let land = runs[index]
            guard land.surface == .land, land.duration >= 45, land.fixCount >= 24 else { return nil }
            let before = index > 0 && runs[index - 1].supportsWaterContext(for: land)
            let after = index + 1 < runs.count && runs[index + 1].supportsWaterContext(for: land)
            guard before || after else { return nil }
            let context: OffWaterSuggestion.WaterContext =
                before && after ? .beforeAndAfter : (before ? .before : .after)
            return OffWaterSuggestion(
                originalClockRange: land.start...land.lastFix.t,
                confidence: context == .beforeAndAfter ? .corroborated : .supported,
                reason: .init(
                    landFixCount: land.fixCount, minimumClearanceMeters: land.minimumClearance,
                    waterContext: context))
        }
    }

    private enum Surface { case land, water }

    private struct Run {
        let surface: Surface
        let block: Int
        let start: Double
        var lastFix: GPSFix
        var lastClearance: Double
        var minimumClearance: Double
        var fixCount = 1

        var duration: Double { lastFix.t - start }

        func supportsWaterContext(for land: Run) -> Bool {
            guard surface == .water, block == land.block, duration >= 20, fixCount >= 12 else { return false }
            let separation = max(land.start - lastFix.t, start - land.lastFix.t)
            return separation <= maximumTransitionSeconds
        }

        func canExtend(to fix: GPSFix, clearance: Double) -> Bool {
            let step = Geo.distance(
                lat1: lastFix.latitude, lon1: lastFix.longitude, lat2: fix.latitude, lon2: fix.longitude)
            // Overlapping clear areas support the direct step. A narrow water or
            // coverage gap between two land fixes must be able to break the run.
            // Allow for the spherical distance approximation used by Geo.
            return step * 1.01 < lastClearance + clearance
        }

        mutating func append(_ fix: GPSFix, clearance: Double) {
            lastFix = fix
            lastClearance = clearance
            minimumClearance = min(minimumClearance, clearance)
            fixCount += 1
        }
    }

    private static func evidenceRuns(
        _ gps: [GPSFix], through end: Double, using boundaries: any WaterBoundarySource
    ) -> [Run] {
        var filter = GPSFilter()
        var runs: [Run] = []
        var previousTime = -Double.infinity
        var block = 0
        var canExtendRun = false

        for fix in gps {
            // A conflicting or invalid timestamp cannot be placed on the editor clock.
            guard fix.t.isFinite, fix.t > previousTime else { return [] }
            let gap = fix.t - previousTime
            previousTime = fix.t
            guard fix.t >= 0, fix.t <= end else { continue }

            if gap > maximumFixGapSeconds {
                filter = GPSFilter()
                block += 1
                canExtendRun = false
            }
            guard case .accepted = filter.ingest(fix), let accuracy = fix.horizontalAccuracy,
                let evidence = boundaries.evidence(latitude: fix.latitude, longitude: fix.longitude)
            else {
                block += 1
                canExtendRun = false
                continue
            }

            let surface: Surface
            let mapClearance: Double
            switch evidence {
            case .ambiguous:
                canExtendRun = false
                continue
            case .land(let clearance):
                surface = .land
                mapClearance = clearance
            case .water(let clearance):
                surface = .water
                mapClearance = clearance
            }
            guard mapClearance.isFinite, mapClearance >= 0 else {
                block += 1
                canExtendRun = false
                continue
            }
            let clearance = mapClearance - shorelineBufferMeters - accuracyMultiplier * accuracy
            guard clearance > 0 else {
                canExtendRun = false
                continue
            }

            if canExtendRun, let last = runs.last, last.surface == surface,
                last.canExtend(to: fix, clearance: clearance)
            {
                runs[runs.count - 1].append(fix, clearance: clearance)
            } else {
                runs.append(
                    Run(
                        surface: surface, block: block, start: fix.t, lastFix: fix, lastClearance: clearance,
                        minimumClearance: clearance))
            }
            canExtendRun = true
        }
        return runs
    }
}
