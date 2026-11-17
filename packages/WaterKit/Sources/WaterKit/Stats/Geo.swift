import Foundation

/// Spherical-Earth geodesy helpers. Accurate to about 0.5 % against WGS 84, which is
/// well inside GPS noise for the distances a session covers.
public enum Geo {
    /// Mean Earth radius, m (IUGG).
    public static let earthRadius = 6_371_008.8

    /// Great-circle distance between two points, m.
    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Initial great-circle bearing from point 1 to point 2, degrees true (0–360).
    public static func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point `distance` m from a start point along `bearing` degrees true.
    public static func destination(
        lat: Double, lon: Double, bearing: Double, distance: Double
    ) -> (lat: Double, lon: Double) {
        let delta = distance / earthRadius
        let theta = bearing * .pi / 180
        let phi1 = lat * .pi / 180
        let lambda1 = lon * .pi / 180
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
        var lon2 = lambda2 * 180 / .pi
        lon2 = (lon2 + 540).truncatingRemainder(dividingBy: 360) - 180
        return (phi2 * 180 / .pi, lon2)
    }
}
