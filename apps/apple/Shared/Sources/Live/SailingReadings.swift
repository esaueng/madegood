import Foundation
import WaterKit

/// Live sailing values for the sport page and the watch mirror. Units are SI (m/s,
/// degrees true); see docs/metrics.md, "Sailing wind and VMG".
struct SailingReadings: Codable, Equatable, Sendable {
    /// The track's wind estimate, degrees true; nil until both legs have enough time.
    var windFrom: Double?
    var windConfidence: Double?
    /// Velocity made good toward the wind, m/s; negative downwind.
    var vmg: Double?
    /// Wind relative to the bow, degrees; positive over the starboard side.
    var trueWindAngle: Double?
    var tacks: Int
    var gybes: Int

    init(_ live: LiveSailing) {
        windFrom = live.wind?.fromDegrees
        windConfidence = live.wind?.confidence
        vmg = live.vmg
        trueWindAngle = live.trueWindAngle
        tacks = live.tacks
        gybes = live.gybes
    }

    var maneuverCount: Int { tacks + gybes }
}

extension LiveDisplay {
    /// VMG as a positive speed; `vmgCaption` says which way.
    func vmg(_ metresPerSecond: Double?) -> String {
        speed(metresPerSecond.map(abs))
    }

    static func vmgCaption(_ metresPerSecond: Double?) -> String {
        guard let metresPerSecond else { return "VMG" }
        return metresPerSecond >= 0 ? "VMG upwind" : "VMG downwind"
    }

    /// "42° stbd" / "135° port": the true wind angle and the tack it puts the boat on.
    static func windAngle(_ degrees: Double?) -> String {
        guard let degrees else { return "–" }
        let side = degrees >= 0 ? "stbd" : "port"
        return "\(Int(abs(degrees).rounded()))° \(side)"
    }

    /// "Wind 030°" with "est." while the estimate only assumes the legs were upwind.
    static func windFrom(_ degrees: Double?) -> String {
        guard let degrees else { return "–" }
        let whole = Int(degrees.rounded()) % 360
        return whole < 10 ? "00\(whole)°" : whole < 100 ? "0\(whole)°" : "\(whole)°"
    }
}
