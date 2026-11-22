import Foundation
import Testing

@testable import WaterKit

/// Regression tests for the PR #59 scoped re-check findings.
@Suite struct StrokeRecheckRegressionTests {
    func rotation(from start: Double, to end: Double, cyclesPerMinute rate: Double) -> [MotionSample] {
        stride(from: start, to: end, by: 0.01).map { t in
            let s = 2 * sin(2 * Double.pi * rate / 60 * (t - start))
            return MotionSample(
                t: t, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -9.8),
                rotationRate: Vector3(x: s, y: 0, z: 0), attitude: .identity)
        }
    }

    /// Finding 1: the wall clock is set back 20 s during a pause. Post-session analysis
    /// keeps pause before resume (the monotonic clock) and counts the strokes after it.
    /// Versions 2 and 3 (absolute monotonic times) and version 1 (device uptime) alike.
    @Test(arguments: [1, 2, 3]) func backwardClockCorrectionKeepsPauseOrder(version: Int) throws {
        let start = 946_684_800.0
        let uptime0 = 100.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .sup, startedAt: start, endedAt: start + 70,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
        let motion = rotation(from: 0, to: 90, cyclesPerMinute: 60)
        try RawSessionWriter.write(
            RawSession(meta: meta, motion: motion), to: folder, gzip: false, version: max(version, 2))
        let encoder = JSONEncoder()
        func lines<T: Encodable>(_ items: [T]) throws -> Data {
            Data(try items.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined().utf8)
        }
        // 35 s in (uptime 135) the wall clock goes back 20 s; pause 30 s in, resume 40 s in.
        if version == 1 {
            try RawFormat.V1.encodeMeta(meta, clock: .init(unix: start, uptime: uptime0))
                .write(to: folder.appendingPathComponent(RawFormat.metaFileName))
            try lines([RawFormat.V1.ClockAnchor(unix: start + 15, uptime: uptime0 + 35)])
                .write(to: folder.appendingPathComponent(RawFormat.Stream.clock.fileName))
            try lines(motion.map { sample in
                RawFormat.MotionLine(
                    ts: uptime0 + sample.t, userAcceleration: sample.userAcceleration, gravity: sample.gravity,
                    rotationRate: sample.rotationRate, attitude: sample.attitude)
            }).write(to: folder.appendingPathComponent(RawFormat.Stream.motion.fileName))
        } else {
            try lines([RawFormat.ClockAnchor(unix: start + 15, mono: start + 35)])
                .write(to: folder.appendingPathComponent(RawFormat.Stream.clock.fileName))
        }
        try lines([
            RawFormat.EventLine(ts: start, type: .start), RawFormat.EventLine(ts: start + 30, type: .pause),
            RawFormat.EventLine(ts: start + 20, type: .resume), RawFormat.EventLine(ts: start + 70, type: .stop),
        ]).write(to: folder.appendingPathComponent(RawFormat.Stream.events.fileName))

        let session = try RawSessionReader.read(folder: folder)
        #expect(session.meta.version == version)
        #expect(session.pauseEventsOnMonotonicClock?.map(\.t) == [30, 40])
        #expect(session.motion.first?.monotonic == start)
        let detection = StrokeAnalysis.detect(session: session)
        // 30 strokes before the pause, none in it, 50 after.
        #expect(abs(detection.strokes.count - 80) <= 2)
        #expect(SessionStats(session: session).strokes.map { abs($0.count - 80) <= 2 } == true)
    }

    /// Finding 2: kayak's inferred second stroke inside a manual pause is not counted.
    @Test func kayakSecondStrokeInsideAPauseIsNotCounted() {
        let cycles = [
            StrokeDetector.Cycle(t: 8, period: nil, side: nil), StrokeDetector.Cycle(t: 10, period: 2, side: nil),
        ]
        let strokes = StrokeAnalysis.expand(cycles, strokesPerCycle: 2) { (10.5..<15).contains($0) }
        #expect(strokes.map(\.t) == [8, 9, 10])

        // End to end: a pause just after a cycle's peak.
        let samples = rotation(from: 0, to: 40, cyclesPerMinute: 30)
        let pause = 20.6..<26.0
        let events = [SessionEvent(t: pause.lowerBound, type: .pause), SessionEvent(t: pause.upperBound, type: .resume)]
        let detection = StrokeAnalysis.detect(motion: samples, sport: .kayak, events: events)
        #expect(!detection.strokes.isEmpty)
        #expect(detection.strokes.allSatisfy { !pause.contains($0.t) })
    }

    /// Finding 3: a stroke that peaked before a quick pause still counts when its lobe
    /// closes after the resume.
    @Test func quickPauseKeepsAStrokeThatPeakedBeforeIt() throws {
        let samples = rotation(from: 0, to: 20, cyclesPerMinute: 60)
        let plain = StrokeAnalysis.detect(motion: samples, sport: .sup)
        let peak = try #require(plain.cycles.first { (9..<10).contains($0.t) }?.t)
        let events = [
            SessionEvent(t: peak + 0.05, type: .pause), SessionEvent(t: peak + 0.2, type: .resume),
        ]
        let paused = StrokeAnalysis.detect(motion: samples, sport: .sup, events: events)
        #expect(paused.cycles.map(\.t) == plain.cycles.map(\.t))
        // The interval across the pause is not a period.
        #expect(paused.cycles.first { $0.t > peak }?.period == nil)
    }

    /// Finding 4: the principal axis is found when the strongest covariance column is
    /// orthogonal to it.
    @Test func principalAxisIsFoundWhateverTheColumnSizes() throws {
        let matrix: [[Double]] = [[1, 1, 0], [1, 1, 0], [0, 0, 1.6]]
        let axis = try #require(StrokeDetector.principalAxis(of: matrix))
        let half = 0.5.squareRoot()
        #expect(abs(abs(axis[0]) - half) < 1e-9 && abs(abs(axis[1]) - half) < 1e-9 && abs(axis[2]) < 1e-9)
        #expect(axis[0] * axis[1] > 0)
        // In the detector's 6-channel case too.
        var six = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for i in 0..<3 { for j in 0..<3 { six[i][j] = matrix[i][j] } }
        let axis6 = try #require(StrokeDetector.principalAxis(of: six))
        #expect(abs(abs(axis6[0]) - half) < 1e-9 && abs(axis6[2]) < 1e-9)
    }

    /// Finding 5: the restart threshold uses the real time between samples.
    @Test func restartUsesTheRealSampleGap() {
        func run(gapEnd: Double) -> Int {
            var detector = StrokeDetector(sport: .sup)
            let still = { (t: Double) in
                MotionSample(
                    t: t, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -9.8), rotationRate: .zero,
                    attitude: .identity)
            }
            for t in stride(from: 0.001, through: 10.001, by: 0.01) { detector.ingest(still(t)) }
            for t in stride(from: gapEnd, to: gapEnd + 2, by: 0.01) { detector.ingest(still(t)) }
            return detector.restarts
        }
        #expect(run(gapEnd: 10.239) == 1)  // 238 ms, four empty bins
        #expect(run(gapEnd: 10.151) == 0)  // 150 ms: interpolated
    }
}
