import Foundation
import Synchronization
import WaterKit

/// The live paddle-stroke detector for kayak, canoe and SUP. Motion arrives on the motion
/// queue at the sensor rate, so the detector lives behind a lock there; the recorder reads
/// a snapshot about once a second on the main actor.
///
/// Detection runs on the session's monotonic clock (the motion lines' clock), never the
/// wall clock, so a system clock change cannot make the rate look stale.
///
/// The count is of strokes in moving time, as session detail counts them: strokes in the
/// engine's auto-pauses and vehicle legs are left out. Those are dated back when they are
/// confirmed, so the count can step down (and back up after an auto-resume), as distance
/// does. The engine runs on wall time, so stroke times are placed on it with the same
/// clock anchors the recording stores, as session detail places them.
final class LiveStrokes: Sendable {
    private struct State {
        var detector: StrokeDetector
        /// The latest motion sample, to close its bin at the end.
        var lastSample: MotionSample?
        /// Wall time and monotonic time read together, both in seconds since the start, in
        /// recorded order. The first is the start itself.
        var anchors: [(mono: Double, wall: Double)] = [(0, 0)]
    }

    private let state: Mutex<State>
    /// The monotonic clock at the session start: a motion time minus this is session time.
    private let startMono: Double
    private let now: @Sendable () -> Double

    /// `now` returns the monotonic clock's current time (absolute, Unix s).
    init(sport: Sport, startMono: Double, now: @escaping @Sendable () -> Double) {
        state = Mutex(State(detector: StrokeDetector(sport: sport, recordsCycles: true)))
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
        state.withLock { state in
            state.detector.ingest(sample)
            state.lastSample = sample
        }
    }

    /// The user's manual pause or resume, now: strokes stop counting while paused, as all
    /// other accounting does. Auto-pause is not passed here; `snapshot(excluding:)` applies it.
    func userEvent(_ type: EventType) {
        let event = SessionEvent(t: now() - startMono, type: type)
        state.withLock { $0.detector.ingest(event) }
    }

    /// A clock anchor as the recorder writes it: `mono` (absolute monotonic time) and
    /// `wall` (Unix time) read together. Strokes after it are placed on wall time from it.
    func anchor(mono: Double, wall: Double) {
        let anchor = (mono: mono - startMono, wall: wall - startMono)
        state.withLock { state in
            guard let last = state.anchors.last, anchor.mono > last.mono else { return }
            state.anchors.append(anchor)
        }
    }

    /// Closes the last motion bin at the end of the session, as session detail does, so a
    /// stroke confirmed in it counts.
    func finish() {
        state.withLock { state in
            guard var closing = state.lastSample else { return }
            closing.t += state.detector.config.binInterval
            state.detector.ingest(closing)
            state.lastSample = nil
        }
    }

    /// The metrics now, so the rate blanks when paddling stops. The count leaves out strokes
    /// in `excluded`: the engine's auto-pauses and vehicle legs, in wall time since the start.
    func snapshot(excluding excluded: [ClosedRange<Double>] = []) -> StrokeDetector.Metrics {
        let current = now() - startMono
        return state.withLock { state in
            state.detector.advance(to: current)
            var metrics = state.detector.snapshot
            let anchors = state.anchors
            let detector = state.detector
            metrics.strokeCount = StrokeAnalysis.strokeCount(
                cycles: detector.cycles, strokesPerCycle: detector.strokesPerCycle, excluding: excluded,
                isPaused: { detector.isPaused(at: $0) },
                toSessionTime: { Self.wallTime(mono: $0, anchors: anchors) })
            return metrics
        }
    }

    /// `mono` (seconds since the start) on wall time from the latest anchor before it, as
    /// `SessionClock.fromMono` places samples after the session.
    static func wallTime(mono: Double, anchors: [(mono: Double, wall: Double)]) -> Double {
        var anchor = anchors[0]
        var low = 0
        var high = anchors.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if anchors[mid].mono < mono {
                anchor = anchors[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return anchor.wall + (mono - anchor.mono)
    }
}
