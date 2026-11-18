import Foundation
import WaterKit

/// A small, north-up trace in normalized coordinates for an offline History thumbnail.
struct HistoryRoute: Hashable, Sendable {
    struct Point: Hashable, Sendable {
        var x: Double
        var y: Double
    }

    let spans: [[Point]]

    init?(fixSpans: [ArraySlice<GPSFix>]) {
        let visibleSpans = fixSpans.filter { !$0.isEmpty }
        let pointsPerSpan = max(2, 64 / max(1, visibleSpans.count))

        var projected: [[Point]] = []
        var origin: GPSFix?
        var previousLongitude: Double?
        var longitudeOffset = 0.0
        var longitudeScale = 1.0
        for fixes in visibleSpans {
            var span: [Point] = []
            let count = min(fixes.count, pointsPerSpan)
            for index in 0..<count {
                // Sample evenly within a span, keeping both ends on long recordings.
                let fix = fixes[fixes.startIndex + index * (fixes.count - 1) / max(1, count - 1)]
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
                    span.append(Point(x: longitudeOffset * longitudeScale, y: origin.latitude - fix.latitude))
                }
            }
            if !span.isEmpty { projected.append(span) }
        }

        let xs = projected.flatMap { $0.map(\.x) }
        let ys = projected.flatMap { $0.map(\.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let span = max(maxX - minX, maxY - minY)
        guard span > 1e-9 else { return nil }
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        spans = projected.map { $0.map { Point(x: ($0.x - midX) / span, y: ($0.y - midY) / span) } }
    }
}
