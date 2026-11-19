import WaterKit
import XCTest

@testable import MadeGood

final class OpenMeteoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01 00:00 UTC

    private func track(start: Date, latitude: Double = 10.04, longitude: Double = -30.06) -> Track {
        Track(
            sessionId: UUID(), sport: .sailing, startedAt: start,
            gps: [
                GPSFix(t: 0, latitude: latitude, longitude: longitude, horizontalAccuracy: 5),
                GPSFix(t: 1, latitude: latitude + 0.06, longitude: longitude - 0.04, horizontalAccuracy: 5),
            ])
    }

    /// Only the area rounded to 0.5° (about 50 km), whole UTC days and the variables leave
    /// the phone.
    func testRequestSendsRoundedAreaAndDatesOnly() throws {
        let position = try XCTUnwrap(OpenMeteo.roundedPosition(track(start: start).gps))
        XCTAssertEqual(position.latitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(position.longitude, -30.0, accuracy: 1e-9)
        XCTAssertEqual(OpenMeteo.round(10.26), 10.5)
        XCTAssertEqual(OpenMeteo.round(-30.24), -30.0)
        XCTAssertNil(OpenMeteo.roundedPosition([]))

        let query = try XCTUnwrap(OpenMeteo.query(track: track(start: start), duration: 3 * 3_600))
        let old = OpenMeteo.request(query, now: start.addingTimeInterval(30 * 86_400))
        let url = try XCTUnwrap(old.url)
        XCTAssertEqual(url.host, "archive-api.open-meteo.com")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
            [
                "latitude": "10.0", "longitude": "-30.0", "hourly": "wind_speed_10m,wind_direction_10m",
                "wind_speed_unit": "ms", "timeformat": "unixtime", "timezone": "GMT",
                "start_date": "2000-01-01", "end_date": "2000-01-01",
            ])
        XCTAssertFalse(old.httpShouldHandleCookies)

        let recent = OpenMeteo.request(query, now: start.addingTimeInterval(5 * 3_600))
        XCTAssertEqual(recent.url?.host, "api.open-meteo.com")
    }

    /// Directions either side of north average to north, weighted by speed, and only the
    /// hours around the session count.
    func testParseAveragesTheSessionHoursAcrossNorth() throws {
        let t0 = start.timeIntervalSince1970
        let json = """
            {"hourly":{"time":[\(t0 - 7_200),\(t0),\(t0 + 3_600),\(t0 + 7_200),\(t0 + 36_000)],
            "wind_speed_10m":[20,4,4,null,20],
            "wind_direction_10m":[180,350,10,90,180]}}
            """
        let query = try XCTUnwrap(OpenMeteo.query(track: track(start: start), duration: 3_600))
        let wind = try OpenMeteo.parse(Data(json.utf8), query: query)
        XCTAssertEqual(wind.hours, 2)
        XCTAssertEqual(GPSFix.signedAngle(wind.fromDegrees), 0, accuracy: 1e-6)
        XCTAssertEqual(wind.speed, 4, accuracy: 1e-9)

        XCTAssertThrowsError(try OpenMeteo.parse(Data("{}".utf8), query: query)) {
            XCTAssertEqual($0 as? OpenMeteo.Failure, .badResponse)
        }
        let empty = #"{"hourly":{"time":[],"wind_speed_10m":[],"wind_direction_10m":[]}}"#
        XCTAssertThrowsError(try OpenMeteo.parse(Data(empty.utf8), query: query)) {
            XCTAssertEqual($0 as? OpenMeteo.Failure, .noData)
        }
    }

    /// Review regression: the cache was keyed by session ID, so a selection trimmed to
    /// another area or day reused the old forecast. It is keyed by the query now.
    func testCacheIsKeyedByTheQuery() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OpenMeteoTests.\(UUID().uuidString)"))
        let original = try XCTUnwrap(OpenMeteo.query(track: track(start: start), duration: 3_600))
        XCTAssertNil(OpenMeteoCache.wind(for: original, defaults: defaults))
        let wind = OpenMeteoWind(fromDegrees: 12, speed: 5, hours: 3)
        OpenMeteoCache.store(wind, for: original, defaults: defaults)
        XCTAssertEqual(OpenMeteoCache.wind(for: original, defaults: defaults), wind)

        // The same request from another session (or a re-read) hits the cache.
        let same = try XCTUnwrap(OpenMeteo.query(track: track(start: start), duration: 3_600))
        XCTAssertEqual(OpenMeteoCache.wind(for: same, defaults: defaults), wind)

        // Another day, another area, or other hours of the same day ask again.
        let nextDay = try XCTUnwrap(
            OpenMeteo.query(track: track(start: start.addingTimeInterval(86_400)), duration: 3_600))
        let elsewhere = try XCTUnwrap(OpenMeteo.query(track: track(start: start, latitude: 12), duration: 3_600))
        let laterHours = try XCTUnwrap(
            OpenMeteo.query(track: track(start: start.addingTimeInterval(6 * 3_600)), duration: 3_600))
        for query in [nextDay, elsewhere, laterHours] {
            XCTAssertNotEqual(query, original)
            XCTAssertNil(OpenMeteoCache.wind(for: query, defaults: defaults))
        }
    }
}

