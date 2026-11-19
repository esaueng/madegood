import Foundation

/// Current conditions and the next few hours at one place, from Open-Meteo's forecast
/// API. SI units: °C, m/s, metres, degrees true (wind *from*).
public struct WeatherNow: Sendable, Equatable, Codable {
    public struct Hour: Sendable, Equatable, Codable {
        /// Start of the hour, unix seconds.
        public var time: Double
        public var code: Int
        /// m/s; nil when the model has no value.
        public var gust: Double?
        /// Percent, 0–100.
        public var precipitationProbability: Double?

        public init(time: Double, code: Int, gust: Double? = nil, precipitationProbability: Double? = nil) {
            self.time = time
            self.code = code
            self.gust = gust
            self.precipitationProbability = precipitationProbability
        }
    }

    /// Unix seconds the conditions are valid for.
    public var time: Double
    /// Air temperature at 2 m, °C.
    public var temperature: Double
    /// WMO weather interpretation code (Open-Meteo `weather_code`).
    public var code: Int
    /// Mean 10 m wind, m/s.
    public var windSpeed: Double
    /// 10 m gusts, m/s.
    public var windGust: Double?
    /// Direction the wind blows from, degrees true.
    public var windFrom: Double
    /// Percent, 0–100.
    public var cloudCover: Double?
    /// Metres.
    public var visibility: Double?
    public var isDay: Bool
    /// Hours from the current one on, in time order.
    public var hours: [Hour]

    public init(
        time: Double, temperature: Double, code: Int, windSpeed: Double, windGust: Double? = nil,
        windFrom: Double, cloudCover: Double? = nil, visibility: Double? = nil, isDay: Bool = true,
        hours: [Hour] = []
    ) {
        self.time = time
        self.temperature = temperature
        self.code = code
        self.windSpeed = windSpeed
        self.windGust = windGust
        self.windFrom = windFrom
        self.cloudCover = cloudCover
        self.visibility = visibility
        self.isDay = isDay
        self.hours = hours
    }

    public enum ParseError: Error, Equatable { case badResponse }

    /// The variables a request asks for (`current=` and `hourly=`), matching `parse`.
    public static let currentVariables =
        "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,cloud_cover,visibility,is_day"
    public static let hourlyVariables = "weather_code,wind_gusts_10m,precipitation_probability"

    private struct Response: Decodable {
        struct Current: Decodable {
            var time: Double
            var temperature_2m: Double?
            var weather_code: Int?
            var wind_speed_10m: Double?
            var wind_direction_10m: Double?
            var wind_gusts_10m: Double?
            var cloud_cover: Double?
            var visibility: Double?
            var is_day: Int?
        }
        struct Hourly: Decodable {
            var time: [Double]
            var weather_code: [Int?]?
            var wind_gusts_10m: [Double?]?
            var precipitation_probability: [Double?]?
        }
        var current: Current
        var hourly: Hourly?
    }

    /// Reads an Open-Meteo forecast answer (`wind_speed_unit=ms`, `timeformat=unixtime`).
    public static func parse(_ data: Data) throws -> WeatherNow {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ParseError.badResponse
        }
        let current = response.current
        guard let temperature = current.temperature_2m, temperature.isFinite,
            let code = current.weather_code,
            let speed = current.wind_speed_10m, speed.isFinite, speed >= 0,
            let direction = current.wind_direction_10m, direction.isFinite
        else { throw ParseError.badResponse }

