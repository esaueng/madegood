import Foundation
import WaterKit

/// The readings shared by the phone's local and mirrored live screens. Units are SI.
struct LiveReadings: Codable, Equatable, Sendable {
    var elapsed: Double
    var movingTime: Double
    var distance: Double
    var speed: Double?
    var averageSpeed: Double?
    var maxSpeed10s: Double?
    var course: Double?
    var heartRate: Double?
    var pauseState: LiveMetrics.PauseState
    var lap: Int?
    /// Paddle strokes (kayak, canoe, SUP); absent from older watches' snapshots.
    var strokeRate: Double?
    var strokeCount: Int?

    init(_ metrics: LiveMetrics?, strokes: StrokeDetector.Metrics? = nil) {
        elapsed = metrics?.elapsed ?? 0
        movingTime = metrics?.movingTime ?? 0
        distance = metrics?.distance ?? 0
        speed = metrics?.speed
        averageSpeed = metrics?.averageSpeed
        maxSpeed10s = metrics?.maxSpeed10s
        course = metrics?.course
        heartRate = metrics?.heartRate
        pauseState = metrics?.pauseState ?? .moving
        lap = metrics.flatMap { $0.laps.isEmpty ? nil : $0.currentLap.index }
        strokeRate = strokes?.strokeRate
        strokeCount = strokes?.strokeCount
    }
}

/// An ephemeral HealthKit message. Full snapshots make coalescing and reconnect safe.
struct WorkoutMirrorSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    /// The watch's recording UUID, also used in the finished file.
    let sessionID: UUID
    /// Increases for the entire recording, including across connection changes.
    let sequence: UInt64
    let sport: Sport
    let sentAt: Date
    let readings: LiveReadings

    func age(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(sentAt))
    }
}
