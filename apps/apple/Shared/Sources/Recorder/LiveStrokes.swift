import Foundation
import Synchronization
import WaterKit

/// The live paddle-stroke detector for kayak, canoe and SUP. Motion arrives on the motion
/// queue at the sensor rate, so the detector lives behind a lock there; the recorder reads
/// a snapshot about once a second on the main actor.
///
/// Everything runs on device uptime (the motion timestamps' clock), never the wall clock,
/// so a system clock change cannot make the rate look stale.
final class LiveStrokes: Sendable {
    private let detector: Mutex<StrokeDetector>
    /// Device uptime at the session start: an uptime minus this is session time.
    private let startUptime: Double
    private let uptime: @Sendable () -> Double

    init(
        sport: Sport, startUptime: Double,
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        detector = Mutex(StrokeDetector(sport: sport))
        self.startUptime = startUptime
        self.uptime = uptime
    }

    func ingest(_ line: RawFormat.MotionLine) {
        let sample = MotionSample(
            t: line.ts - startUptime,
            userAcceleration: Vector3(x: line.ax, y: line.ay, z: line.az),
            gravity: Vector3(x: line.gx, y: line.gy, z: line.gz),
            rotationRate: Vector3(x: line.rx, y: line.ry, z: line.rz),
            attitude: Quaternion(x: line.qx, y: line.qy, z: line.qz, w: line.qw))
        detector.withLock { $0.ingest(sample) }
    }

    /// The user's manual pause or resume, now: strokes stop counting while paused, as all
    /// other accounting does. Auto-pause is not passed here; strokes count through it.
    func userEvent(_ type: EventType) {
        let event = SessionEvent(t: uptime() - startUptime, type: type)
        detector.withLock { $0.ingest(event) }
    }

    /// The metrics now, so the rate blanks when paddling stops.
    func snapshot() -> StrokeDetector.Metrics {
        let now = uptime() - startUptime
        return detector.withLock { detector in
            detector.advance(to: now)
            return detector.snapshot
        }
    }
}
