import Foundation
import WaterKit

/// Modelled wind shown beside the track estimate and used as its directional prior.
struct SessionWeatherWind: Equatable, Sendable {
    /// Direction the wind blows from, degrees true.
    let fromDegrees: Double
    /// Mean sustained wind speed over the sampled hours, m/s.
    let speed: Double
    let hours: Int

    struct Query: Hashable, Sendable {
        let cell: WeatherGridCell
        let firstHour: Date
        let lastHour: Date
    }

    @MainActor
    static func query(track: Track, duration: Double) -> Query? {
        let fixes = track.gps.filter { (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }
        guard !fixes.isEmpty, duration.isFinite else { return nil }
        let latitude = fixes.map(\.latitude).reduce(0, +) / Double(fixes.count)
        // Longitude as a circular mean, so sessions crossing the antimeridian stay there.
        let radians = fixes.map { $0.longitude * .pi / 180 }
        let longitude = atan2(radians.map(sin).reduce(0, +), radians.map(cos).reduce(0, +)) * 180 / .pi
        guard let cell = WeatherGridCell(latitude: latitude, longitude: longitude) else { return nil }
        return Query(
            cell: cell, firstHour: PhoneWeather.hour(containing: track.startedAt),
            lastHour: PhoneWeather.hour(containing: track.startedAt.addingTimeInterval(max(0, duration))))
    }

    /// Speed-weighted circular mean direction and arithmetic mean speed of the sampled hours.
    static func average(_ samples: [WeatherWindHour]) -> Self? {
        var (x, y, speedSum, count) = (0.0, 0.0, 0.0, 0)
        for sample in samples {
            guard sample.speed.isFinite, sample.speed >= 0, sample.fromDegrees.isFinite else { continue }
            let weight = max(sample.speed, 0.1)
            let angle = sample.fromDegrees * .pi / 180
            x += weight * cos(angle)
            y += weight * sin(angle)
            speedSum += sample.speed
            count += 1
        }
        guard count > 0, x != 0 || y != 0 else { return nil }
        return Self(
            fromDegrees: (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360),
            speed: speedSum / Double(count), hours: count)
    }
}

/// Forecast results and fetch state per query, for session detail. A fetch that
/// completes after the selection changed lands under its own query, so it never shows
/// for (or overwrites) the selection now on screen.
struct SessionWeatherForecasts: Equatable {
    enum State: Equatable { case idle, loading, failed }

    private var results: [SessionWeatherWind.Query: SessionWeatherWind] = [:]
    private var loading: Set<SessionWeatherWind.Query> = []
    private var failed: Set<SessionWeatherWind.Query> = []

    func wind(for query: SessionWeatherWind.Query?) -> SessionWeatherWind? {
        query.flatMap { results[$0] }
    }

    func state(for query: SessionWeatherWind.Query?) -> State {
        guard let query else { return .idle }
        if loading.contains(query) { return .loading }
        return failed.contains(query) ? .failed : .idle
    }

    mutating func start(_ query: SessionWeatherWind.Query) {
        loading.insert(query)
        failed.remove(query)
    }

    mutating func complete(_ query: SessionWeatherWind.Query, with wind: SessionWeatherWind) {
        loading.remove(query)
        failed.remove(query)
        results[query] = wind
    }

    mutating func fail(_ query: SessionWeatherWind.Query) {
        loading.remove(query)
        failed.insert(query)
    }
}