        var hours: [Hour] = []
        if let hourly = response.hourly {
            for (index, time) in hourly.time.enumerated() {
                guard let code = hourly.weather_code?[safe: index] ?? nil else { continue }
                let gust = (hourly.wind_gusts_10m?[safe: index] ?? nil).flatMap { $0.isFinite ? $0 : nil }
                let rain = (hourly.precipitation_probability?[safe: index] ?? nil).flatMap { $0.isFinite ? $0 : nil }
                hours.append(Hour(time: time, code: code, gust: gust, precipitationProbability: rain))
            }
        }
        return WeatherNow(
            time: current.time, temperature: temperature, code: code, windSpeed: speed,
            windGust: current.wind_gusts_10m.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            windFrom: direction.truncatingRemainder(dividingBy: 360) + (direction < 0 ? 360 : 0),
            cloudCover: current.cloud_cover, visibility: current.visibility, isDay: (current.is_day ?? 1) != 0,
            hours: hours.sorted { $0.time < $1.time })
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Outlook

/// What the conditions mean on the water: a sky to draw, how hard it blows, a headline
/// mood, a warning about the next few hours, and a rating per kind of craft. A guide for
/// planning only; it is not a marine forecast (AGENTS.md, "not for navigation").
public struct WaterOutlook: Sendable, Equatable {
    public enum Sky: String, Sendable, CaseIterable {
        case clear, partlyCloudy, overcast, fog, drizzle, rain, snow, thunderstorm
    }

    /// Beaufort-ish bands, by mean 10 m wind.
    public enum Wind: Int, Sendable, Comparable, CaseIterable {
        /// Under 1.5 m/s (3 kn): glassy.
        case calm
        /// 1.5–4 m/s (3–8 kn).
        case light
        /// 4–8 m/s (8–16 kn): a good sailing breeze.
        case moderate
        /// 8–11 m/s (16–21 kn).
        case fresh
        /// 11–14 m/s (21–27 kn).
        case strong
        /// 14 m/s (27 kn) and up.
        case gale

        public init(speed: Double) {
            switch speed {
            case ..<1.5: self = .calm
            case ..<4: self = .light
            case ..<8: self = .moderate
            case ..<11: self = .fresh
            case ..<14: self = .strong
            default: self = .gale
            }
        }

        public static func < (a: Wind, b: Wind) -> Bool { a.rawValue < b.rawValue }
    }

    /// The one thing to say first, most serious first.
    public enum Mood: String, Sendable, CaseIterable {
        case thunderstorm, stormComing, tooWindy, fog, snow, rain, drizzle
        /// A moderate or fresh breeze: a day for the wind sports.
        case sailingBreeze
        /// Calm: a day for paddling.
        case glassy
        case sunny, partlyCloudy, cloudy, clearNight
    }

    public enum Craft: String, Sendable, CaseIterable {
        /// Sailing and windsurfing.
        case wind
        /// Kayak, canoe and SUP.
        case paddle
        case power

        public init(_ sport: Sport) {
            switch sport {
            case .sailing, .windsurfing: self = .wind
            case .kayak, .canoe, .sup: self = .paddle
            case .motorboating: self = .power
            }
        }
    }

    public enum Rating: Int, Sendable, Comparable, CaseIterable {
        case stayAshore, poor, fair, good, great
        public static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Warning: Sendable, Equatable {
        /// Thunder expected in the hour starting at `at` (unix seconds).
        case thunder(at: Double)
        /// Gusts up to `speed` m/s by the hour starting at `at`.
        case gusts(at: Double, speed: Double)
        /// Rain likely from the hour starting at `at`.
        case rain(at: Double)
    }

    public var sky: Sky
    public var wind: Wind
    public var mood: Mood
    public var warning: Warning?
    public var ratings: [Craft: Rating]

    /// Gusts at or over this are too windy for anyone small, whatever the mean (m/s, 35 kn).
    public static let dangerousGust = 18.0
    /// How far ahead a warning looks, seconds.
    public static let lookahead: Double = 3 * 3_600

