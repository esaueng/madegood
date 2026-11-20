import Testing
import WaterKit

@Suite struct WeatherGridCellTests {
    @Test func roundsToNearestTenthAndSharesCellForNearbyFixes() throws {
        let cell = try #require(WeatherGridCell(latitude: 10.04, longitude: -30.06))
        #expect(cell.latitude == 10)
        #expect(cell.longitude == -30.1)
        #expect(cell == WeatherGridCell(latitude: 9.97, longitude: -30.09))
        #expect(cell != WeatherGridCell(latitude: 10.05, longitude: -30.09))
        #expect(WeatherGridCell(latitude: -10.05, longitude: 30.05)?.latitude == -10.1)
        #expect(WeatherGridCell(latitude: -10.05, longitude: 30.05)?.longitude == 30.1)
    }

    @Test func canonicalizesPolesAndAntimeridian() throws {
        let west = try #require(WeatherGridCell(latitude: 1, longitude: -179.99))
        #expect(west == WeatherGridCell(latitude: 1, longitude: 179.99))
        #expect(west.longitude == -180)
        #expect(west == WeatherGridCell(latitude: 1, longitude: 180))

        for latitude in [-90.0, 90.0] {
            let pole = try #require(WeatherGridCell(latitude: latitude, longitude: 170))
            #expect(pole.latitude == latitude)
            #expect(pole.longitude == 0)
            #expect(pole == WeatherGridCell(latitude: latitude * 0.9999, longitude: -60))
        }
    }

    @Test func rejectsInvalidFixes() {
        #expect(WeatherGridCell(latitude: 90.01, longitude: 0) == nil)
        #expect(WeatherGridCell(latitude: 0, longitude: -180.01) == nil)
        #expect(WeatherGridCell(latitude: .nan, longitude: 0) == nil)
        #expect(WeatherGridCell(latitude: 0, longitude: .infinity) == nil)
    }
}
