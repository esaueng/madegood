import Foundation
import SwiftUI
import WaterKit

/// Words for the start screen's conditions card. Values stay SI until here.
struct WeatherText {
    let weather: WeatherNow
    let outlook: WaterOutlook
    let speedUnit: SpeedUnit

    init(_ weather: WeatherNow, speedUnit: SpeedUnit) {
        self.weather = weather
        outlook = WaterOutlook(weather)
        self.speedUnit = speedUnit
    }

    private var gust: Double { max(weather.windGust ?? 0, weather.windSpeed) }

    var headline: String {
        switch outlook.mood {
        case .thunderstorm: "Thunderstorm. Stay ashore"
        case .stormComing: "Storm on the way"
        case .tooWindy: "Too windy out there"
        case .fog: "Foggy. Keep a lookout"
        case .snow: "Snowing. Wrap up warm"
        case .rain: "Rainy on the water"
        case .drizzle: "Drizzly and grey"
        case .sailingBreeze: outlook.wind == .fresh ? "Fresh breeze. Reef early" : "Good sailing breeze"
        case .glassy: "Glassy. Perfect for paddling"
        case .sunny: "Sunny, light breeze"
        case .partlyCloudy: "Sun and clouds, light breeze"
        case .cloudy: "Grey skies, light breeze"
        case .clearNight: "Clear night, light breeze"
        }
    }

    var temperature: String {
        Measurement(value: weather.temperature, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// Whole numbers: a model's wind is no better than that.
    private func speed(_ metresPerSecond: Double, symbol: Bool = true) -> String {
        let value = "\(Int(speedUnit.fromSI(metresPerSecond).rounded()))"
        return symbol ? "\(value) \(speedUnit.symbol)" : value
    }

    /// "12 kn SW · gusts 18"
    var wind: String {
        let base = outlook.wind == .calm ? "Calm" : "\(speed(weather.windSpeed)) \(Self.compass(weather.windFrom))"
        guard gust >= weather.windSpeed + 1.5 else { return base }
        return "\(base) · gusts \(speed(gust, symbol: false))"
    }

    var warning: String? {
        switch outlook.warning {
        case .thunder(let at)?: "Thunder likely \(Self.when(at, now: weather.time))"
        case .gusts(let at, let speed)?: "Gusts to \(self.speed(speed)) \(Self.when(at, now: weather.time))"
        case .rain(let at)?: "Rain likely \(Self.when(at, now: weather.time))"
        case nil: nil
        }
    }

    var warningSymbol: String {
        switch outlook.warning {
        case .thunder?: "cloud.bolt.fill"
        case .gusts?: "wind"
        case .rain?, nil: "cloud.rain.fill"
        }
    }

    static func ratingWord(_ rating: WaterOutlook.Rating) -> String {
        switch rating {
        case .great: "Great"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        case .stayAshore: "Stay ashore"
        }
    }

    static func ratingColor(_ rating: WaterOutlook.Rating) -> Color {
        switch rating {
        case .great: Color(red: 0.45, green: 0.86, blue: 0.55)
        case .good: Color(red: 0.55, green: 0.85, blue: 0.85)
        case .fair: Color(red: 0.98, green: 0.82, blue: 0.35)
        case .poor: Color(red: 0.98, green: 0.6, blue: 0.3)
        case .stayAshore: Color(red: 1, green: 0.42, blue: 0.4)
        }
    }

    static func craftName(_ craft: WaterOutlook.Craft) -> String {
        switch craft {
        case .wind: "Sailing"
        case .paddle: "Paddling"
        case .power: "Motor"
        }
    }

    /// The sport whose icon stands for a craft, preferring ones on the start screen.
    static func icon(for craft: WaterOutlook.Craft, among sports: [Sport]) -> Sport {
        sports.first { WaterOutlook.Craft($0) == craft }
            ?? Sport.allCases.first { WaterOutlook.Craft($0) == craft }!
    }

    /// Eight-point compass name for a direction in degrees true.
    static func compass(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalized / 45).rounded()) % 8]
    }

    /// "soon" within the hour, otherwise "by 3 PM".
    static func when(_ time: Double, now: Double) -> String {
        guard time - now > 45 * 60 else { return "soon" }
        let date = Date(timeIntervalSince1970: time)
        return "by \(date.formatted(date: .omitted, time: .shortened))"
    }

    var accessibilityLabel: String {
        var parts = [headline, temperature, wind]
        if let warning { parts.append(warning) }
        return parts.joined(separator: ". ")
    }
}
