import CoreLocation
import Foundation
import Observation
import WaterKit

/// Current conditions where the iPhone is, for the start screen. Off until the user turns
/// it on (the start screen asks once; Settings > Weather after that).
///
/// What is sent: the phone's position rounded to 0.1° (about 10 km) and the variables
/// asked for, to Open-Meteo, with no key, cookies or identifiers. The position itself is
/// never stored; the last answer is, so the card draws at once on the next launch.
@MainActor
@Observable
final class LocalWeather {
    static let shared = LocalWeather()

    enum Status: Equatable {
        /// The user hasn't chosen yet, or turned it off.
        case off
        case loading
        case ready
        /// Location access is denied or restricted.
        case noLocation
        case failed
    }

    private(set) var status: Status = .off
    private(set) var weather: WeatherNow?
    private(set) var fetchedAt: Date?
    /// nil until the user chooses.
    private(set) var choice: Bool?

    /// Answers older than this are refetched when the screen shows.
    static let refreshAfter: TimeInterval = 15 * 60
    /// Answers older than this are not shown.
    static let staleAfter: TimeInterval = 3 * 3_600

    private let location = OneShotLocation()
    private var refreshing = false
    private let defaults = UserDefaults.standard
    #if DEBUG
        private var isDemo = false
    #endif

    var isEnabled: Bool { choice == true }

    /// The conditions to show, if fresh enough.
    var current: WeatherNow? {
        guard let weather, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.staleAfter else { return nil }
        return weather
    }

    private struct Saved: Codable {
        var weather: WeatherNow
        var fetchedAt: Date
    }

    private init() {
        choice = defaults.object(forKey: UserSettings.Key.localWeather) as? Bool
        if let data = defaults.data(forKey: UserSettings.Key.lastWeather),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        {
            weather = saved.weather
            fetchedAt = saved.fetchedAt
        }
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-demoWeather"), index + 1 < arguments.count {
                isDemo = true
                choice = true
                weather = DemoWeather.sample(arguments[index + 1], now: .now)
                fetchedAt = .now
                status = .ready
                return
            }
            // UI tests never reach the network or prompt for location unless asked.
            if arguments.contains(DemoFeed.launchArgument) {
                isDemo = true
                choice = nil
                weather = nil
                fetchedAt = nil
            }
        #endif
        status = isEnabled ? (current == nil ? .loading : .ready) : .off
    }

    /// Turns local conditions on or off. On asks for location if it hasn't been asked.
    func setEnabled(_ enabled: Bool) {
        choice = enabled
        defaults.set(enabled, forKey: UserSettings.Key.localWeather)
        if enabled {
            Task { await refresh(force: true) }
        } else {
            status = .off
        }
    }

    /// Fetches new conditions unless the last ones are recent (or `force`).
    func refresh(force: Bool = false) async {
        guard isEnabled, !refreshing else { return }
        #if DEBUG
            if isDemo {
                status = weather == nil ? .failed : .ready
                return
            }
        #endif
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.refreshAfter, weather != nil {
            status = .ready
            return
        }
        refreshing = true
        defer { refreshing = false }
        if current == nil { status = .loading }

        switch await location.requestAuthorization() {
        case .denied, .restricted:
            status = .noLocation
            return
        default: break
        }
        do {
            let position = try await location.position()
            let weather = try await OpenMeteo.fetchCurrent(latitude: position.latitude, longitude: position.longitude)
            self.weather = weather
            fetchedAt = .now
            if let data = try? JSONEncoder().encode(Saved(weather: weather, fetchedAt: .now)) {
                defaults.set(data, forKey: UserSettings.Key.lastWeather)
            }
            status = .ready
        } catch OneShotLocation.Failure.denied {
            status = .noLocation
        } catch {
            status = current == nil ? .failed : .ready
        }
    }
}

// MARK: - Request

extension OpenMeteo {
    /// Current conditions are asked for at this resolution: the forecast grid is a few km,
    /// so 0.1° (about 10 km) loses little and keeps the exact position on the phone.
    static let currentStep = 0.1

    static func roundCurrent(_ degrees: Double) -> Double {
        (degrees / currentStep).rounded() * currentStep
    }

