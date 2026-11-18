import Synchronization
import WaterKit

/// The live paddle-stroke detector for kayak, canoe and SUP. Motion arrives on the motion
/// queue at the sensor rate, so the detector lives behind a lock there; the recorder reads
/// a snapshot about once a second on the main actor.
final class LiveStrokes: Sendable {
    private let detector: Mutex<StrokeDetector>
    /// Device uptime at the session start: motion `ts` minus this is session time.
    private let startUptime: Double

    init(sport: Sport, startUptime: Double) {
        detector = Mutex(StrokeDetector(sport: sport))
        self.startUptime = startUptime
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

    /// The metrics with the clock moved to `t` (session time), so the rate blanks when
    /// paddling stops.
    func snapshot(at t: Double) -> StrokeDetector.Metrics {
        detector.withLock { detector in
            detector.advance(to: t)
            return detector.snapshot
        }
    }
}
