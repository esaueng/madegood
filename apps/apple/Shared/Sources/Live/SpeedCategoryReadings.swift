import Foundation
import WaterKit

/// The windsurf speed categories as plain values, for live screens and the watch mirror.
/// Units are SI (m/s); see docs/metrics.md, "Windsurf speed categories".
struct SpeedCategoryReadings: Codable, Equatable, Sendable {
    var peak2s: Double?
    var best10s: Double?
    var best5x10s: Double?
    var best100m: Double?
    var best500m: Double?
    var nauticalMile: Double?
    var hour: Double?
    var alpha500: Double?

    init(_ categories: SpeedCategories) {
        peak2s = categories.peak2s?.speed
        best10s = categories.best10s?.speed
        best5x10s = categories.best5x10s
        best100m = categories.best100m?.speed
        best500m = categories.best500m?.speed
        nauticalMile = categories.nauticalMile?.speed
        hour = categories.hour?.speed
        alpha500 = categories.alpha500?.speed
    }

    /// One category, in display order.
    struct Row: Identifiable {
        /// Accessibility identifier suffix, e.g. "speed.500m".
        let id: String
        let title: String
        /// For the watch's narrow columns.
        let shortTitle: String
        let value: Double?
    }

    var rows: [Row] {
        [
            Row(id: "speed.2s", title: "2 s", shortTitle: "2 s", value: peak2s),
            Row(id: "speed.10s", title: "10 s", shortTitle: "10 s", value: best10s),
            Row(id: "speed.5x10s", title: "5 × 10 s", shortTitle: "5×10 s", value: best5x10s),
            Row(id: "speed.100m", title: "100 m", shortTitle: "100 m", value: best100m),
            Row(id: "speed.500m", title: "500 m", shortTitle: "500 m", value: best500m),
            Row(id: "speed.nm", title: "Nautical mile", shortTitle: "NM", value: nauticalMile),
            Row(id: "speed.1h", title: "1 hour", shortTitle: "1 h", value: hour),
            Row(id: "speed.alpha500", title: "Alpha 500", shortTitle: "α 500", value: alpha500),
        ]
    }
}
