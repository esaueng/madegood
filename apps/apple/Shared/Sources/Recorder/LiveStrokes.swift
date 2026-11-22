import Foundation
import Synchronization
import WaterKit

/// The live paddle-stroke detector for kayak, canoe and SUP. Motion arrives on the motion
/// queue at the sensor rate, so the detector lives behind a lock there; the recorder reads
/// a snapshot about once a second on the main actor.
///
/// Everything runs on the session's monotonic clock (the motion lines' clock), never the
/// wall clock, so a system clock change cannot make the rate look stale.
///
/// The count is of strokes in moving time, as session detail counts them: strokes in the
/// engine's auto-pauses and vehicle legs are left out. Those are dated back when they are
/// confirmed, so the count can step down (and back up after an auto-resume), as distance
/// does.
final class LiveStrokes: Sendable {
    private let detector: Mutex<StrokeDetector>
    /// The monotonic clock at the session start: a motion time minus this is session time.
    private let startMono: Double
    private let now: @Sendable () -> Double

    /// `now` returns the monotonic clock's current time (absolute, Unix s).
    init(sport: Sport, startMono: Double, now: @escaping @Sendable () -> Double) {
        detector = Mutex(StrokeDetector(sport: sport, recordsCycles: true))
        self.startMono = startMono
        self.now = now
    }

    convenience init(sport: Sport, clock: RawFormat.MonotonicClock) {
        self.init(sport: sport, startMono: clock.startUnix) {
            clock.absolute(uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    func ingest(_ line: RawFormat.MotionLine) {
        let sample = MotionSample(
            t: line.ts - startMono,
            userAcceleration: Vector3(x: line.ax, y: line.ay, z: line.az),
            gravity: Vector3(x: line.gx, y: line.gy, z: line.gz),
            rotationRate: Vector3(x: line.rx, y: line.ry, z: line.rz),
            attitude: Quaternion(x: line.qx, y: line.qy, z: line.qz, w: line.qw))
        detector.withLock { $0.ingest(sample) }
    }

    /// The user's manual pause or resume, now: strokes stop counting while paused, as all
    /// other accounting does. Auto-pause is not passed here; `snapshot(excluding:)` applies it.
    func userEvent(_ type: EventType) {
        let event = SessionEvent(t: now() - startMono, type: type)
        detector.withLock { $0.ingest(event) }
    }

    /// The metrics now, so the rate blanks when paddling stops. The count leaves out strokes
    /// in `excluded`: the engine's auto-pauses and vehicle legs, on the engine's clock (wall
    /// time since the start, `sessionNow` now). They are moved onto the motion clock with
    /// the current difference between the two clocks, which is zero unless the wall clock
    /// was changed during the session.
    func snapshot(excluding excluded: [ClosedRange<Double>] = [], sessionNow: Double? = nil) -> StrokeDetector.Metrics {
        let current = now() - startMono
        let shift = sessionNow.map { current - $0 } ?? 0
        let moved = excluded.map { ($0.lowerBound + shift)...($0.upperBound + shift) }
        return detector.withLock { detector in
            detector.advance(to: current)
            var metrics = detector.snapshot
            metrics.strokeCount = StrokeAnalysis.strokeCount(
                cycles: detector.cycles, strokesPerCycle: detector.strokesPerCycle, excluding: moved,
                isPaused: { detector.isPaused(at: $0) })
            return metrics
        }
    }
}
