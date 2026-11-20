import WaterKit
import XCTest

@testable import MadeGood

@MainActor
final class PhoneWeatherTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_728_000_000)
    private let hour: TimeInterval = 3_600

    func testConditionsMappingPreservesWindFromAndConvertsToSI() throws {
        let wind = AppleWeatherProvider.windHour(
            date: start, direction: .init(value: .pi, unit: .radians), speed: .init(value: 20, unit: .milesPerHour)
        )
        let hourly = AppleWeatherProvider.hour(
            date: start + hour, condition: .thunderstorms, gust: .init(value: 40, unit: .milesPerHour),
            precipitation: 0.75)
        let weather = try AppleWeatherProvider.conditions(
            temperature: .init(value: 68, unit: .fahrenheit), condition: .mostlyCloudy, wind: wind,
            gust: .init(value: 30, unit: .milesPerHour), cloudCover: 0.6,
            visibility: .init(value: 5, unit: .kilometers), isDaylight: false, hours: [hourly])

        XCTAssertEqual(weather.time, start.timeIntervalSince1970)
        XCTAssertEqual(weather.temperature, 20, accuracy: 1e-6)
        XCTAssertEqual(weather.windSpeed, 8.9408, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(weather.windGust), 13.4112, accuracy: 1e-6)
        XCTAssertEqual(weather.windFrom, 180, accuracy: 1e-6)
        XCTAssertEqual(weather.visibility, 5_000)
        XCTAssertEqual(weather.cloudCover, 60)
        XCTAssertFalse(weather.isDay)
        XCTAssertEqual(WaterOutlook.sky(code: weather.code), .partlyCloudy)
        XCTAssertEqual(WaterOutlook.sky(code: hourly.code), .thunderstorm)
        XCTAssertEqual(hourly.time, (start + hour).timeIntervalSince1970)
        XCTAssertEqual(try XCTUnwrap(hourly.gust), 17.8816, accuracy: 1e-6)
        XCTAssertEqual(hourly.precipitationProbability, 75)
    }

    func testCurrentCacheUsesRoundedCellAndHour() async throws {
        let service = StubWeather()
        let clock = WeatherTestClock(start)
        let client = PhoneWeather(provider: service, clock: { clock.now })
        let first = try XCTUnwrap(WeatherGridCell(latitude: 10.04, longitude: -30.06))
        let nearby = try XCTUnwrap(WeatherGridCell(latitude: 9.97, longitude: -30.08))
        let elsewhere = try XCTUnwrap(WeatherGridCell(latitude: 10.06, longitude: -30.08))
        _ = try await client.current(at: first)
        clock.now = start + 60
        let cached = try await client.current(at: nearby)
        XCTAssertEqual(service.currentCells.count, 1)
        XCTAssertEqual(cached.fetchedAt, start)
        XCTAssertEqual(service.currentCells.first?.latitude, 10)
        XCTAssertEqual(service.currentCells.first?.longitude, -30.1)
        _ = try await client.current(at: elsewhere)
        clock.now = start + PhoneWeather.conditionsLifetime
        _ = try await client.current(at: nearby)
        clock.now = start + hour
        _ = try await client.current(at: nearby)
        XCTAssertEqual(service.currentCells, [first, elsewhere, nearby, nearby])
    }

    func testSailingCacheReusesHistoricalHoursAcrossOverlappingSelectionsOffline() async throws {
        let service = StubWeather()
        let disk = WeatherDiskCache(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let now = start + 1_000 * hour
        let client = PhoneWeather(provider: service, disk: disk, clock: { now })
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10.04, longitude: -30.06))
        let first = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start + hour)
        let second = SessionWeatherWind.Query(cell: cell, firstHour: start + hour, lastHour: start + 2 * hour)
        async let firstAnswer = client.wind(for: first)
        async let secondAnswer = client.wind(for: second)
        let answers = try await [firstAnswer, secondAnswer]
        XCTAssertEqual(answers.map(\.wind.hours), [4, 4])
        XCTAssertEqual(service.windRequests.count, 2)
        let requestedHours = service.windRequests.reduce(0) { $0 + $1.interval.duration / hour }
        XCTAssertEqual(requestedHours, 5)
        for request in service.windRequests {
            XCTAssertEqual(request.cell.latitude, 10)
            XCTAssertEqual(request.cell.longitude, -30.1)
        }

        service.offline = true
        let reopened = PhoneWeather(provider: service, disk: disk, clock: { now })
        XCTAssertEqual(reopened.cachedWind(for: first), answers[0])
        let offlineResult = try await reopened.wind(for: second)
        XCTAssertEqual(offlineResult, answers[1])
        XCTAssertEqual(service.windRequests.count, 2)
    }

    func testPartialHistoryCanBeReopenedOffline() async throws {
        let service = StubWeather()
        service.missingHours = [start]
        let disk = WeatherDiskCache(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let clock = WeatherTestClock(start + 100 * hour)
        let client = PhoneWeather(provider: service, disk: disk, clock: { clock.now })
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let query = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        let result = try await client.wind(for: query)
        XCTAssertEqual(result.wind.hours, 2)

        service.offline = true
        clock.now += hour - 1
        let reopened = PhoneWeather(provider: service, disk: disk, clock: { clock.now })
        XCTAssertEqual(reopened.cachedWind(for: query), result)
        clock.now += 1
        XCTAssertNil(reopened.cachedWind(for: query))
        XCTAssertEqual(service.windRequests.count, 1)
    }

    func testOutOfRangeSkipsProviderAndOfflineErrorPropagates() async throws {
        let service = StubWeather()
        let now = start
        let client = PhoneWeather(provider: service, clock: { now })
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let unsupported = Date(timeIntervalSince1970: 0)
        let old = SessionWeatherWind.Query(cell: cell, firstHour: unsupported, lastHour: unsupported)
        do {
            _ = try await client.wind(for: old)
            XCTFail("Expected historical data to be unavailable")
        } catch PhoneWeather.Failure.unavailable {}
        XCTAssertTrue(service.windRequests.isEmpty)

        service.offline = true
        let covered = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        do {
            _ = try await client.wind(for: covered)
            XCTFail("Expected an offline error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertNil(client.cachedWind(for: covered))
        service.offline = false
        let retry = try await client.wind(for: covered)
        XCTAssertEqual(retry.wind.hours, 3)
    }

    func testHistoricalWindExpiresInMemoryAndIsPrunedOnWriteAndLaunch() async throws {
        let service = StubWeather()
        let disk = WeatherDiskCache(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let clock = WeatherTestClock(start + 100 * hour)
        let client = PhoneWeather(provider: service, disk: disk, clock: { clock.now })
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let first = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        let second = SessionWeatherWind.Query(cell: cell, firstHour: start + 3 * hour, lastHour: start + 3 * hour)
        let result = try await client.wind(for: first)

        clock.now = result.expiresAt - 1
        XCTAssertEqual(client.cachedWind(for: first), result)
        clock.now = result.expiresAt
        XCTAssertNil(client.cachedWind(for: first))
        XCTAssertEqual(try windSnapshot(in: disk).count, 3)
        let next = try await client.wind(for: second)
        let snapshot = try windSnapshot(in: disk)
        XCTAssertEqual(snapshot.count, 3)

        clock.now = next.expiresAt
        let reopened = PhoneWeather(provider: service, disk: disk, clock: { clock.now })
        XCTAssertNil(reopened.cachedWind(for: second))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: disk.directory.appending(path: WeatherDiskCache.Entry.wind.rawValue).path))
    }

    func testLegacyCleanupDropsExpiredForecastsAndObservationsButKeepsFreshHours() throws {
        struct LegacyEntry: Encodable {
            let hour: WeatherWindHour
            let fetchedAt: Date
        }

        let disk = WeatherDiskCache(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let suite = "PhoneWeatherTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let now = start + 100 * hour
        let query = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        func seed(hour: Date, fetchedAt: Date) throws {
            let key = "appleWeather.wind.10.0,-30.0.\(Int(hour.timeIntervalSince1970))"
            let data = try JSONEncoder().encode(
                LegacyEntry(hour: .init(date: hour, fromDegrees: 230, speed: 5), fetchedAt: fetchedAt))
            defaults.set(data, forKey: key)
        }
        for hour in [start - hour, start, start + hour] { try seed(hour: hour, fetchedAt: now - 60) }
        try seed(hour: start - 5 * hour, fetchedAt: now - PhoneWeather.historicalWindLifetime)
        try seed(hour: now, fetchedAt: now - PhoneWeather.forecastWindLifetime)
        defaults.set("bad", forKey: "appleWeather.invalid")
        defaults.set(true, forKey: UserSettings.Key.localWeather)
        let conditions = PhoneWeather.Conditions(
            weather: WeatherNow(time: 0, temperature: 20, code: 1, windSpeed: 6, windFrom: 225), fetchedAt: now - 60)
        defaults.set(try JSONEncoder().encode(conditions), forKey: UserSettings.Key.lastWeather)
        defaults.set(Data([0]), forKey: "weather.appleAttribution")

        let service = StubWeather()
        let client = PhoneWeather(provider: service, legacyDefaults: defaults, disk: disk, clock: { now })
        XCTAssertEqual(client.cachedWind(for: query)?.wind.hours, 3)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("appleWeather.") })
        XCTAssertTrue(defaults.bool(forKey: UserSettings.Key.localWeather))
        XCTAssertNil(defaults.data(forKey: UserSettings.Key.lastWeather))
        XCTAssertNil(defaults.data(forKey: "weather.appleAttribution"))
        XCTAssertEqual(PhoneWeather.Conditions.load(from: disk, now: now)?.weather, conditions.weather)
        let snapshot = try windSnapshot(in: disk)
        XCTAssertEqual(snapshot.count, 3)
    }

    func testWindCacheLimitDoesNotTruncateAnInFlightLongComparison() async throws {
        let disk = WeatherDiskCache(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let service = StubWeather()
        let now = start + 1_000 * hour
        let client = PhoneWeather(provider: service, disk: disk, clock: { now })
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let last = start + Double(PhoneWeather.windLimit) * hour
        let query = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: last)
        let answer = try await client.wind(for: query)
        XCTAssertEqual(answer.wind.hours, PhoneWeather.windLimit + 3)
        XCTAssertEqual(service.windRequests.count, 3)
        XCTAssertNil(client.cachedWind(for: query))
        let snapshot = try windSnapshot(in: disk)
        XCTAssertEqual(snapshot.count, PhoneWeather.windLimit)
    }

    func testExpiredConditionsAreRemovedFromDisk() throws {
        let disk = WeatherDiskCache(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let answer = PhoneWeather.Conditions(
            weather: WeatherNow(time: 0, temperature: 20, code: 1, windSpeed: 6, windFrom: 225), fetchedAt: start)
        disk.write(answer, for: .conditions)
        XCTAssertEqual(PhoneWeather.Conditions.load(from: disk, now: answer.expiresAt - 1)?.weather, answer.weather)
        let now = answer.expiresAt
        _ = PhoneWeather(provider: StubWeather(), disk: disk, clock: { now })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: disk.directory.appending(path: WeatherDiskCache.Entry.conditions.rawValue).path))
    }

    func testAttributionRefreshFailureKeepsValidMarksAndLimitsDisplay() async throws {
        let marks = AppleWeatherAttribution(
            darkMark: Data([1]), lightMark: Data([2]), legalPageURL: try XCTUnwrap(URL(string: "https://example.com")),
            fetchedAt: start)
        let clock = WeatherTestClock(marks.expiresAt - 60)
        let fallback = try await AppleWeatherAttribution.refresh(keeping: marks, clock: { clock.now }) {
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(fallback.darkMark, marks.darkMark)
        XCTAssertEqual(fallback.limitedDisplayExpiry(weatherExpiresAt: clock.now + hour), marks.expiresAt)
        XCTAssertEqual(fallback.limitedDisplayExpiry(weatherExpiresAt: clock.now + 30), clock.now + 30)

        clock.now = marks.expiresAt
        do {
            _ = try await AppleWeatherAttribution.refresh(keeping: marks, clock: { clock.now }) {
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expired marks must not be used after a failed refresh")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testSailingWeatherComparisonLeavesGPXAndUploadInputsUnchanged() async throws {
        let now = start + 100 * hour
        let provider = StubWeather()
        provider.windDirection = 10
        let client = PhoneWeather(provider: provider, clock: { now })
        var position = DemoFeed.origin
        let fixes = (0...140).map { second in
            let sample = DemoFeed.beat(at: Double(second))
            let fix = GPSFix(
                t: Double(second), latitude: position.lat, longitude: position.lon,
                horizontalAccuracy: 5, speed: sample.speed, course: sample.course)
            position = Geo.destination(
                lat: position.lat, lon: position.lon, bearing: sample.course, distance: sample.speed)
            return fix
        }
        let end = start + 140
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .sailing, startedAt: start.timeIntervalSince1970,
            endedAt: end.timeIntervalSince1970,
            device: .init(kind: "watch", model: "Synthetic", os: "watchOS"),
            app: .init(version: "1.0", build: "test"))
        let trim = try SessionTrim(start: 1, end: 139)
        let selection = try SessionSelection(session: RawSession(meta: meta, gps: fixes), trim: trim)
        let query = try XCTUnwrap(SessionWeatherWind.query(track: selection.track, duration: selection.duration))

        let originalGPX = GPXWriter().data(for: selection)
        let originalTrack = selection.replay.analyzedTrack(from: selection.track)
        let originalPayload = SessionUploadSnapshot(track: originalTrack, endedAt: end)
        let originalTrackBytes = try TrackCodec.encodeJSON(originalTrack)

        let weather = try await client.wind(for: query)
        XCTAssertFalse(selection.sailingAnalysis().windResolved)
        XCTAssertTrue(selection.sailingAnalysis(windPrior: weather.wind.fromDegrees).windResolved)

        let uploadedTrack = selection.replay.analyzedTrack(from: selection.track)
        XCTAssertEqual(try TrackCodec.encodeJSON(uploadedTrack), originalTrackBytes)
        XCTAssertEqual(SessionUploadSnapshot(track: uploadedTrack, endedAt: end), originalPayload)
        XCTAssertEqual(GPXWriter().data(for: selection), originalGPX)
    }

    func testSessionQueryUsesCircularMeanAndRoundsIt() throws {
        let track = Track(
            sessionId: UUID(), sport: .sailing, startedAt: start,
            gps: [
                GPSFix(t: 0, latitude: 10.02, longitude: 179.98, horizontalAccuracy: 5),
                GPSFix(t: 1, latitude: 10.04, longitude: -179.99, horizontalAccuracy: 5),
            ])
        let query = try XCTUnwrap(SessionWeatherWind.query(track: track, duration: 1))
        XCTAssertEqual(query.cell.latitude, 10)
        XCTAssertEqual(query.cell.longitude, -180)
        XCTAssertEqual(query.firstHour, start)
        XCTAssertEqual(query.lastHour, start)
    }

    func testWindDirectionAveragesAcrossNorthAndWeightsBySpeed() throws {
        let average = try XCTUnwrap(
            SessionWeatherWind.average([
                .init(date: start, fromDegrees: 350, speed: 4),
                .init(date: start + hour, fromDegrees: 10, speed: 4),
                .init(date: start + 2 * hour, fromDegrees: 90, speed: 1),
            ]))
        XCTAssertEqual(average.hours, 3)
        XCTAssertEqual(average.fromDegrees, 7.2338, accuracy: 0.001)
        XCTAssertEqual(average.speed, 3, accuracy: 1e-6)
    }

    func testLateCompletionStaysWithItsOwnQuery() throws {
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let first = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        let second = SessionWeatherWind.Query(cell: cell, firstHour: start + hour, lastHour: start + hour)
        var forecasts = SessionWeatherForecasts()
        forecasts.start(first)
        XCTAssertEqual(forecasts.state(for: first), .loading)
        XCTAssertEqual(forecasts.state(for: second), .idle)
        XCTAssertNil(forecasts.wind(for: second))
        forecasts.start(second)
        forecasts.fail(second)
        let late = SessionWeatherWind(fromDegrees: 120, speed: 4, hours: 2)
        let expiry = start + hour
        forecasts.complete(first, with: .init(wind: late, expiresAt: expiry), now: start)
        XCTAssertNil(forecasts.wind(for: second, now: start))
        XCTAssertEqual(forecasts.state(for: second), .failed)
        XCTAssertEqual(forecasts.wind(for: first, now: start), late)
        XCTAssertEqual(forecasts.state(for: first), .idle)
        XCTAssertNil(forecasts.wind(for: first, now: expiry))
        forecasts.prune(now: expiry)
        XCTAssertNil(forecasts.nextExpiry)
    }

    private func windSnapshot(in disk: WeatherDiskCache) throws -> [String: Any] {
        let data = try Data(contentsOf: disk.directory.appending(path: WeatherDiskCache.Entry.wind.rawValue))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class StubWeather: PhoneWeatherProviding {
    var currentCells: [WeatherGridCell] = []
    var windRequests: [(cell: WeatherGridCell, interval: DateInterval)] = []
    var offline = false
    var windDirection = 225.0
    var missingHours: Set<Date> = []

    func current(at cell: WeatherGridCell) async throws -> WeatherNow {
        currentCells.append(cell)
        return WeatherNow(time: 0, temperature: 20, code: 1, windSpeed: 6, windFrom: 225)
    }

    func hourlyWind(at cell: WeatherGridCell, during interval: DateInterval) async throws -> [WeatherWindHour] {
        windRequests.append((cell, interval))
        await Task.yield()
        if offline { throw URLError(.notConnectedToInternet) }
        let hours = stride(
            from: interval.start.timeIntervalSince1970, to: interval.end.timeIntervalSince1970, by: 3_600)
        return hours.compactMap { timestamp in
            let date = Date(timeIntervalSince1970: timestamp)
            guard !missingHours.contains(date) else { return nil }
            return WeatherWindHour(date: date, fromDegrees: windDirection, speed: 6)
        }
    }
}

@MainActor
private final class WeatherTestClock {
    var now: Date

    init(_ now: Date) { self.now = now }
}
