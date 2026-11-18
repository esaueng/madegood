import Foundation
import WaterKit

/// A small, north-up trace in normalized coordinates for an offline History thumbnail.
struct HistoryRoute: Hashable, Sendable {
    struct Point: Hashable, Sendable {
        var x: Double
        var y: Double
    }

    let points: [Point]

    init?(fixes: [GPSFix]) {
        let count = min(fixes.count, 64)
        guard count > 1 else { return nil }

        var projected: [Point] = []
        var origin: GPSFix?
        var previousLongitude: Double?
        var longitudeOffset = 0.0
        var longitudeScale = 1.0
        for index in 0..<count {
            // Sample evenly, keeping both ends even for multi-hour recordings.
            let fix = fixes[index * (fixes.count - 1) / (count - 1)]
            guard (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude) else { continue }
            if let previousLongitude {
                // Use the short step across the date line.
                let delta = fix.longitude - previousLongitude
                longitudeOffset += delta - 360 * (delta / 360).rounded()
            } else {
                origin = fix
                longitudeScale = cos(fix.latitude * .pi / 180)
            }
            previousLongitude = fix.longitude
            if let origin {
                projected.append(Point(x: longitudeOffset * longitudeScale, y: origin.latitude - fix.latitude))
            }
        }

        let xs = projected.map(\.x)
        let ys = projected.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let span = max(maxX - minX, maxY - minY)
        guard span > 1e-9 else { return nil }
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        points = projected.map { Point(x: ($0.x - midX) / span, y: ($0.y - midY) / span) }
    }
}
