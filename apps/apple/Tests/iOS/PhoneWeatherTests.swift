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
        let client = PhoneWeather(provider: service, defaults: nil)
        let first = try XCTUnwrap(WeatherGridCell(latitude: 10.04, longitude: -30.06))
        let nearby = try XCTUnwrap(WeatherGridCell(latitude: 9.97, longitude: -30.08))
        let elsewhere = try XCTUnwrap(WeatherGridCell(latitude: 10.06, longitude: -30.08))
        _ = try await client.current(at: first, now: start)
        let cached = try await client.current(at: nearby, now: start + 60)
        XCTAssertEqual(service.currentCells.count, 1)
        XCTAssertEqual(cached.fetchedAt, start)
        XCTAssertEqual(service.currentCells.first?.latitude, 10)
        XCTAssertEqual(service.currentCells.first?.longitude, -30.1)
        _ = try await client.current(at: elsewhere, now: start + 60)
        _ = try await client.current(at: nearby, now: start + hour)
        XCTAssertEqual(service.currentCells, [first, elsewhere, nearby])
    }

    func testSailingCacheReusesHistoricalHoursAcrossOverlappingSelectionsOffline() async throws {
        let service = StubWeather()
        let suite = "PhoneWeatherTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = PhoneWeather(provider: service, defaults: defaults)
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10.04, longitude: -30.06))
        let now = start + 1_000 * hour
        let first = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start + hour)
        let second = SessionWeatherWind.Query(cell: cell, firstHour: start + hour, lastHour: start + 2 * hour)
        async let firstAnswer = client.wind(for: first, now: now)
        async let secondAnswer = client.wind(for: second, now: now)
        let answers = try await [firstAnswer, secondAnswer]
        XCTAssertEqual(answers.map(\.hours), [4, 4])
        XCTAssertEqual(service.windRequests.count, 2)
        let requestedHours = service.windRequests.reduce(0) { $0 + $1.interval.duration / hour }
        XCTAssertEqual(requestedHours, 5)
        for request in service.windRequests {
            XCTAssertEqual(request.cell.latitude, 10)
            XCTAssertEqual(request.cell.longitude, -30.1)
        }

        service.offline = true
        let reopened = PhoneWeather(provider: service, defaults: defaults)
        XCTAssertEqual(reopened.cachedWind(for: first, now: now), answers[0])
        let offlineResult = try await reopened.wind(for: second, now: now)
        XCTAssertEqual(offlineResult, answers[1])
        XCTAssertEqual(service.windRequests.count, 2)
    }

    func testPartialHistoryCanBeReopenedOffline() async throws {
        let service = StubWeather()
        service.missingHours = [start]
        let suite = "PhoneWeatherTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = PhoneWeather(provider: service, defaults: defaults)
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let query = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        let result = try await client.wind(for: query, now: start + 100 * hour)
        XCTAssertEqual(result.hours, 2)

        service.offline = true
        let reopened = PhoneWeather(provider: service, defaults: defaults)
        XCTAssertEqual(reopened.cachedWind(for: query, now: start + 101 * hour), result)
        XCTAssertEqual(service.windRequests.count, 1)
    }

    func testOutOfRangeSkipsProviderAndOfflineErrorPropagates() async throws {
        let service = StubWeather()
        let client = PhoneWeather(provider: service, defaults: nil)
        let cell = try XCTUnwrap(WeatherGridCell(latitude: 10, longitude: -30))
        let unsupported = Date(timeIntervalSince1970: 0)
        let old = SessionWeatherWind.Query(cell: cell, firstHour: unsupported, lastHour: unsupported)
        do {
            _ = try await client.wind(for: old, now: start)
            XCTFail("Expected historical data to be unavailable")
        } catch PhoneWeather.Failure.unavailable {}
        XCTAssertTrue(service.windRequests.isEmpty)

        service.offline = true
        let covered = SessionWeatherWind.Query(cell: cell, firstHour: start, lastHour: start)
        do {
            _ = try await client.wind(for: covered, now: start)
            XCTFail("Expected an offline error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertNil(client.cachedWind(for: covered, now: start))
        service.offline = false
        let retry = try await client.wind(for: covered, now: start)
        XCTAssertEqual(retry.hours, 3)
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
        forecasts.complete(first, with: late)
        XCTAssertNil(forecasts.wind(for: second))
        XCTAssertEqual(forecasts.state(for: second), .failed)
        XCTAssertEqual(forecasts.wind(for: first), late)
        XCTAssertEqual(forecasts.state(for: first), .idle)
    }
}

@MainActor
private final class StubWeather: PhoneWeatherProviding {
    var currentCells: [WeatherGridCell] = []
    var windRequests: [(cell: WeatherGridCell, interval: DateInterval)] = []
    var offline = false
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
            return WeatherWindHour(date: date, fromDegrees: 225, speed: 6)
        }
    }
}
