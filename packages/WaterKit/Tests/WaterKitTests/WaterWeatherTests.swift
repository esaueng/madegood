import Foundation
import Testing

@testable import WaterKit

@Suite struct WaterWeatherTests {
    private let now = 1_800_000_000.0
    private var hour: Double { (now / 3_600).rounded(.down) * 3_600 }

    private func weather(
        code: Int = 1, wind: Double = 3, gust: Double? = nil, visibility: Double? = 20_000,
        isDay: Bool = true, hours: [WeatherNow.Hour] = []
    ) -> WeatherNow {
        WeatherNow(
            time: now, temperature: 15, code: code, windSpeed: wind, windGust: gust, windFrom: 225,
            cloudCover: 20, visibility: visibility, isDay: isDay, hours: hours)
    }

    @Test func skyFollowsTheWeatherCode() {
        #expect(WaterOutlook.sky(code: 0) == .clear)
        #expect(WaterOutlook.sky(code: 2) == .partlyCloudy)
        #expect(WaterOutlook.sky(code: 3) == .overcast)
        #expect(WaterOutlook.sky(code: 45) == .fog)
        #expect(WaterOutlook.sky(code: 3, visibility: 600) == .fog)
        #expect(WaterOutlook.sky(code: 53) == .drizzle)
        #expect(WaterOutlook.sky(code: 63) == .rain)
        #expect(WaterOutlook.sky(code: 81) == .rain)
        #expect(WaterOutlook.sky(code: 73) == .snow)
        #expect(WaterOutlook.sky(code: 96) == .thunderstorm)
        // Thunder wins over poor visibility.
        #expect(WaterOutlook.sky(code: 95, visibility: 200) == .thunderstorm)
    }

    @Test func windBands() {
        #expect(WaterOutlook.Wind(speed: 0.5) == .calm)
        #expect(WaterOutlook.Wind(speed: 3) == .light)
        #expect(WaterOutlook.Wind(speed: 6) == .moderate)
        #expect(WaterOutlook.Wind(speed: 9) == .fresh)
        #expect(WaterOutlook.Wind(speed: 12) == .strong)
        #expect(WaterOutlook.Wind(speed: 20) == .gale)
    }

    @Test func aGoodBreezeIsASailingDay() {
        let outlook = WaterOutlook(weather(code: 1, wind: 6, gust: 9))
        #expect(outlook.mood == .sailingBreeze)
        #expect(outlook.ratings[.wind] == .great)
        #expect(outlook.ratings[.paddle] == .fair)
        #expect(outlook.ratings[.power] == .good)
        #expect(outlook.warning == nil)
    }

    @Test func calmIsGlassyForPaddlers() {
        let outlook = WaterOutlook(weather(code: 0, wind: 0.8, gust: 1.5))
        #expect(outlook.mood == .glassy)
        #expect(outlook.ratings[.paddle] == .great)
        #expect(outlook.ratings[.wind] == .poor)
    }

    @Test func lightAirsShowTheSky() {
        #expect(WaterOutlook(weather(code: 0, wind: 2.5)).mood == .sunny)
        #expect(WaterOutlook(weather(code: 0, wind: 2.5, isDay: false)).mood == .clearNight)
        #expect(WaterOutlook(weather(code: 2, wind: 2.5)).mood == .partlyCloudy)
        #expect(WaterOutlook(weather(code: 3, wind: 2.5)).mood == .cloudy)
    }

    @Test func strongGustsAreTooWindyForEveryone() {
        let outlook = WaterOutlook(weather(code: 1, wind: 10, gust: 19))
        #expect(outlook.mood == .tooWindy)
        #expect(outlook.ratings.values.allSatisfy { $0 == .stayAshore })
        #expect(WaterOutlook(weather(code: 1, wind: 12, gust: 15)).mood == .tooWindy)
    }

    @Test func thunderNowOrSoonKeepsEveryoneAshore() {
        let storm = WaterOutlook(weather(code: 95, wind: 5))
        #expect(storm.mood == .thunderstorm)
        #expect(storm.ratings.values.allSatisfy { $0 == .stayAshore })
        #expect(storm.warning == nil)

        let coming = WaterOutlook(
            weather(code: 1, wind: 5, hours: [.init(time: hour, code: 2), .init(time: hour + 7_200, code: 95)]))
        #expect(coming.mood == .stormComing)
        // The warning starts at the forecast hour.
        #expect(coming.warning == .thunder(at: hour + 7_200))
        #expect(coming.ratings.values.allSatisfy { $0 == .stayAshore })

        // Thunder beyond three hours isn't a warning yet.
        let later = WaterOutlook(weather(code: 1, wind: 5, hours: [.init(time: hour + 5 * 3_600, code: 95)]))
        #expect(later.mood == .sailingBreeze)
        #expect(later.warning == nil)
    }

    @Test func warnsOfBuildingGustsThenRain() {
        let gusts = WaterOutlook(
            weather(
                code: 1, wind: 5, gust: 8,
                hours: [
                    .init(time: hour, code: 1, gust: 8), .init(time: hour + 3_600, code: 1, gust: 19),
                    .init(time: hour + 7_200, code: 1, gust: 22),
                ]))
        #expect(gusts.warning == .gusts(at: hour + 3_600, speed: 22))
        #expect(gusts.mood == .sailingBreeze)

        let rain = WaterOutlook(
            weather(code: 1, wind: 3, hours: [.init(time: hour + 3_600, code: 3, precipitationProbability: 70)]))
        #expect(rain.warning == .rain(at: hour + 3_600))
        // Already raining: nothing to warn of.
        let wet = WaterOutlook(weather(code: 63, wind: 3, hours: [.init(time: hour + 3_600, code: 63)]))
        #expect(wet.warning == nil)
        #expect(wet.mood == .rain)
        #expect(wet.ratings[.paddle] == .fair)
    }

    /// At 14:05 the 14:00 gust is already happening and the 13:00 storm has passed.
    @Test func hourlyValuesStartAtTheirTimestamp() {
        let fivepast = WeatherNow(
            time: hour + 300, temperature: 15, code: 1, windSpeed: 5, windGust: 8, windFrom: 225,
            hours: [
                .init(time: hour - 3_600, code: 95, gust: 25, precipitationProbability: 90),
                .init(time: hour, code: 1, gust: 20),
            ])
        #expect(WaterOutlook(fivepast).warning == .gusts(at: hour + 300, speed: 20))

        var activeStorm = fivepast
        activeStorm.hours[1].code = 95
        #expect(WaterOutlook(activeStorm).warning == .thunder(at: hour + 300))
    }

    @Test func fogAndSnowMoods() {
        let fog = WaterOutlook(weather(code: 45, wind: 1))
        #expect(fog.mood == .fog)
        #expect(fog.ratings.values.allSatisfy { $0 <= .poor })
        #expect(WaterOutlook(weather(code: 3, wind: 2, visibility: 400)).mood == .fog)
        #expect(WaterOutlook(weather(code: 75, wind: 2)).mood == .snow)
        #expect(WaterOutlook(weather(code: 51, wind: 2)).mood == .drizzle)
    }

    @Test func craftForEachSport() {
        #expect(WaterOutlook.Craft(.sailing) == .wind)
        #expect(WaterOutlook.Craft(.windsurfing) == .wind)
        #expect(WaterOutlook.Craft(.sup) == .paddle)
        #expect(WaterOutlook.Craft(.motorboating) == .power)
    }
}
