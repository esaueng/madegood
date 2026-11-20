import CoreLocation
import Foundation
import WaterKit
import WeatherKit

/// The only WeatherKit adapter, compiled into the iPhone app. CLLocation is built
/// here from the grid cell; there is no overload that accepts a GPS fix.
struct AppleWeatherProvider: PhoneWeatherProviding {
    func current(at cell: WeatherGridCell) async throws -> WeatherNow {
        let (current, hourly) = try await WeatherService.shared.weather(
            for: location(cell), including: .current, .hourly)
        try await AppleWeatherAttribution.prepare()
        let wind = Self.windHour(date: current.date, direction: current.wind.direction, speed: current.wind.speed)
        return try Self.conditions(
            temperature: current.temperature, condition: current.condition, wind: wind, gust: current.wind.gust,
            cloudCover: current.cloudCover, visibility: current.visibility, isDaylight: current.isDaylight,
            hours: hourly.prefix(6).map {
                Self.hour(
                    date: $0.date, condition: $0.condition, gust: $0.wind.gust, precipitation: $0.precipitationChance)
            })
    }

    func hourlyWind(at cell: WeatherGridCell, during interval: DateInterval) async throws -> [WeatherWindHour] {
        let forecast = try await WeatherService.shared.weather(
            for: location(cell), including: .hourly(startDate: interval.start, endDate: interval.end))
        if !forecast.isEmpty { try await AppleWeatherAttribution.prepare() }
        return forecast.map { Self.windHour(date: $0.date, direction: $0.wind.direction, speed: $0.wind.speed) }
    }

    private func location(_ cell: WeatherGridCell) -> CLLocation {
        CLLocation(latitude: cell.latitude, longitude: cell.longitude)
    }

    static func conditions(
        temperature: Measurement<UnitTemperature>, condition: WeatherCondition, wind: WeatherWindHour,
        gust: Measurement<UnitSpeed>?, cloudCover: Double, visibility: Measurement<UnitLength>,
        isDaylight: Bool, hours: [WeatherNow.Hour]
    ) throws -> WeatherNow {
        let celsius = temperature.converted(to: .celsius).value
        guard celsius.isFinite, wind.speed.isFinite, wind.speed >= 0, wind.fromDegrees.isFinite else {
            throw PhoneWeather.Failure.unavailable
        }
        return WeatherNow(
            time: wind.date.timeIntervalSince1970, temperature: celsius,
            code: code(for: condition), windSpeed: wind.speed, windGust: gust?.converted(to: .metersPerSecond).value,
            windFrom: wind.fromDegrees, cloudCover: 100 * cloudCover,
            visibility: visibility.converted(to: .meters).value,
            isDay: isDaylight, hours: hours)
    }

    static func hour(
        date: Date, condition: WeatherCondition, gust: Measurement<UnitSpeed>?, precipitation: Double
    ) -> WeatherNow.Hour {
        WeatherNow.Hour(
            time: date.timeIntervalSince1970, code: code(for: condition),
            gust: gust?.converted(to: .metersPerSecond).value, precipitationProbability: 100 * precipitation)
    }

    static func windHour(
        date: Date, direction: Measurement<UnitAngle>, speed: Measurement<UnitSpeed>
    ) -> WeatherWindHour {
        // Apple defines direction as where the wind comes FROM; the app uses the same convention.
        WeatherWindHour(
            date: date, fromDegrees: direction.converted(to: .degrees).value,
            speed: speed.converted(to: .metersPerSecond).value)
    }

    /// Approximate WeatherKit's conditions with the WMO codes used by WaterOutlook.
    private static func code(for condition: WeatherCondition) -> Int {
        switch condition {
        case .clear, .hot, .frigid, .breezy, .windy: 0
        case .mostlyClear: 1
        case .partlyCloudy, .mostlyCloudy: 2
        case .cloudy: 3
        case .foggy, .haze, .smoky, .blowingDust: 45
        case .drizzle: 53
        case .freezingDrizzle: 57
        case .rain, .sunShowers: 63
        case .heavyRain, .hurricane, .tropicalStorm: 65
        case .freezingRain: 67
        case .flurries, .sunFlurries: 71
        case .snow, .blowingSnow, .sleet, .wintryMix: 73
        case .heavySnow, .blizzard: 75
        case .hail: 86
        case .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms: 95
        @unknown default: 3
        }
    }
}
