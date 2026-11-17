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
    /// A fake origin in open water, like the anonymized fixtures (no real location).
    static let origin = (lat: 10.0, lon: -30.0)

    /// The fix at `ts` (unix time), heading east. Each fix is stamped with the real time it
    /// is made: a loop that runs late (a busy CI simulator) must not fall behind the
    /// session clock, or the engine treats its speed as stale.
    static func fix(at ts: Double, startUnix: Double) -> RawFormat.GPSLine {
        let elapsed = max(0, ts - startUnix)
        let point = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: 90, distance: speed * elapsed)
        return RawFormat.GPSLine(ts: ts, lat: point.lat, lon: point.lon, hacc: 5, spd: speed, crs: 90)
    }

    static func heartRate(at ts: Double, startUnix: Double) -> RawFormat.HRLine {
        RawFormat.HRLine(ts: ts, bpm: 120 + Double(Int(ts - startUnix) % 10))
    }
}
