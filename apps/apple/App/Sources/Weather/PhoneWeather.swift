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
                return PhoneWeather(provider: DemoWeatherProvider())
            }
        #endif
        return PhoneWeather(provider: AppleWeatherProvider(), legacyDefaults: .standard, disk: .shared)
    }()

    enum Failure: Error { case unavailable }

    // Short-lived performance caches for repeated views and overlapping comparisons.
    // Age is measured from fetch time, regardless of the observation's date or cache reads.
    nonisolated static let conditionsLifetime: TimeInterval = 15 * 60
    nonisolated static let historicalWindLifetime: TimeInterval = 24 * 3_600
    nonisolated static let forecastWindLifetime: TimeInterval = 3_600
    static let windLimit = 512  // approximately two full WeatherKit request batches
    private static let conditionsLimit = 8

    struct Conditions: Codable {
        let weather: WeatherNow
        let fetchedAt: Date

        var expiresAt: Date { fetchedAt + PhoneWeather.conditionsLifetime }

        func isFresh(at now: Date) -> Bool { fetchedAt <= now && now < expiresAt }

        static func load(from disk: WeatherDiskCache?, now: Date) -> Self? {
            guard let entry = disk?.read(Self.self, for: .conditions) else { return nil }
            guard entry.isFresh(at: now) else {
                disk?.remove(.conditions)
                return nil
            }
            return entry
        }
    }

    private struct HourKey: Hashable {
        let cell: WeatherGridCell
        let hour: Date

        var cacheKey: String {
            "appleWeather.wind.\(cell.latitude),\(cell.longitude).\(Int(hour.timeIntervalSince1970))"
        }
    }

    private struct WindEntry: Codable {
        let hour: WeatherWindHour?
        let fetchedAt: Date

        var isHistorical: Bool {
            guard let hour else { return false }
            return PhoneWeather.hour(containing: hour.date) + PhoneWeather.hourLength <= fetchedAt
        }

        var expiresAt: Date {
            fetchedAt + (isHistorical ? PhoneWeather.historicalWindLifetime : PhoneWeather.forecastWindLifetime)
        }

        func isFresh(at now: Date) -> Bool { fetchedAt <= now && now < expiresAt }
    }

    private let provider: any PhoneWeatherProviding
    private let disk: WeatherDiskCache?
    private let clock: () -> Date
    private var conditions: [HourKey: Conditions] = [:]
    private var wind: [String: WindEntry]
    private var pendingWind: [HourKey: Task<[String: WindEntry], Error>] = [:]

    init(
        provider: any PhoneWeatherProviding, legacyDefaults: UserDefaults? = nil,
        disk: WeatherDiskCache? = nil, clock: @escaping () -> Date = { .now }
    ) {
        self.provider = provider
        self.disk = disk
        self.clock = clock
        wind = disk?.read([String: WindEntry].self, for: .wind) ?? [:]
        let now = clock()
        if let legacyDefaults { migrateLegacyCache(legacyDefaults, now: now) }
        prune()
    }

    /// Old installations stored each wind hour and the last conditions in preferences.
    /// Move only fresh entries. Removing the old keys makes the migration idempotent.
    private func migrateLegacyCache(_ defaults: UserDefaults, now: Date) {
        let decoder = JSONDecoder()
        let legacyWind = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("appleWeather.") }
        for (key, value) in legacyWind where key.hasPrefix("appleWeather.wind.") {
            if let data = value as? Data, let entry = try? decoder.decode(WindEntry.self, from: data),
                entry.isFresh(at: now), wind[key] == nil
            {
                wind[key] = entry
            }
        }
        if !legacyWind.isEmpty {
            pruneWind(now: now)
            saveWind()
            for key in legacyWind.keys { defaults.removeObject(forKey: key) }
        }

        let conditionsKey = UserSettings.Key.lastWeather
        if let data = defaults.data(forKey: conditionsKey),
            let entry = try? decoder.decode(Conditions.self, from: data),
            entry.isFresh(at: now), Conditions.load(from: disk, now: now) == nil
        {
            disk?.write(entry, for: .conditions)
        }
        defaults.removeObject(forKey: conditionsKey)
        // The legacy marks and legal URL have no trustworthy fetch date.
        defaults.removeObject(forKey: "weather.appleAttribution")
    }

    func prune() {
        let now = clock()
        pruneConditions(now: now)
        _ = Conditions.load(from: disk, now: now)
        let count = wind.count
        pruneWind(now: now)
        if wind.count != count { saveWind() }
    }

    private func pruneConditions(now: Date) {
        conditions = conditions.filter { $0.value.isFresh(at: now) && $0.key.hour == Self.hour(containing: now) }
        guard conditions.count > Self.conditionsLimit else { return }
        let oldest = conditions.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
        for (key, _) in oldest.prefix(conditions.count - Self.conditionsLimit) { conditions[key] = nil }
    }

    func current(at cell: WeatherGridCell, force: Bool = false) async throws -> Conditions {
        let now = clock()
        let key = HourKey(cell: cell, hour: Self.hour(containing: now))
        pruneConditions(now: now)
        if !force, let cached = conditions[key] { return cached }
        let weather = try await provider.current(at: cell)
        let fetchedAt = clock()
        let answer = Conditions(weather: weather, fetchedAt: fetchedAt)
        conditions[HourKey(cell: cell, hour: Self.hour(containing: fetchedAt))] = answer
        pruneConditions(now: fetchedAt)
        return answer
    }

    nonisolated static let hourLength: TimeInterval = 3_600
    /// WeatherKit's documented historical lower limit and maximum span per request.
    private static let firstHistoricalHour = Date(timeIntervalSince1970: 1_627_776_000)  // 2021-08-01 UTC
    private static let maximumHours = 240

    nonisolated static func hour(containing date: Date) -> Date {
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

    private func fresh(_ key: HourKey, now: Date) -> WindEntry? {
        guard let entry = wind[key.cacheKey], entry.isFresh(at: now) else { return nil }
        // An explicit comparison refreshes forecasts and gaps after the fetch hour passes.
        return entry.isHistorical || Self.hour(containing: entry.fetchedAt) == Self.hour(containing: now) ? entry : nil
    }

    func cachedWind(for query: SessionWeatherWind.Query) -> SessionWeatherWind.Comparison? {
        let now = clock()
        let keys = hourKeys(for: query, now: now)
        let entries = keys.compactMap { wind[$0.cacheKey] }.filter { $0.isFresh(at: now) }
        guard entries.count == keys.count else { return nil }
        return comparison(from: entries)
    }

    func wind(for query: SessionWeatherWind.Query) async throws -> SessionWeatherWind.Comparison {
        let keys = hourKeys(for: query, now: clock())
        // Hold results for this request locally so a long or concurrent comparison can
        // finish even if some of its hours are evicted from the shared cache.
        var entries: [String: WindEntry] = [:]
        var index = keys.startIndex
        while index < keys.endIndex {
            let key = keys[index]
            let now = clock()
            if entries[key.cacheKey] != nil {
                index += 1
            } else if let pending = pendingWind[key] {
                entries.merge(try await pending.value) { current, _ in current }
                index += 1
            } else if let entry = fresh(key, now: now) {
                entries[key.cacheKey] = entry
                index += 1
            } else {
                // Request adjacent misses together, skipping hours already cached or in flight.
                let start = index
                repeat {
                    index += 1
                } while index < keys.endIndex && index - start < Self.maximumHours
                    && entries[keys[index].cacheKey] == nil && fresh(keys[index], now: now) == nil
                    && pendingWind[keys[index]] == nil
                entries.merge(try await requestWind(keys[start..<index])) { current, _ in current }
            }
        }

        let now = clock()
        let selected = keys.compactMap { entries[$0.cacheKey] }
        guard selected.count == keys.count, selected.allSatisfy({ $0.isFresh(at: now) }),
            let answer = comparison(from: selected)
        else { throw Failure.unavailable }

        // Keep forecast gaps only for a successful comparison. An entirely unanswered
        // comparison can be retried immediately.
        let oldCount = wind.count
        for key in keys {
            guard let entry = entries[key.cacheKey], entry.hour == nil, wind[key.cacheKey] == nil else { continue }
            wind[key.cacheKey] = entry
        }
        if wind.count != oldCount {
            pruneWind(now: now)
            saveWind()
        }
        return answer
    }

    private func comparison(from entries: [WindEntry]) -> SessionWeatherWind.Comparison? {
        guard let wind = SessionWeatherWind.average(entries.compactMap(\.hour)),
            let expiresAt = entries.map(\.expiresAt).min()
        else { return nil }
        return .init(wind: wind, expiresAt: expiresAt)
    }

    private func requestWind(_ keys: ArraySlice<HourKey>) async throws -> [String: WindEntry] {
        guard let first = keys.first, let last = keys.last else { return [:] }
        let interval = DateInterval(start: first.hour, end: last.hour.addingTimeInterval(Self.hourLength))
        let task = Task {
            defer {
                for key in keys { pendingWind[key] = nil }
            }
            let samples = try await provider.hourlyWind(at: first.cell, during: interval)
            let now = clock()
            let byHour = Dictionary(
                samples.map { (Self.hour(containing: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
            var entries: [String: WindEntry] = [:]
            for key in keys {
                let entry = WindEntry(hour: byHour[key.hour], fetchedAt: now)
                entries[key.cacheKey] = entry
                // Replace old forecast gaps or samples with this request's answer.
                wind[key.cacheKey] = entry.hour == nil ? nil : entry
            }
            pruneWind(now: now)
            saveWind()
            return entries
        }
        for key in keys { pendingWind[key] = task }
        return try await task.value
    }

    private func pruneWind(now: Date) {
        wind = wind.filter { $0.value.isFresh(at: now) }
        guard wind.count > Self.windLimit else { return }
        let oldest = wind.sorted {
            $0.value.fetchedAt == $1.value.fetchedAt ? $0.key < $1.key : $0.value.fetchedAt < $1.value.fetchedAt
        }
        for (key, _) in oldest.prefix(wind.count - Self.windLimit) { wind[key] = nil }
    }

    private func saveWind() {
        if wind.isEmpty {
            disk?.remove(.wind)
        } else {
            disk?.write(wind, for: .wind)
        }
    }
}
