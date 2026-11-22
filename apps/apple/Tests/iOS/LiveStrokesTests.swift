import Synchronization
import WaterKit
import XCTest

@testable import MadeGood

/// Regression tests for the PR #59 review: live strokes use one monotonic clock (device
/// uptime), and a manual pause stops counting.
final class LiveStrokesTests: XCTestCase {
    final class Uptime: Sendable {
        let value = Mutex(0.0)
        func set(_ t: Double) { value.withLock { $0 = t } }
        func read() -> Double { value.withLock { $0 } }
    }

    let startUptime = 1_000.0

    func motion(seconds: Double, rate: Double = 60) -> [MotionSample] {
        var simulator = PaddleMotionSimulator(sport: .sup, segments: [.init(duration: seconds, strokeRate: rate)])
        simulator.seed = 5
        return simulator.generate().samples
    }

    func feed(_ samples: [MotionSample], offset: Double = 0, to strokes: LiveStrokes, clock: Uptime) {
        for sample in samples {
            let ts = startUptime + offset + sample.t
            strokes.ingest(
                RawFormat.MotionLine(
                    ts: ts, userAcceleration: sample.userAcceleration, gravity: sample.gravity,
                    rotationRate: sample.rotationRate, attitude: sample.attitude))
            clock.set(ts)
        }
    }

    /// Finding 5: the recorder checked freshness against wall time while peaks were on
    /// uptime, so a forward clock correction blanked the rate. The snapshot now reads only
    /// uptime; the wall clock is not an input.
    func testRateUsesUptimeNotTheWallClock() throws {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        feed(motion(seconds: 60), to: strokes, clock: clock)
        let rate = try XCTUnwrap(strokes.snapshot().strokeRate)
        XCTAssertEqual(rate, 60, accuracy: 2)
        // Paddling stops: the rate blanks on uptime alone.
        clock.set(clock.read() + 15)
        XCTAssertNil(strokes.snapshot().strokeRate)
        XCTAssertGreaterThan(strokes.snapshot().strokeCount, 50)
    }

    /// Finding 2: strokes during a manual pause are not counted.
    func testManualPauseStopsCounting() {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        let samples = motion(seconds: 90)
        feed(samples.filter { $0.t < 30 }, to: strokes, clock: clock)
        strokes.userEvent(.pause)
        feed(samples.filter { $0.t >= 30 && $0.t < 40 }, to: strokes, clock: clock)
        let paused = strokes.snapshot().strokeCount
        strokes.userEvent(.resume)
        feed(samples.filter { $0.t >= 40 }, to: strokes, clock: clock)
        // About 30 strokes before the pause (the last may finish just after it), none during
        // it, and about 50 after.
        XCTAssertEqual(Double(paused), 30, accuracy: 2)
        XCTAssertEqual(Double(strokes.snapshot().strokeCount - paused), 50, accuracy: 2)
    }

    /// The live count kept strokes in auto-pauses and vehicle legs, which session detail
    /// leaves out. Those intervals come on the engine's wall-time clock and are moved onto
    /// the motion clock, so a wall clock set 100 s ahead leaves out the same strokes.
    func testCountLeavesOutAutoPausedIntervals() {
        let clock = Uptime()
        let strokes = LiveStrokes(sport: .sup, startMono: startUptime, now: clock.read)
        feed(motion(seconds: 60), to: strokes, clock: clock)
        let all = strokes.snapshot().strokeCount
        let now = clock.read() - startUptime
        let gated = strokes.snapshot(excluding: [20...40], sessionNow: now).strokeCount
        XCTAssertEqual(Double(all - gated), 20, accuracy: 2)
        XCTAssertEqual(strokes.snapshot(excluding: [120...140], sessionNow: now + 100).strokeCount, gated)
        // An auto-pause still open leaves out everything after its start.
        XCTAssertEqual(
            Double(strokes.snapshot(excluding: [30...Double.infinity], sessionNow: now).strokeCount), 30, accuracy: 2)
    }
}
