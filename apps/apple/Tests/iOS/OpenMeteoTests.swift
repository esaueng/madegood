import WaterKit
import XCTest

@testable import MadeGood

final class OpenMeteoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01 00:00 UTC

    /// Only the rounded area, whole UTC days and the variables leave the phone.
    func testRequestSendsRoundedAreaAndDatesOnly() throws {
        let gps = [
            GPSFix(t: 0, latitude: 10.04, longitude: -30.06, horizontalAccuracy: 5),
            GPSFix(t: 1, latitude: 10.10, longitude: -30.10, horizontalAccuracy: 5),
        ]
        let position = try XCTUnwrap(OpenMeteo.roundedPosition(gps))
        XCTAssertEqual(position.latitude, 10.1, accuracy: 1e-9)
        XCTAssertEqual(position.longitude, -30.1, accuracy: 1e-9)
        XCTAssertNil(OpenMeteo.roundedPosition([]))

        let end = start.addingTimeInterval(3 * 3_600)
        let old = OpenMeteo.request(
            latitude: position.latitude, longitude: position.longitude, start: start, end: end,
            now: start.addingTimeInterval(30 * 86_400))
        let url = try XCTUnwrap(old.url)
        XCTAssertEqual(url.host, "archive-api.open-meteo.com")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
            [
                "latitude": "10.1", "longitude": "-30.1", "hourly": "wind_speed_10m,wind_direction_10m",
                "wind_speed_unit": "ms", "timeformat": "unixtime", "timezone": "GMT",
                "start_date": "2000-01-01", "end_date": "2000-01-01",
            ])
        XCTAssertFalse(old.httpShouldHandleCookies)

        let recent = OpenMeteo.request(
            latitude: 1, longitude: 2, start: start, end: end, now: end.addingTimeInterval(3_600))
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
        let wind = try OpenMeteo.parse(Data(json.utf8), start: start, end: start.addingTimeInterval(3_600))
        XCTAssertEqual(wind.hours, 2)
        XCTAssertEqual(GPSFix.signedAngle(wind.fromDegrees), 0, accuracy: 1e-6)
        XCTAssertEqual(wind.speed, 4, accuracy: 1e-9)

        XCTAssertThrowsError(try OpenMeteo.parse(Data("{}".utf8), start: start, end: start)) {
            XCTAssertEqual($0 as? OpenMeteo.Failure, .badResponse)
        }
        let empty = #"{"hourly":{"time":[],"wind_speed_10m":[],"wind_direction_10m":[]}}"#
        XCTAssertThrowsError(try OpenMeteo.parse(Data(empty.utf8), start: start, end: start)) {
            XCTAssertEqual($0 as? OpenMeteo.Failure, .noData)
        }
    }

    func testCacheRoundTripsPerSession() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OpenMeteoTests.\(UUID().uuidString)"))
        let id = UUID()
        XCTAssertNil(OpenMeteoCache.wind(for: id, defaults: defaults))
        let wind = OpenMeteoWind(fromDegrees: 12, speed: 5, hours: 3)
        OpenMeteoCache.store(wind, for: id, defaults: defaults)
        XCTAssertEqual(OpenMeteoCache.wind(for: id, defaults: defaults), wind)
        XCTAssertNil(OpenMeteoCache.wind(for: UUID(), defaults: defaults))
    }
}

private extension GPSFix {
    /// Degrees in (-180, 180], so a direction near north compares with 0.
    static func signedAngle(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d > 180 ? d - 360 : d
    }
}
