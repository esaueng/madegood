import Foundation
import WaterKit

/// Modelled 10 m wind from Open-Meteo for a finished session, used as a prior for the
/// track's own wind estimate and shown for comparison (docs/metrics.md, "Open-Meteo").
/// iPhone only, and only when the user asks: the watch never calls the network.
///
/// What is sent: the session's mean position rounded to 0.5° (about 50 km; the weather
/// models' grids are coarse anyway), its UTC start and end dates (whole days), and the
/// variables asked for. No session ID, account, device or exact time. Open-Meteo needs
/// no API key.
struct OpenMeteoWind: Codable, Equatable, Sendable {
    /// Direction the wind blows from, degrees true (Open-Meteo's meteorological convention).
    var fromDegrees: Double
    /// Mean 10 m wind speed over the session's hours, m/s.
    var speed: Double
    /// Hourly values that covered the session.
    var hours: Int
}

enum OpenMeteo {
    /// Coordinates are rounded to this many degrees before they leave the phone.
    static let coordinateStep = 0.5
    static let variables = "wind_speed_10m,wind_direction_10m"
    /// Sessions that ended longer ago than this use the historical archive; newer ones
    /// the forecast API, which also serves the recent past (the archive lags by days).
    static let archiveAfter: TimeInterval = 7 * 86_400

    enum Failure: Error, Equatable {
        case noPosition
        case badResponse
        case noData
    }

    /// The rounded position for a session: the mean of its fixes. Nil without fixes.
    static func roundedPosition(_ gps: [GPSFix]) -> (latitude: Double, longitude: Double)? {
        let fixes = gps.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        guard !fixes.isEmpty else { return nil }
        let latitude = fixes.map(\.latitude).reduce(0, +) / Double(fixes.count)
        // Longitude as a circular mean, so a session across the antimeridian stays put.
        let radians = fixes.map { $0.longitude * .pi / 180 }
        let longitude = atan2(radians.map(sin).reduce(0, +), radians.map(cos).reduce(0, +)) * 180 / .pi
        return (round(latitude), round(longitude))
    }

    static func round(_ degrees: Double) -> Double {
        // Whole multiples of the step: exact in binary for 0.5, so it prints cleanly.
        (degrees / coordinateStep).rounded() * coordinateStep
    }

    /// What one fetch asks for, and the hours it averages. It is also the cache key, so a
    /// trimmed or edited session in another area or on another day asks again.
    struct Query: Hashable, Sendable {
        /// Rounded degrees, as sent.
        var latitude: Double
        var longitude: Double
        /// UTC dates, "yyyy-MM-dd", as sent.
        var startDate: String
        var endDate: String
        /// The session's whole UTC hours (unix s), used on the phone only to pick hours.
        var firstHour: Double
        var lastHour: Double

        var cacheKey: String {
            let position = String(format: "%.1f,%.1f", latitude, longitude)
            return
                "openMeteoWind.v2.\(position).\(startDate).\(endDate).\(Int(firstHour)).\(Int(lastHour)).\(variables)"
        }
    }

    /// The query for a session's track (the displayed selection, after trimming).
    static func query(track: Track, duration: Double) -> Query? {
        guard let position = roundedPosition(track.gps) else { return nil }
        let start = track.startedAt
        let end = start.addingTimeInterval(max(0, duration))
        let day = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month().day()
        func hour(_ date: Date) -> Double { (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600 }
        return Query(
            latitude: position.latitude, longitude: position.longitude, startDate: start.formatted(day),
            endDate: end.formatted(day), firstHour: hour(start), lastHour: hour(end))
    }

    /// The request for a query. Sessions that ended over `archiveAfter` before `now` use
    /// the archive.
    static func request(_ query: Query, now: Date) -> URLRequest {
        let archive = now.timeIntervalSince1970 - (query.lastHour + 3_600) > archiveAfter
        var components = URLComponents(
            string: archive ? "https://archive-api.open-meteo.com/v1/archive" : "https://api.open-meteo.com/v1/forecast"
        )!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", query.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", query.longitude)),
            URLQueryItem(name: "hourly", value: variables),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "start_date", value: query.startDate),
            URLQueryItem(name: "end_date", value: query.endDate),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        return request
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            var time: [Double]
            var wind_speed_10m: [Double?]
            var wind_direction_10m: [Double?]
        }
        var hourly: Hourly
    }

    /// The speed-weighted circular mean direction and mean speed of the hourly values
    /// from the hour before the query's first hour to the hour after its last.
    static func parse(_ data: Data, query: Query) throws -> OpenMeteoWind {
        guard let hourly = try? JSONDecoder().decode(Response.self, from: data).hourly else {
            throw Failure.badResponse
        }
        let window = (query.firstHour - 3_600)...(query.lastHour + 3_600)
        var (x, y, speedSum, count) = (0.0, 0.0, 0.0, 0)
        for (index, time) in hourly.time.enumerated() where window.contains(time) {
            guard index < hourly.wind_speed_10m.count, index < hourly.wind_direction_10m.count,
                let speed = hourly.wind_speed_10m[index], let direction = hourly.wind_direction_10m[index],
                speed.isFinite, speed >= 0, direction.isFinite
            else { continue }
            // Weight by speed so a calm hour's direction counts for little.
            let weight = max(speed, 0.1)
            x += weight * cos(direction * .pi / 180)
            y += weight * sin(direction * .pi / 180)
            speedSum += speed
            count += 1
        }
        guard count > 0, x != 0 || y != 0 else { throw Failure.noData }
        var direction = atan2(y, x) * 180 / .pi
        if direction < 0 { direction += 360 }
        return OpenMeteoWind(fromDegrees: direction, speed: speedSum / Double(count), hours: count)
    }

    /// Fetches the wind for a session. Throws when offline or on any bad answer; callers
    /// show the failure and keep the track's own estimate.
    static func fetch(_ query: Query, now: Date = .now) async throws -> OpenMeteoWind {
        let request = request(query, now: now)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return try parse(data, query: query)
    }
}

/// Fetched Open-Meteo results, kept on this phone per query so the comparison and the
/// prior survive reopening without asking the network again. A different selection
/// (trimmed to another area or day) is a different query and is not answered from here.
enum OpenMeteoCache {
    static func wind(for query: OpenMeteo.Query, defaults: UserDefaults = .standard) -> OpenMeteoWind? {
        defaults.data(forKey: query.cacheKey).flatMap { try? JSONDecoder().decode(OpenMeteoWind.self, from: $0) }
    }

    static func store(_ wind: OpenMeteoWind, for query: OpenMeteo.Query, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(wind) { defaults.set(data, forKey: query.cacheKey) }
    }
}
