import Foundation
import WaterKit

/// Live sailing values for the sport page and the watch mirror. Units are SI (m/s,
/// degrees true); see docs/metrics.md, "Sailing wind and VMG".
///
/// Until something resolves which side of its axis the wind is on (live there is no
/// prior, so never), the text here names only the axis: no upwind/downwind, no tack or
/// gybe, no starboard/port, and one combined maneuver count.
struct SailingReadings: Codable, Equatable, Sendable {
    /// The track's wind estimate, degrees true; nil until both legs have enough time.
    /// Only its axis is known unless `windResolved`.
    var windFrom: Double?
    var windConfidence: Double?
    /// Spread of the legs' courses, degrees. Optional for older watch apps.
    var windAxisUncertainty: Double?
    /// Whether the wind's side is known. Optional for older watch apps (nil: not known).
    var windResolved: Bool?
    /// Velocity made good toward the wind, m/s; negative downwind.
    var vmg: Double?
    /// Wind relative to the bow, degrees; positive over the starboard side.
    var trueWindAngle: Double?
    var tacks: Int
    var gybes: Int

    init(_ live: LiveSailing) {
        windFrom = live.wind?.fromDegrees
        windConfidence = live.wind?.axisConfidence
        windAxisUncertainty = live.wind?.axisUncertainty
        windResolved = live.wind?.resolvedByPrior ?? false
        vmg = live.vmg
        trueWindAngle = live.trueWindAngle
        tacks = live.tacks
        gybes = live.gybes
    }

    var maneuverCount: Int { tacks + gybes }
    var resolved: Bool { windFrom != nil && windResolved == true }

    /// "VMG upwind" / "VMG downwind" with a known side, else "VMG".
    var vmgTitle: String {
        guard resolved, let vmg else { return "VMG" }
        return vmg >= 0 ? "VMG upwind" : "VMG downwind"
    }

    var windTitle: String { resolved ? "Wind from" : "Wind axis" }

    /// "030°" with a known side, else both ends of the axis: "030°/210°".
    var windText: String {
        guard let windFrom else { return "–" }
        guard resolved else {
            return "\(LiveDisplay.windFrom(windFrom))/\(LiveDisplay.windFrom(windFrom + 180))"
        }
        return LiveDisplay.windFrom(windFrom)
    }

    var angleTitle: String { resolved ? "Wind angle" : "Off axis" }

    /// "42° stbd" with a known side, else the angle to the axis: "42°".
    var angleText: String {
        guard let trueWindAngle else { return "–" }
        guard resolved else {
            let off = min(abs(trueWindAngle), 180 - abs(trueWindAngle))
            return "\(Int(off.rounded()))°"
        }
        return LiveDisplay.windAngle(trueWindAngle)
    }

    /// Tacks and gybes apart only with a known side; otherwise one total.
    var maneuverRows: [(id: String, title: String, count: Int)] {
        resolved
            ? [("tacks", "Tacks", tacks), ("gybes", "Gybes", gybes)]
            : [("maneuvers", "Tacks/gybes", maneuverCount)]
    }
}

extension LiveDisplay {
    /// VMG as a positive speed; `SailingReadings.vmgTitle` says which way when known.
    func vmg(_ metresPerSecond: Double?) -> String {
        speed(metresPerSecond.map(abs))
    }

    /// "42° stbd" / "135° port": the true wind angle and the tack it puts the boat on.
    static func windAngle(_ degrees: Double?) -> String {
        guard let degrees else { return "–" }
        let side = degrees >= 0 ? "stbd" : "port"
        return "\(Int(abs(degrees).rounded()))° \(side)"
    }

    /// Three-digit degrees true: "030°".
    static func windFrom(_ degrees: Double) -> String {
        let whole = (Int(degrees.rounded()) % 360 + 360) % 360
        return whole < 10 ? "00\(whole)°" : whole < 100 ? "0\(whole)°" : "\(whole)°"
    }
}