    /// Current conditions and the next six hours at the rounded position.
    static func currentRequest(latitude: Double, longitude: Double) -> URLRequest {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", roundCurrent(latitude))),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", roundCurrent(longitude))),
            URLQueryItem(name: "current", value: WeatherNow.currentVariables),
            URLQueryItem(name: "hourly", value: WeatherNow.hourlyVariables),
            URLQueryItem(name: "forecast_hours", value: "6"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        return request
    }

    static func fetchCurrent(latitude: Double, longitude: Double) async throws -> WeatherNow {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: currentRequest(latitude: latitude, longitude: longitude))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return try WeatherNow.parse(data)
    }
}

// MARK: - Location

/// One coarse position on request, asking for When In Use access first if needed.
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    enum Failure: Error { case denied, unavailable }

    struct Position: Sendable {
        var latitude: Double
        var longitude: Double
    }

    private let manager = CLLocationManager()
    private var authorization: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var waiting: [CheckedContinuation<Position, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestAuthorization() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        return await withCheckedContinuation { continuation in
            authorization.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func position() async throws -> Position {
        if let location = manager.location, -location.timestamp.timeIntervalSinceNow < 600 {
            return Position(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { manager.requestLocation() }
        }
    }

    private func finish(_ result: Result<Position, Error>) {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != .notDetermined else { return }
            let pending = authorization
            authorization = []
            for continuation in pending { continuation.resume(returning: status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let position = Position(latitude: coordinate.latitude, longitude: coordinate.longitude)
        MainActor.assumeIsolated { finish(.success(position)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated { finish(.failure(denied ? Failure.denied : Failure.unavailable)) }
    }
}

// MARK: - Demo

#if DEBUG
    /// Canned conditions for UI tests and screenshots: launch with `-demoWeather <mood>`
    /// (a `WaterOutlook.Mood` raw value). No network, no location prompt.
    enum DemoWeather {
        static func sample(_ mood: String, now: Date) -> WeatherNow? {
            let t = now.timeIntervalSince1970
            let hour = (t / 3_600).rounded(.down) * 3_600
            func hours(_ codes: [Int], gusts: [Double] = [], rain: [Double] = []) -> [WeatherNow.Hour] {
                codes.enumerated().map { index, code in
                    WeatherNow.Hour(
                        time: hour + Double(index) * 3_600, code: code,
                        gust: index < gusts.count ? gusts[index] : nil,
                        precipitationProbability: index < rain.count ? rain[index] : nil)
                }
            }
            func sample(
                _ code: Int, _ temperature: Double, wind: Double, gust: Double, from: Double = 235, cloud: Double = 20,
                visibility: Double = 24_000, day: Bool = true, next: [WeatherNow.Hour] = []
            ) -> WeatherNow {
                WeatherNow(
                    time: t, temperature: temperature, code: code, windSpeed: wind, windGust: gust, windFrom: from,
                    cloudCover: cloud, visibility: visibility, isDay: day, hours: next)
            }
            switch WaterOutlook.Mood(rawValue: mood) {
            case .thunderstorm: return sample(95, 19, wind: 7, gust: 15, cloud: 100, visibility: 6_000)
            case .stormComing:
                return sample(2, 24, wind: 5, gust: 9, cloud: 45, next: hours([2, 3, 95, 95], gusts: [9, 12, 20, 22]))
            case .tooWindy: return sample(2, 13, wind: 13.5, gust: 21, from: 250, cloud: 40)
            case .fog: return sample(45, 9, wind: 1.2, gust: 2.5, cloud: 100, visibility: 300)
            case .snow: return sample(73, -1, wind: 3, gust: 6, cloud: 100, visibility: 3_000)
            case .rain: return sample(63, 11, wind: 5, gust: 10, cloud: 100, visibility: 8_000)
            case .drizzle: return sample(53, 12, wind: 3, gust: 6, cloud: 95)
            case .sailingBreeze: return sample(1, 21, wind: 6.5, gust: 9.5, cloud: 25)
            case .glassy: return sample(0, 23, wind: 0.8, gust: 1.6, cloud: 5)
            case .sunny: return sample(0, 25, wind: 2.8, gust: 4.5, cloud: 5, next: hours([0, 1, 3], rain: [0, 10, 65]))
            case .partlyCloudy: return sample(2, 18, wind: 3, gust: 5, cloud: 50)
            case .cloudy: return sample(3, 14, wind: 2.6, gust: 4, cloud: 100)
            case .clearNight: return sample(0, 12, wind: 2.2, gust: 3.5, cloud: 5, day: false)
            case nil: return nil
            }
        }
    }
#endif
