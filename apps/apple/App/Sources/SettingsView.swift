import SwiftUI
import WaterKit

/// Units and auto-pause. Values default to "Automatic", which follows the sport.
struct SettingsView: View {
    @AppStorage(UserSettings.Key.speedUnit) private var speedUnit = UserSettings.automatic
    @AppStorage(UserSettings.Key.distanceUnit) private var distanceUnit = UserSettings.automatic

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speed", selection: $speedUnit) {
                        Text("Automatic").tag(UserSettings.automatic)
                        ForEach(SpeedUnit.allCases, id: \.rawValue) { unit in
                            Text(unit.symbol).tag(unit.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.speedUnit")
                    Picker("Distance", selection: $distanceUnit) {
                        Text("Automatic").tag(UserSettings.automatic)
                        ForEach(DistanceUnit.allCases, id: \.rawValue) { unit in
                            Text(unit.name).tag(unit.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.distanceUnit")
                } header: {
                    Text("Units")
                } footer: {
                    Text(
                        "Automatic uses knots and nautical miles on boats and boards, km/h and kilometres for paddling."
                    )
                }

                Section {
                    ForEach(Sport.allCases, id: \.self) { sport in
                        AutoPauseToggle(sport: sport)
                    }
                } header: {
                    Text("Auto-pause")
                } footer: {
                    Text(
                        "Pauses when you stop for 10 seconds and resumes when you move again. Changes apply to new sessions and to how past ones are shown."
                    )
                }

                Section {
                    ForEach(Sport.allCases, id: \.self) { sport in
                        SaveWorkoutToggle(sport: sport)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text(
                        "Saves each session as a workout with its route and heart rate. Recordings stay in MadeGood either way."
                    )
                }

                Section("About") {
                    LabeledContent("Version", value: AppInfo.version)
                    Link(destination: URL(string: "https://github.com/esaueng/madegood")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Text("Routes and charts are not for navigation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.accentColor)
            .navigationTitle("Settings")
        }
    }
}

private struct AutoPauseToggle: View {
    let sport: Sport
    @AppStorage private var enabled: Bool

    init(sport: Sport) {
        self.sport = sport
        _enabled = AppStorage(
            wrappedValue: SportProfile.standard(for: sport).autoPause.enabled, UserSettings.Key.autoPause(sport))
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            Label(sport.displayName, systemImage: sport.symbolName)
        }
        .accessibilityIdentifier("settings.autoPause.\(sport.rawValue)")
    }
}

private struct SaveWorkoutToggle: View {
    let sport: Sport
    @AppStorage private var enabled: Bool

    init(sport: Sport) {
        self.sport = sport
        _enabled = AppStorage(
            wrappedValue: SportProfile.standard(for: sport).savesWorkoutByDefault, UserSettings.Key.saveWorkout(sport))
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            Label(sport.displayName, systemImage: sport.symbolName)
        }
        .accessibilityIdentifier("settings.saveWorkout.\(sport.rawValue)")
    }
}

extension DistanceUnit {
    var name: String {
        switch self {
        case .metric: "Kilometres"
        case .nauticalMiles: "Nautical miles"
        case .statuteMiles: "Miles"
        }
    }
}
