import Foundation
import WaterKit

/// A synthetic session for UI tests and screenshots: launch with `-demoSession` in a
/// Debug build and a recording uses this route instead of GPS, motion and Health, so it
/// needs no permissions and gives the same numbers every run. Release builds ignore it.
enum DemoFeed {
    static let launchArgument = "-demoSession"

    static var isEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
            false
        #endif
    }

    // One fix per real second, on the same clock as user events and metadata: a faster
    // simulated clock made saved recordings disagree with themselves (events and
    // `endedAt` behind the fixes).
    /// Constant speed of the synthetic boat, m/s.
    static let speed = 2.5
    /// Windsurfing's demo board is faster, so its distance categories fill within a test.
    static func speed(for sport: Sport?) -> Double {
        sport == .windsurfing ? 8 : speed
    }
    /// A fake origin in open water, like the anonymized fixtures (no real location).
    static let origin = (lat: 10.0, lon: -30.0)

    /// The fix at `ts` (unix time), heading east. Each fix is stamped with the real time it
    /// is made: a loop that runs late (a busy CI simulator) must not fall behind the
    /// session clock, or the engine treats its speed as stale.
    static func fix(at ts: Double, startUnix: Double, sport: Sport? = nil) -> RawFormat.GPSLine {
        let elapsed = max(0, ts - startUnix)
        let speed = speed(for: sport)
        let point = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: 90, distance: speed * elapsed)
        return RawFormat.GPSLine(ts: ts, lat: point.lat, lon: point.lon, hacc: 5, spd: speed, crs: 90)
    }

    /// Synthetic wrist motion for paddling, at 25 Hz: a steady 64 SPM for kayak (two
    /// strokes per wrist cycle) and 48 SPM for canoe and SUP, repeating every 10 minutes.
    static let motionRate = 25.0
    static let motionLoop = 600.0

    static func strokeRate(for sport: Sport) -> Double { sport == .kayak ? 64 : 48 }

    private static let paddleMotion: [Sport: [MotionSample]] = Dictionary(
        uniqueKeysWithValues: [Sport.kayak, .canoe, .sup].map { sport in
            var simulator = PaddleMotionSimulator(
                sport: sport, segments: [.init(duration: motionLoop, strokeRate: strokeRate(for: sport))])
            simulator.sampleRate = motionRate
            simulator.seed = 2
            return (sport, simulator.generate().samples)
        })

    /// Motion lines for session times in (`start`, `end`], with uptime timestamps.
    static func motion(sport: Sport, from start: Double, to end: Double, startUptime: Double) -> [RawFormat.MotionLine] {
        guard let samples = paddleMotion[sport], !samples.isEmpty, end > start else { return [] }
        let first = Int((start * motionRate).rounded(.down)) + 1
        let last = Int((end * motionRate).rounded(.down))
        guard last >= first else { return [] }
        return (first...last).map { index in
            let sample = samples[index % samples.count]
            return RawFormat.MotionLine(
                ts: startUptime + Double(index) / motionRate, userAcceleration: sample.userAcceleration,
                gravity: sample.gravity, rotationRate: sample.rotationRate, attitude: sample.attitude)
        }
    }

    static func heartRate(at ts: Double, startUnix: Double) -> RawFormat.HRLine {
        RawFormat.HRLine(ts: ts, bpm: 120 + Double(Int(ts - startUnix) % 10))
    }
}
