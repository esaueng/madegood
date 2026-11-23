import SwiftUI
import WeatherKit

/// Attribution is cached to avoid downloading the same marks for every WeatherKit call.
/// Refresh after one day and expire after two, so freshly fetched weather can keep
/// its attribution through the full 24-hour historical wind cache lifetime.
@MainActor
struct AppleWeatherAttribution: Codable {
    let darkMark: Data
    let lightMark: Data
    let legalPageURL: URL
    let fetchedAt: Date

    private static let refreshAfter: TimeInterval = 24 * 3_600
    private static let lifetime: TimeInterval = 2 * refreshAfter
    var expiresAt: Date { fetchedAt + Self.lifetime }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private static var pending: Task<Void, Error>?
    private static var cached = WeatherDiskCache.shared.read(Self.self, for: .attribution)

    private func isFresh(at now: Date) -> Bool { fetchedAt <= now && now < expiresAt }

    static var available: Self? {
        #if DEBUG
            if DemoWeatherProvider.isEnabled { return nil }
        #endif
        guard let cached, cached.isFresh(at: .now) else { return nil }
        return cached
    }

    static func prune() {
        guard let cached, !cached.isFresh(at: .now) else { return }
        Self.cached = nil
        WeatherDiskCache.shared.remove(.attribution)
    }

    /// Weather is only displayed while the corresponding marks and legal link are available.
    static func displayExpiry(weatherExpiresAt: Date) -> Date? {
        #if DEBUG
            if DemoWeatherProvider.isEnabled { return weatherExpiresAt }
        #endif
        return available?.limitedDisplayExpiry(weatherExpiresAt: weatherExpiresAt)
    }

    func limitedDisplayExpiry(weatherExpiresAt: Date) -> Date {
        min(expiresAt, weatherExpiresAt)
    }

    static func refresh(
        keeping fallback: Self?, clock: () -> Date = { .now }, fetch: () async throws -> Self
    ) async throws -> Self {
        do {
            return try await fetch()
        } catch {
            // Keep valid marks during an outage. The display expires with them if needed.
            guard let fallback, fallback.isFresh(at: clock()) else { throw error }
            return fallback
        }
    }

    static func prepare() async throws {
        #if DEBUG
            if DemoWeatherProvider.isEnabled { return }
        #endif
        prune()
        if let cached, Date.now.timeIntervalSince(cached.fetchedAt) < refreshAfter { return }
        if let pending { return try await pending.value }

        let task = Task {
            defer { pending = nil }
            do {
                cached = try await refresh(keeping: cached) {
                    let attribution = try await WeatherService.shared.attribution
                    async let dark = mark(at: attribution.combinedMarkDarkURL)
                    async let light = mark(at: attribution.combinedMarkLightURL)
                    let value = try await Self(
                        darkMark: dark, lightMark: light, legalPageURL: attribution.legalPageURL, fetchedAt: .now)
                    WeatherDiskCache.shared.write(value, for: .attribution)
                    return value
                }
            } catch {
                prune()
                throw error
            }
        }
        pending = task
        try await task.value
    }

    private static func mark(at url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else {
            throw PhoneWeather.Failure.unavailable
        }
        return data
    }
}

struct AppleWeatherAttributionLink: View {
    let attribution: AppleWeatherAttribution
    @Environment(\.colorScheme) private var colorScheme

    static let height: CGFloat = 12

    /// The mark's drawn width (the light and dark marks share a shape).
    static func width(of attribution: AppleWeatherAttribution) -> CGFloat {
        guard let size = UIImage(data: attribution.darkMark)?.size, size.height > 0 else { return 0 }
        return height * size.width / size.height
    }

    var body: some View {
        let data = colorScheme == .dark ? attribution.darkMark : attribution.lightMark
        Link(destination: attribution.legalPageURL) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: Self.height)
            }
        }
        .accessibilityLabel("Apple Weather data sources")
    }
}
