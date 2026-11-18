import Foundation

/// A position on the Voyage timeline. Time is Unix seconds and measurements are SI.
public struct VoyagePosition: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let speed: Double?
    public let course: Double?

    public init(
        timestamp: TimeInterval, latitude: Double, longitude: Double,
        horizontalAccuracy: Double, speed: Double?, course: Double?
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
    }

    var isUsable: Bool {
        timestamp.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && (0...100).contains(horizontalAccuracy)
            && (speed.map { $0.isFinite && $0 >= 0 } ?? true)
            && (course.map { (0..<360).contains($0) } ?? true)
    }
}

public struct VoyageGap: Codable, Hashable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
}

public struct VoyageTrackPoint: Codable, Equatable, Sendable {
    public let position: VoyagePosition
    public let gapBefore: VoyageGap?
}

/// Thins writes while keeping the incoming stream available to detect capture gaps.
struct VoyageSampling {
    static let gapThreshold: TimeInterval = 30

    let startedAt: TimeInterval
    let acceptsFrom: TimeInterval
    var interrupted: Bool
    var lastSaved: VoyagePosition?
    private(set) var lastSeen: TimeInterval?
    private var stationary = false
    var stationaryPause = false

    init(startedAt: TimeInterval, acceptsFrom: TimeInterval, lastSaved: VoyagePosition?, interrupted: Bool) {
        self.startedAt = startedAt
        self.acceptsFrom = acceptsFrom
        self.lastSaved = lastSaved
        self.interrupted = interrupted
    }

    var lastCoverage: TimeInterval { lastSeen ?? lastSaved?.timestamp ?? startedAt }

    mutating func ingest(_ position: VoyagePosition, isStationary: Bool? = nil) -> VoyageTrackPoint? {
        let time = position.timestamp
        guard time >= acceptsFrom,
            lastSeen.map({ time > $0 }) ?? lastSaved.map({ time > $0.timestamp }) ?? true
        else { return nil }
        guard position.isUsable else {
            if isStationary == false { stationaryPause = false }
            return nil
        }

        let gap = gap(until: time)
        stationaryPause = false
        lastSeen = time
        // Doppler speed only. Missing speed calls for the underway cadence.
        let threshold = stationary ? 0.8 : 0.4
        stationary = position.speed.map { $0 < threshold } ?? false

        if gap == nil, let lastSaved {
            let interval: TimeInterval
            if stationary {
                interval = 60
            } else if (lastSaved.speed ?? 1) < 0.4 || isTurning(from: lastSaved.course, to: position.course) {
                interval = 5
            } else {
                interval = 8
            }
            guard time - lastSaved.timestamp >= interval else { return nil }
        }

        self.lastSaved = position
        interrupted = false
        return VoyageTrackPoint(position: position, gapBefore: gap)
    }

    func gap(until time: TimeInterval) -> VoyageGap? {
        let elapsed = time - lastCoverage
        guard elapsed > 0, interrupted || (!stationaryPause && elapsed > Self.gapThreshold) else { return nil }
        return VoyageGap(start: lastCoverage, end: time)
    }

    private func isTurning(from previous: Double?, to current: Double?) -> Bool {
        guard let previous, let current else { return false }
        let difference = abs(current - previous)
        return min(difference, 360 - difference) >= 20
    }
}