    public init(_ weather: WeatherNow) {
        let sky = Self.sky(code: weather.code, visibility: weather.visibility, cloudCover: weather.cloudCover)
        let wind = Wind(speed: weather.windSpeed)
        let gust = max(weather.windGust ?? 0, weather.windSpeed)
        let warning = Self.warning(weather, sky: sky)
        self.sky = sky
        self.wind = wind
        self.warning = warning

        let tooWindy = wind >= .gale || gust >= Self.dangerousGust
        let mood: Mood
        if sky == .thunderstorm {
            mood = .thunderstorm
        } else if case .thunder = warning {
            mood = .stormComing
        } else if tooWindy {
            mood = .tooWindy
        } else {
            switch sky {
            case .fog: mood = .fog
            case .snow: mood = .snow
            case .rain: mood = .rain
            case .drizzle: mood = .drizzle
            case .clear, .partlyCloudy, .overcast, .thunderstorm:
                switch wind {
                case .moderate, .fresh: mood = .sailingBreeze
                case .calm: mood = .glassy
                case .strong, .gale: mood = .tooWindy
                case .light:
                    switch sky {
                    case .overcast: mood = .cloudy
                    case .partlyCloudy: mood = weather.isDay ? .partlyCloudy : .clearNight
                    default: mood = weather.isDay ? .sunny : .clearNight
                    }
                }
            }
        }
        self.mood = mood

        var ratings: [Craft: Rating] = [:]
        for craft in Craft.allCases {
            var rating = Self.rating(craft, wind: weather.windSpeed, gust: gust)
            if sky == .thunderstorm || mood == .stormComing { rating = .stayAshore }
            if sky == .fog { rating = min(rating, .poor) }
            if [.rain, .snow].contains(sky) { rating = min(rating, .fair) }
            ratings[craft] = rating
        }
        self.ratings = ratings
    }

    /// The sky for a WMO code; fog also when visibility is under 1 km.
    public static func sky(code: Int, visibility: Double? = nil, cloudCover: Double? = nil) -> Sky {
        switch code {
        case 95...99: return .thunderstorm
        case 71...77, 85, 86: return .snow
        case 61...67, 80...82: return .rain
        case 51...57: return .drizzle
        case 45, 48: return .fog
        default: break
        }
        if let visibility, visibility < 1_000 { return .fog }
        switch code {
        case 0: return (cloudCover ?? 0) > 40 ? .partlyCloudy : .clear
        case 1, 2: return .partlyCloudy
        case 3: return .overcast
        default: return (cloudCover ?? 0) > 70 ? .overcast : .partlyCloudy
        }
    }

    /// Mean wind and gusts in m/s; the band edges are where each kind of craft starts or
    /// stops having fun, not safety limits.
    public static func rating(_ craft: Craft, wind: Double, gust: Double) -> Rating {
        if gust >= dangerousGust { return .stayAshore }
        switch craft {
        case .wind:
            switch wind {
            case ..<1.5: return .poor
            case ..<4: return .fair
            case ..<9: return .great
            case ..<11: return .good
            case ..<14: return .fair
            default: return .stayAshore
            }
        case .paddle:
            switch max(wind, gust * 0.7) {
            case ..<3: return .great
            case ..<5.5: return .good
            case ..<8: return .fair
            case ..<11: return .poor
            default: return .stayAshore
            }
        case .power:
            switch max(wind, gust * 0.7) {
            case ..<6: return .great
            case ..<9: return .good
            case ..<12: return .fair
            case ..<15: return .poor
            default: return .stayAshore
            }
        }
    }

    /// The first thing worth knowing in the next three hours, if the current hour
    /// doesn't already show it: thunder, then gusts building to too windy, then rain.
    static func warning(_ weather: WeatherNow, sky: Sky) -> Warning? {
        let coming = weather.hours.filter {
            $0.time + 3_600 > weather.time && $0.time <= weather.time + lookahead
        }
        if sky != .thunderstorm, let hour = coming.first(where: { Self.sky(code: $0.code) == .thunderstorm }) {
            return .thunder(at: max(hour.time, weather.time))
        }
        let gustNow = max(weather.windGust ?? 0, weather.windSpeed)
        if gustNow < dangerousGust,
            let hour = coming.first(where: { ($0.gust ?? 0) >= dangerousGust }), let gust = hour.gust
        {
            return .gusts(at: max(hour.time, weather.time), speed: coming.compactMap(\.gust).max() ?? gust)
        }
        let wet: Set<Sky> = [.rain, .drizzle, .snow, .thunderstorm]
        if !wet.contains(sky),
            let hour = coming.first(where: { ($0.precipitationProbability ?? 0) >= 60 || wet.contains(Self.sky(code: $0.code)) })
        {
            return .rain(at: max(hour.time, weather.time))
        }
        return nil
    }
}
