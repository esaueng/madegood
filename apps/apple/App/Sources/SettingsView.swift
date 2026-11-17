import SwiftUI
import WaterKit

/// One row per sport, each opening that sport's settings (the same form as on the watch),
/// then app-wide items. Every setting starts at an automatic value that follows the sport.
struct SettingsView: View {
    @State private var store = SettingsStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Sport.allCases, id: \.self) { sport in
                        NavigationLink(value: sport) {
                            SportRow(sport: sport, settings: store[sport])
                        }
                        .accessibilityIdentifier("settings.sport.\(sport.rawValue)")
                    }
                } header: {
                    Text("Sports")
                } footer: {
                    Text("Units, first screen, alerts, countdown and Health for each sport. Changes reach your watch.")
                }

                Section("About") {
                    LabeledContent("Version", value: AppInfo.version)
                    Link(destination: URL(string: "https://github.com/esaueng/madegood")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Label("Routes and charts are not for navigation.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Sport.self) { sport in
                SportSettingsForm(sport: sport)
            }
        }
    }
}

private struct SportRow: View {
    let sport: Sport
    let settings: SportSettings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sport.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.cream)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(settings.isHidden ? 0.4 : 1), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(sport.displayName)
                    .foregroundStyle(settings.isHidden ? .secondary : .primary)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "kn · nm · Countdown 5 min", "Hidden".
    private var summary: String {
        if settings.isHidden { return "Hidden" }
        var parts = [
            settings.resolvedSpeedUnit(for: sport).symbol, settings.resolvedDistanceUnit(for: sport).symbol,
        ]
        if settings.countdownMinutes > 0 { parts.append("\(settings.countdownMinutes) min countdown") }
        if let alert = settings.distanceAlert {
            parts.append("alert \(ShortNumber.text(alert)) \(settings.resolvedDistanceUnit(for: sport).symbol)")
        }
        return parts.joined(separator: " · ")
    }
}
