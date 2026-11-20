import CoreLocation
import Foundation
import Observation
import WaterKit

/// Current conditions where the iPhone is, for the start screen. Off until the user turns
/// it on (the start screen asks once; Settings > Weather after that).
///
/// The iPhone sends Apple Weather a 0.1° grid cell. The last answer is saved without
/// coordinates so the card draws at once on the next launch.
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
    private var conditions: PhoneWeather.Conditions?
    var expiresAt: Date? {
        guard let conditions, conditions.isFresh(at: .now) else { return nil }
        return AppleWeatherAttribution.displayExpiry(weatherExpiresAt: conditions.expiresAt)
    }
    /// nil until the user chooses.
    private(set) var choice: Bool?

    private let location = OneShotLocation()
    private var refreshing = false
    private let defaults = UserDefaults.standard

    var isEnabled: Bool { choice == true }

    var current: WeatherNow? {
        expiresAt == nil ? nil : conditions?.weather
    }

    private init() {
        choice = defaults.object(forKey: UserSettings.Key.localWeather) as? Bool
        conditions = PhoneWeather.Conditions.load(from: .shared, now: .now)
        #if DEBUG
            if DemoWeatherProvider.isEnabled {
                choice = DemoWeatherProvider.mood == nil ? nil : true
                conditions = nil
            }
        #endif
        status = isEnabled ? (current == nil ? .loading : .ready) : .off
    }

    func prune() {
        let now = Date.now
        if let conditions, !conditions.isFresh(at: now) { self.conditions = nil }
        _ = PhoneWeather.Conditions.load(from: .shared, now: now)
    }

    /// Turns local conditions on or off. On asks for location if it hasn't been asked.
    func setEnabled(_ enabled: Bool) {
        choice = enabled
        #if DEBUG
            if !DemoWeatherProvider.isEnabled { defaults.set(enabled, forKey: UserSettings.Key.localWeather) }
        #else
            defaults.set(enabled, forKey: UserSettings.Key.localWeather)
        #endif
        if enabled {
            Task { await refresh(force: true) }
        } else {
            status = .off
        }
    }

    /// Fetches new conditions unless the last ones are recent (or `force`).
    func refresh(force: Bool = false) async {
        guard isEnabled, !refreshing else { return }
        prune()
        if !force, current != nil {
            status = .ready
            return
        }
        refreshing = true
        defer { refreshing = false }
        if current == nil { status = .loading }

        do {
            let cell = try await weatherCell()
            // The user may have turned this off while the fix was pending.
            guard isEnabled else { return }
            // Near the end of attribution's lifetime a cached WeatherKit answer may
            // still be fresh even though the marks need to be downloaded again.
            let answer = try await PhoneWeather.shared.current(at: cell, force: force)
            if AppleWeatherAttribution.available == nil { try await AppleWeatherAttribution.prepare() }
            guard isEnabled else { return }
            conditions = answer
            #if DEBUG
                if DemoWeatherProvider.isEnabled {
                    status = .ready
                    return
                }
            #endif
            WeatherDiskCache.shared.write(answer, for: .conditions)
            status = .ready
        } catch OneShotLocation.Failure.denied {
            if isEnabled { status = .noLocation }
        } catch {
            if isEnabled { status = current == nil ? .failed : .ready }
        }
    }

    private func weatherCell() async throws -> WeatherGridCell {
        #if DEBUG
            if DemoWeatherProvider.isEnabled {
                return WeatherGridCell(latitude: 0, longitude: 0)!
            }
        #endif
        switch await location.requestAuthorization() {
        case .denied, .restricted: throw OneShotLocation.Failure.denied
        default: break
        }
        let position = try await location.position()
        guard let cell = WeatherGridCell(latitude: position.latitude, longitude: position.longitude) else {
            throw OneShotLocation.Failure.unavailable
        }
        return cell
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

    /// A fix that hasn't come by then fails, so a silent Core Location never wedges refresh.
    static let timeout: Duration = .seconds(20)

    private let manager = CLLocationManager()
    private var request = 0
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
            guard waiting.count == 1 else { return }
            request += 1
            let id = request
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard let self, self.request == id, !self.waiting.isEmpty else { return }
                self.manager.stopUpdatingLocation()
                self.finish(.failure(Failure.unavailable))
            }
        }
    }

    private func finish(_ result: Result<Position, Error>) {
        request += 1  // a late timeout for this request does nothing
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
    struct DemoWeatherProvider: PhoneWeatherProviding {
        static var isEnabled: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return DemoFeed.isEnabled || mood != nil
                || arguments.contains(DemoHistory.launchArgument) || arguments.contains("-demoMoments")
        }

        static var mood: String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-demoWeather"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        func current(at cell: WeatherGridCell) async throws -> WeatherNow {
            guard let weather = Self.sample(Self.mood ?? "sunny", now: .now) else {
                throw PhoneWeather.Failure.unavailable
            }
            return weather
        }

        func hourlyWind(at cell: WeatherGridCell, during interval: DateInterval) async throws -> [WeatherWindHour] {
            try await Task.sleep(for: .milliseconds(300))
            if ProcessInfo.processInfo.arguments.contains("-demoWeatherOffline") {
                throw URLError(.notConnectedToInternet)
            }
            return stride(from: interval.start.timeIntervalSince1970, to: interval.end.timeIntervalSince1970, by: 3_600)
                .map { WeatherWindHour(date: Date(timeIntervalSince1970: $0), fromDegrees: 10, speed: 6) }
        }

        private static func sample(_ mood: String, now: Date) -> WeatherNow? {
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
            case .sunny:
                return sample(0, 25, wind: 2.8, gust: 4.5, cloud: 5, next: hours([0, 1, 3], rain: [0, 10, 65]))
            case .partlyCloudy: return sample(2, 18, wind: 3, gust: 5, cloud: 50)
            case .cloudy: return sample(3, 14, wind: 2.6, gust: 4, cloud: 100)
            case .clearNight: return sample(0, 12, wind: 2.2, gust: 3.5, cloud: 5, day: false)
            case nil: return nil
            }
        }
    }
#endif
