import Foundation
import WaterKit

/// The provider can only receive a cell created by WaterKit's rounding initializer.
@MainActor
protocol PhoneWeatherProviding {
    func current(at cell: WeatherGridCell) async throws -> WeatherNow
    func hourlyWind(at cell: WeatherGridCell, during interval: DateInterval) async throws -> [WeatherWindHour]
}

struct WeatherWindHour: Codable, Sendable {
    let date: Date
    let fromDegrees: Double
    let speed: Double
}

@MainActor
final class PhoneWeather {
    static let shared: PhoneWeather = {
        #if DEBUG
            if DemoWeatherProvider.isEnabled {
                return PhoneWeather(provider: DemoWeatherProvider(), defaults: nil)
            }
        #endif
        return PhoneWeather(provider: AppleWeatherProvider(), defaults: .standard)
    }()

    enum Failure: Error { case unavailable }

    struct Conditions: Codable {
        let weather: WeatherNow
        let fetchedAt: Date
    }

    private struct HourKey: Hashable {
        let cell: WeatherGridCell
        let hour: Date

        var diskKey: String {
            "appleWeather.wind.\(cell.latitude),\(cell.longitude).\(Int(hour.timeIntervalSince1970))"
        }
    }

    private struct WindEntry: Codable {
        let hour: WeatherWindHour?
        let fetchedAt: Date
    }

    private let provider: any PhoneWeatherProviding
    private let defaults: UserDefaults?
    private var conditions: [HourKey: Conditions] = [:]
    private var wind: [HourKey: WindEntry] = [:]
    private var pendingWind: [HourKey: Task<Void, Error>] = [:]

    init(provider: any PhoneWeatherProviding, defaults: UserDefaults?) {
        self.provider = provider
        self.defaults = defaults
    }

    func current(at cell: WeatherGridCell, force: Bool = false, now: Date = .now) async throws -> Conditions {
        let key = HourKey(cell: cell, hour: Self.hour(containing: now))
        if !force, let cached = conditions[key], now.timeIntervalSince(cached.fetchedAt) < LocalWeather.refreshAfter {
            return cached
        }
        let answer = Conditions(weather: try await provider.current(at: cell), fetchedAt: now)
        conditions = conditions.filter { $0.key.hour == key.hour }
        conditions[key] = answer
        return answer
    }

    static let hourLength: TimeInterval = 3_600
    /// WeatherKit's documented historical lower limit and maximum span per request.
    private static let firstHistoricalHour = Date(timeIntervalSince1970: 1_627_776_000)  // 2021-08-01 UTC
    private static let maximumHours = 240

    static func hour(containing date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / hourLength).rounded(.down) * hourLength)
    }

    private func hourKeys(for query: SessionWeatherWind.Query, now: Date) -> [HourKey] {
        let limit = Self.hour(containing: now).addingTimeInterval(Double(Self.maximumHours) * Self.hourLength)
        guard query.lastHour >= Self.firstHistoricalHour, query.firstHour < limit else { return [] }
        let first = max(Self.firstHistoricalHour, query.firstHour.addingTimeInterval(-Self.hourLength))
        let end = min(limit, query.lastHour.addingTimeInterval(2 * Self.hourLength))
        return stride(from: first.timeIntervalSince1970, to: end.timeIntervalSince1970, by: Self.hourLength).map {
            HourKey(cell: query.cell, hour: Date(timeIntervalSince1970: $0))
        }
    }

    private func stored(_ key: HourKey) -> WindEntry? {
        wind[key]
            ?? defaults?.data(forKey: key.diskKey).flatMap {
                try? JSONDecoder().decode(WindEntry.self, from: $0)
            }
    }

    private func fresh(_ key: HourKey, now: Date) -> WindEntry? {
        guard let entry = stored(key) else { return nil }
        // A new comparison can refresh a forecast after the fetch hour passes.
        let historical = entry.hour != nil && key.hour.addingTimeInterval(Self.hourLength) <= entry.fetchedAt
        return historical || Self.hour(containing: entry.fetchedAt) == Self.hour(containing: now) ? entry : nil
    }

    func cachedWind(for query: SessionWeatherWind.Query, now: Date = .now) -> SessionWeatherWind? {
        let keys = hourKeys(for: query, now: now)
        // Reopening a comparison can reuse fetched forecasts as well as observations,
        // even if a recently finished session included a forecast hour.
        let entries = keys.compactMap { stored($0) }
        guard entries.count == keys.count else { return nil }
        return SessionWeatherWind.average(entries.compactMap(\.hour))
    }

    func wind(for query: SessionWeatherWind.Query, now: Date = .now) async throws -> SessionWeatherWind {
        let keys = hourKeys(for: query, now: now)
        var index = keys.startIndex
        while index < keys.endIndex {
            let key = keys[index]
            if let pending = pendingWind[key] {
                try await pending.value
                index += 1
            } else if fresh(key, now: now) != nil {
                index += 1
            } else {
                // Request adjacent misses together, skipping hours already cached or in flight.
                let start = index
                repeat {
                    index += 1
                } while index < keys.endIndex && index - start < Self.maximumHours
                    && fresh(keys[index], now: now) == nil && pendingWind[keys[index]] == nil
                try await requestWind(keys[start..<index], now: now)
            }
        }
        guard let answer = cachedWind(for: query, now: now) else {
            // An unanswered comparison can be retried immediately.
            for key in keys where wind[key]?.hour == nil { wind[key] = nil }
            throw Failure.unavailable
        }
        // Keep the coverage of a successful comparison, including gaps in the forecast.
        // On a later comparison, missing hours are eligible to be fetched again.
        for key in keys {
            if let entry = wind[key], entry.hour == nil { save(entry, for: key) }
        }
        return answer
    }

    private func requestWind(_ keys: ArraySlice<HourKey>, now: Date) async throws {
        guard let first = keys.first, let last = keys.last else { return }
        let interval = DateInterval(start: first.hour, end: last.hour.addingTimeInterval(Self.hourLength))
        let task = Task {
            defer {
                for key in keys { pendingWind[key] = nil }
            }
            let samples = try await provider.hourlyWind(at: first.cell, during: interval)
            let byHour = Dictionary(
                samples.map { (Self.hour(containing: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
            for key in keys {
                let entry = WindEntry(hour: byHour[key.hour], fetchedAt: now)
                wind[key] = entry
                if entry.hour != nil { save(entry, for: key) }
            }
        }
        for key in keys { pendingWind[key] = task }
        try await task.value
    }

    private func save(_ entry: WindEntry, for key: HourKey) {
        guard let defaults, let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: key.diskKey)
    }
}
