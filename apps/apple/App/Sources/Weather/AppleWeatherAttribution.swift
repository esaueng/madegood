import SwiftUI
import WeatherKit

/// Stores the two official marks with the legal URL so cached weather has attribution offline.
@MainActor
struct AppleWeatherAttribution: Codable {
    let darkMark: Data
    let lightMark: Data
    let legalPageURL: URL

    private static let key = "weather.appleAttribution"
    private static var pending: Task<Void, Error>?
    private static var cached: Self? = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()

    static var available: Self? {
        #if DEBUG
            if DemoWeatherProvider.isEnabled { return nil }
        #endif
        return cached
    }

    static func prepare() async throws {
        guard cached == nil else { return }
        if let pending { return try await pending.value }

        let task = Task {
            defer { pending = nil }
            let attribution = try await WeatherService.shared.attribution
            async let dark = mark(at: attribution.combinedMarkDarkURL)
            async let light = mark(at: attribution.combinedMarkLightURL)
            let value = try await Self(darkMark: dark, lightMark: light, legalPageURL: attribution.legalPageURL)
            cached = value
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
        }
        pending = task
        try await task.value
    }

    private static func mark(at url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else {
            throw PhoneWeather.Failure.unavailable
        }
        return data
    }
}

struct AppleWeatherAttributionLink: View {
    let attribution: AppleWeatherAttribution
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let data = colorScheme == .dark ? attribution.darkMark : attribution.lightMark
        Link(destination: attribution.legalPageURL) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 12)
            }
        }
        .accessibilityLabel("Apple Weather data sources")
    }
}
