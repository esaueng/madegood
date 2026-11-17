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

    /// The fix `second` simulated seconds after the start, heading east.
    static func fix(second: Int, startUnix: Double) -> RawFormat.GPSLine {
        let point = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: 90, distance: speed * Double(second))
        return RawFormat.GPSLine(
            ts: startUnix + Double(second), lat: point.lat, lon: point.lon, hacc: 5, spd: speed, crs: 90)
    }

    static func heartRate(second: Int, startUnix: Double) -> RawFormat.HRLine {
        RawFormat.HRLine(ts: startUnix + Double(second), bpm: 120 + Double(second % 10))
    }
}
