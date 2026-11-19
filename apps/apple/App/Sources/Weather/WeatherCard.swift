import SwiftUI
import WaterKit

/// Local conditions at the top of the start screen: the animated scene with what it
/// means for each kind of craft on the start screen, or a one-line offer to turn it on.
struct WeatherCard: View {
    let weather: LocalWeather
    /// The start screen's sports, in order: they pick the wind unit and the ratings shown.
    let sports: [Sport]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            switch weather.status {
            case .off:
                if weather.choice == nil { offer }
            case .noLocation:
                notice(
                    "Location is off for MadeGood", symbol: "location.slash",
                    action: "Settings", identifier: "weather.openSettings"
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .failed:
                notice(
                    "Couldn't load conditions", symbol: "cloud.sun", action: "Retry", identifier: "weather.retry"
                ) {
                    Task { await weather.refresh(force: true) }
                }
            case .loading, .ready:
                if let now = weather.current {
                    ConditionsCard(weather: now, sports: sports)
                } else {
                    notice("Finding conditions where you are…", symbol: "location", action: nil, identifier: nil) {}
                }
            }
        }
        // Refreshes when the screen shows or the app comes back, at most every 15 minutes.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await weather.refresh()
                try? await Task.sleep(for: .seconds(LocalWeather.refreshAfter))
            }
        }
    }

    /// One row; at accessibility text sizes the words go above the buttons.
    private var offer: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Image(systemName: "sun.haze.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Conditions where you are")
                        .font(.subheadline.weight(.semibold))
                    Text("Wind and weather for your sports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !stacked { Spacer(minLength: 4) }
            HStack(spacing: 12) {
                Button("Not now") { weather.setEnabled(false) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weather.notNow")
                Button("Show") { weather.setEnabled(true) }
                    .font(.subheadline.weight(.bold))
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("weather.enable")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(cardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weather.offer")
    }

    private func notice(
        _ text: String, symbol: String, action: String?, identifier: String?, perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            if let action {
                Button(action, action: perform)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier(identifier ?? "")
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return shape.fill(Color.accentColor.opacity(0.1))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1))
    }
}

/// One compact card: the scene behind the temperature, headline and wind, with either a
/// warning about the next hours or a rating per kind of craft along the bottom.
private struct ConditionsCard: View {
    let weather: WeatherNow
    let sports: [Sport]

    /// The wind in the unit of the first wind sport shown (knots by default), else the
    /// first sport's: a sailor reads wind in knots even when a kayak is on top.
    private var speedUnit: SpeedUnit {
        let sport = sports.first { WaterOutlook.Craft($0) == .wind } ?? sports.first ?? .sailing
        return UserSettings.display(for: sport).speed
    }

    private var crafts: [WaterOutlook.Craft] {
        let shown = WaterOutlook.Craft.allCases.filter { craft in sports.contains { WaterOutlook.Craft($0) == craft } }
        return shown.isEmpty ? WaterOutlook.Craft.allCases : shown
    }

    var body: some View {
        let text = WeatherText(weather, speedUnit: speedUnit)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        ZStack(alignment: .topLeading) {
            WeatherScene(weather: weather, outlook: text.outlook)
            // Keeps the words readable over a bright sky.
            LinearGradient(
                colors: [.black.opacity(0.34), .black.opacity(0.08), .clear], startPoint: .leading,
                endPoint: UnitPoint(x: 0.72, y: 0.5)
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Text(text.temperature)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityIdentifier("weather.temperature")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.headline)
                            .font(.subheadline.weight(.bold))
                            .fontDesign(.rounded)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .accessibilityIdentifier("weather.headline")
                        Text(text.wind)
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .opacity(0.9)
                            .accessibilityIdentifier("weather.wind")
                    }
                }
                Spacer(minLength: 4)
                if let warning = text.warning {
                    Label(warning, systemImage: text.warningSymbol)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.95, green: 0.55, blue: 0.2).opacity(0.85), in: .capsule)
                        .accessibilityIdentifier("weather.warning")
                } else {
                    HStack(spacing: 5) { chips(text.outlook) }
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in width * 0.68 }
        }
        .frame(height: 112)
        // A fixed-height picture: its words stop growing at xxLarge (VoiceOver reads them all).
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await LocalWeather.shared.refresh(force: true) }
            }
            Link(destination: URL(string: "https://open-meteo.com")!) {
                Label("Weather data by Open-Meteo", systemImage: "info.circle")
            }
            Button("Hide Conditions", systemImage: "eye.slash") { LocalWeather.shared.setEnabled(false) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel + ". " + ratingsLabel(text.outlook))
        .accessibilityHint("Weather data by Open-Meteo. Not a marine forecast.")
        .accessibilityIdentifier("weather.card")
    }

    /// One small capsule per craft on the start screen: its icon and the rating.
    /// When every craft rates the same, one capsule with all their icons.
    @ViewBuilder private func chips(_ outlook: WaterOutlook) -> some View {
        let ratings = crafts.map { outlook.ratings[$0] ?? .fair }
        let groups: [[WaterOutlook.Craft]] = Set(ratings).count == 1 && crafts.count > 1 ? [crafts] : crafts.map { [$0] }
        ForEach(groups, id: \.self) { group in
            let rating = outlook.ratings[group[0]] ?? .fair
            HStack(spacing: 4) {
                ForEach(group, id: \.self) { craft in
                    SportIcon(sport: WeatherText.icon(for: craft, among: sports), size: 13)
                }
                Text(WeatherText.ratingWord(rating))
                    .foregroundStyle(WeatherText.ratingColor(rating))
            }
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.32), in: .capsule)
            .shadow(radius: 0)
            .accessibilityIdentifier("weather.rating.\(group.map(\.rawValue).joined(separator: "."))")
        }
    }

    private func ratingsLabel(_ outlook: WaterOutlook) -> String {
        crafts.map { craft in
            "\(WeatherText.craftName(craft)): \(WeatherText.ratingWord(outlook.ratings[craft] ?? .fair))"
        }.joined(separator: ", ")
    }
}