final class OpenMeteoForecastsTests: XCTestCase {
    private func query(day: Double) -> OpenMeteo.Query {
        OpenMeteo.Query(
            latitude: 10, longitude: -30, startDate: "2000-01-0\(Int(day) + 1)", endDate: "2000-01-0\(Int(day) + 1)",
            firstHour: 946_684_800 + day * 86_400, lastHour: 946_684_800 + day * 86_400)
    }

    /// Re-check regression: a fetch for selection A that completed after the user trimmed
    /// to selection B overwrote the single forecast slot, so B showed A's wind.
    func testLateCompletionStaysWithItsOwnQuery() {
        let a = query(day: 0)
        let b = query(day: 1)
        var forecasts = OpenMeteoForecasts()
        forecasts.start(a)
        XCTAssertEqual(forecasts.state(for: a), .loading)
        // The selection changes to B while A is in flight; B starts idle with no wind.
        XCTAssertEqual(forecasts.state(for: b), .idle)
        XCTAssertNil(forecasts.wind(for: b))
        forecasts.start(b)
        forecasts.fail(b)
        // A answers late: it is filed under A and changes nothing for B.
        let late = OpenMeteoWind(fromDegrees: 120, speed: 4, hours: 2)
        forecasts.complete(a, with: late)
        XCTAssertNil(forecasts.wind(for: b))
        XCTAssertEqual(forecasts.state(for: b), .failed)
        XCTAssertEqual(forecasts.wind(for: a), late)
        XCTAssertEqual(forecasts.state(for: a), .idle)
        XCTAssertNil(forecasts.wind(for: nil))
    }
}

final class SailingReadingsTests: XCTestCase {
    private func readings(side: WindEstimate.Side, vmg: Double, angle: Double) -> SailingReadings {
        let wind = WindEstimate(
            fromDegrees: 200, axisConfidence: 0.99, axisUncertainty: 3, legCourses: [160, 240], legAngle: 80,
            side: side)
        return SailingReadings(LiveSailing(wind: wind, tacks: 3, gybes: 0, vmg: vmg, trueWindAngle: angle))
    }

    /// Review regression: true wind 020°, gybing on 160°/240°, so the track estimate is 200°
    /// and its "tacks" are really gybes. Unresolved, nothing names a side.
    func testUnresolvedWindNamesOnlyTheAxis() {
        let unresolved = readings(side: .unresolved, vmg: 3.8, angle: 40)
        XCTAssertFalse(unresolved.resolved)
        XCTAssertEqual(unresolved.vmgTitle, "VMG")
        XCTAssertEqual(unresolved.windTitle, "Wind axis")
        XCTAssertEqual(unresolved.windText, "200°/020°")
        XCTAssertEqual(unresolved.angleTitle, "Off axis")
        XCTAssertEqual(unresolved.angleText, "40°")
        XCTAssertEqual(unresolved.maneuverRows.map(\.title), ["Tacks/gybes"])
        XCTAssertEqual(unresolved.maneuverRows.map(\.count), [3])
        XCTAssertEqual(readings(side: .priorInconclusive(290), vmg: 3.8, angle: 140).angleText, "40°")
        XCTAssertFalse(readings(side: .priorInconclusive(290), vmg: 3.8, angle: 40).resolved)

        let resolved = readings(side: .resolvedByPrior, vmg: 3.8, angle: 40)
        XCTAssertEqual(resolved.vmgTitle, "VMG upwind")
        XCTAssertEqual(resolved.windText, "200°")
        XCTAssertEqual(resolved.angleText, "40° stbd")
        XCTAssertEqual(resolved.maneuverRows.map(\.title), ["Tacks", "Gybes"])
        XCTAssertEqual(readings(side: .resolvedByPrior, vmg: -3.8, angle: 140).vmgTitle, "VMG downwind")
    }
}

extension GPSFix {
    /// Degrees in (-180, 180], so a direction near north compares with 0.
    fileprivate static func signedAngle(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d > 180 ? d - 360 : d
    }
}

final class LocalWeatherRequestTests: XCTestCase {
    /// Only the position rounded to 0.1° (about 10 km) and the variables leave the phone.
    func testCurrentRequestSendsRoundedPositionOnly() throws {
        let request = OpenMeteo.currentRequest(latitude: 10.04, longitude: -30.06)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.open-meteo.com")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["latitude"], "10.0")
        XCTAssertEqual(query["longitude"], "-30.1")
        XCTAssertEqual(query["current"], WeatherNow.currentVariables)
        XCTAssertEqual(query["hourly"], WeatherNow.hourlyVariables)
        XCTAssertEqual(query["wind_speed_unit"], "ms")
        XCTAssertEqual(Set(query.keys), [
            "latitude", "longitude", "current", "hourly", "forecast_hours", "wind_speed_unit", "timeformat",
            "timezone",
        ])
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testWeatherTextUsesWholeNumbersAndCompass() {
        let weather = WeatherNow(time: 0, temperature: 20, code: 1, windSpeed: 6.5, windGust: 9.5, windFrom: 225)
        let text = WeatherText(weather, speedUnit: .knots)
        XCTAssertEqual(text.headline, "Good sailing breeze")
        XCTAssertEqual(text.wind, "13 kn SW · gusts 18")
        XCTAssertEqual(WeatherText.compass(350), "N")
        XCTAssertEqual(WeatherText.compass(-90), "W")
        XCTAssertEqual(WeatherText.when(1_000, now: 0), "soon")
    }
}
