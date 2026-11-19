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
        if sport == .sailing, tacksEnabled { return beatFix(at: ts, elapsed: elapsed) }
        let speed = speed(for: sport)
        let point = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: 90, distance: speed * elapsed)
        return RawFormat.GPSLine(ts: ts, lat: point.lat, lon: point.lon, hacc: 5, spd: speed, crs: 90)
    }

    /// With `-demoTacks`, sailing beats upwind instead: wind from north, 25 s on each tack
    /// (315° and 045°) joined by 6 s tacks that dip to half speed. The wind estimate
    /// appears about a minute in (docs/metrics.md, "Sailing wind and VMG").
    static let tacksArgument = "-demoTacks"
    static let tackLeg = 25.0
    static let tackTurn = 6.0

    static var tacksEnabled: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(tacksArgument)
    }

    /// Course (degrees true) and Doppler speed (m/s) at `elapsed` on the demo beat.
    static func beat(at elapsed: Double) -> (course: Double, speed: Double) {
        let period = 2 * (tackLeg + tackTurn)
        let phase = elapsed.truncatingRemainder(dividingBy: period)
        let half = phase < tackLeg + tackTurn ? 0.0 : 1.0
        let into = phase - half * (tackLeg + tackTurn)
        let from = half == 0 ? 315.0 : 405.0
        let to = half == 0 ? 405.0 : 315.0
        guard into >= tackLeg else { return (from.truncatingRemainder(dividingBy: 360), speed) }
        let fraction = (into - tackLeg) / tackTurn
        let course = (from + (to - from) * fraction).truncatingRemainder(dividingBy: 360)
        return (course, speed * (1 - 0.5 * (1 - abs(fraction * 2 - 1))))
    }

    /// Integrates the beat in 0.25 s steps (on a flat local plane, fine over a demo's
    /// few kilometres), using whole periods so a long session stays cheap.
    private static func beatOffset(at elapsed: Double) -> (north: Double, east: Double) {
        func integrate(_ duration: Double) -> (north: Double, east: Double) {
            var (north, east) = (0.0, 0.0)
            var t = 0.0
            while t < duration {
                let dt = min(0.25, duration - t)
                let (course, v) = beat(at: t + dt / 2)
                north += v * dt * cos(course * .pi / 180)
                east += v * dt * sin(course * .pi / 180)
                t += dt
            }
            return (north, east)
        }
        let period = 2 * (tackLeg + tackTurn)
        let whole = (elapsed / period).rounded(.down)
        let perPeriod = integrate(period)
        let rest = integrate(elapsed - whole * period)
        return (whole * perPeriod.north + rest.north, whole * perPeriod.east + rest.east)
    }

    private static func beatFix(at ts: Double, elapsed: Double) -> RawFormat.GPSLine {
        let (course, v) = beat(at: elapsed)
        let offset = beatOffset(at: elapsed)
        let distance = (offset.north * offset.north + offset.east * offset.east).squareRoot()
        let bearing = atan2(offset.east, offset.north) * 180 / .pi
        let point = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: bearing, distance: distance)
        return RawFormat.GPSLine(ts: ts, lat: point.lat, lon: point.lon, hacc: 5, spd: v, crs: course)
    }

    // MARK: Start line

    /// With `-demoOCS`, the demo boat is over the start line at the gun.
    static let ocsArgument = "-demoOCS"
    /// With `-demoNoPingFix`, start line pings find no fix and fail.
    static let noPingFixArgument = "-demoNoPingFix"

    /// The demo start line: 200 m long, pin → boat 84° (6° off square to the demo wind, so
    /// the boat end is favoured), centred 30 m south of the origin. The recorded route
    /// starts at the origin, on the course side.
    static let startLineBearing = 84.0
    static var startLineCentre: (lat: Double, lon: Double) {
        Geo.destination(lat: origin.lat, lon: origin.lon, bearing: 180, distance: 30)
    }

    /// Wind axis during the demo countdown, degrees true (from the north).
    static let prestartWind = 0.0

    static func startLineEnd(_ end: StartLineEnd) -> (lat: Double, lon: Double) {
        let centre = startLineCentre
        return Geo.destination(
            lat: centre.lat, lon: centre.lon, bearing: startLineBearing + (end == .pin ? 180 : 0), distance: 100)
    }

    /// The boat during the countdown: sailing square at the line, reaching it 3 s after
    /// the gun (5 s before with `-demoOCS`), at the demo speed.
    static func prestartFix(at ts: Double, remaining: Double) -> GPSFix {
        let late = ProcessInfo.processInfo.arguments.contains(ocsArgument) ? -5.0 : 3.0
        let behind = speed * (remaining + late)
        let toLine = startLineBearing - 90
        let centre = startLineCentre
        let point = Geo.destination(
            lat: centre.lat, lon: centre.lon, bearing: behind >= 0 ? toLine + 180 : toLine, distance: abs(behind))
        return GPSFix(
            t: ts, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: speed,
            course: (toLine + 360).truncatingRemainder(dividingBy: 360))
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
