import SwiftUI
import WaterKit

/// One sport's settings, the same on the watch and the iPhone. Changes save at once and
/// are sent to the other device (`SettingsStore`).
struct SportSettingsForm: View {
    let sport: Sport
    @State private var store = SettingsStore.shared

    var body: some View {
        let settings = store[sport]
        let distanceUnit = settings.resolvedDistanceUnit(for: sport)
        Form {
            Section {
                Picker("Speed", selection: store.binding(sport, \.speedUnit)) {
                    Text("Automatic (\(SpeedUnit.automatic(for: sport).symbol))").tag(SpeedUnit?.none)
                    ForEach(SpeedUnit.allCases, id: \.self) { unit in
                        Text(unit.symbol).tag(SpeedUnit?.some(unit))
                    }
                }
                .accessibilityIdentifier("sportSettings.speedUnit")
                Picker("Distance", selection: store.binding(sport, \.distanceUnit)) {
                    Text("Automatic (\(DistanceUnit.automatic(for: sport).symbol))").tag(DistanceUnit?.none)
                    ForEach(DistanceUnit.allCases, id: \.self) { unit in
                        Text(unit.name).tag(DistanceUnit?.some(unit))
                    }
                }
                .accessibilityIdentifier("sportSettings.distanceUnit")
            } header: {
                Text("Units")
            }

            Section {
                Picker("Opens on", selection: store.binding(sport, \.firstScreen)) {
                    ForEach(LiveScreen.allCases, id: \.self) { screen in
                        Label(screen.title, systemImage: screen.symbolName).tag(screen)
                    }
                }
                .accessibilityIdentifier("sportSettings.firstScreen")
                Picker("Distance alert", selection: store.binding(sport, \.distanceAlert)) {
                    Text("Off").tag(Double?.none)
                    ForEach(SportSettings.distanceAlertChoices, id: \.self) { value in
                        Text("Every \(ShortNumber.text(value)) \(distanceUnit.symbol)").tag(Double?.some(value))
                    }
                }
                .accessibilityIdentifier("sportSettings.distanceAlert")
                Toggle("Auto-pause", isOn: store.binding(sport, \.autoPause))
                    .accessibilityIdentifier("sportSettings.autoPause")
            } header: {
                Text("Session")
            } footer: {
                Text("Auto-pause stops the clock after 10 s at rest. Distance alerts tap your wrist at each mark.")
            }

            Section {
                Picker("Countdown", selection: store.binding(sport, \.countdownMinutes)) {
                    ForEach(SportSettings.countdownChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
                    }
                }
                .accessibilityIdentifier("sportSettings.countdown")
            } header: {
                Text("Start")
            } footer: {
                if sport == .sailing {
                    Text(
                        "Taps each minute and over the last 10 s. Sync rounds to the nearest minute at a start signal.")
                } else {
                    Text("Taps each minute and over the last 10 s. Recording begins at zero.")
                }
            }

            #if os(iOS)
                if sport == .motorboating {
                    FuelSettingsSection(sport: sport)
                }
            #endif

            Section {
                Toggle("Save to Health", isOn: store.binding(sport, \.savesWorkout))
                    .accessibilityIdentifier("sportSettings.saveWorkout")
                Toggle(
                    "Show on start screen",
                    isOn: Binding(
                        get: { !store[sport].isHidden },
                        set: { shown in store.update(sport) { $0.isHidden = !shown } })
                )
                .disabled(!store[sport].isHidden && !store.canHide(sport))
                .accessibilityIdentifier("sportSettings.visible")
            } footer: {
                if !store[sport].isHidden && !store.canHide(sport) {
                    Text("At least one sport stays on the start screen.")
                } else {
                    Text("Sessions stay in MadeGood whether or not they are saved to Health.")
                }
            }
        }
        .tint(.accentColor)
        .navigationTitle(sport.displayName)
    }
}

#if os(iOS)
    /// Burn rates for the motorboat fuel estimate, entered in the chosen unit per hour and
    /// stored in litres per hour.
    private struct FuelSettingsSection: View {
        let sport: Sport
        @State private var store = SettingsStore.shared

        var body: some View {
            let unit = store[sport].fuelUnit
            Section {
                Picker("Fuel unit", selection: store.binding(sport, \.fuelUnit)) {
                    Text("Litres").tag(VolumeUnit.litres)
                    Text("US gallons").tag(VolumeUnit.usGallons)
                }
                .accessibilityIdentifier("sportSettings.fuelUnit")
                rateField("Under way", field: \.fuelBurnRate, unit: unit, identifier: "sportSettings.fuelBurn")
                rateField("Idle", field: \.idleFuelBurnRate, unit: unit, identifier: "sportSettings.fuelIdleBurn")
            } header: {
                Text("Fuel estimate")
            } footer: {
                Text(
                    "Your engine's burn per hour at cruising speed, and while idling or manoeuvring (0 if you shut it down). Fuel is shown as an estimate, never a measurement."
                )
            }
        }

        private func rateField(
            _ title: String, field: WritableKeyPath<SportSettings, Double?>, unit: VolumeUnit, identifier: String
        ) -> some View {
            let binding = Binding<Double?>(
                get: { store[sport][keyPath: field].map { (unit.fromLitres($0) * 100).rounded() / 100 } },
                set: { value in
                    store.update(sport) { settings in
                        let litres = value.map(unit.toLitres)
                        let valid = litres.map { $0.isFinite && $0 >= 0 && $0 <= SportSettings.maxFuelBurnRate } ?? true
                        settings[keyPath: field] = valid ? litres : nil
                    }
                })
            return LabeledContent(title) {
                HStack(spacing: 4) {
                    TextField("Off", value: binding, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(identifier)
                    Text("\(unit.symbol)/h").foregroundStyle(.secondary)
                }
            }
        }
    }
#endif

extension LiveScreen {
    var title: String {
        switch self {
        case .speed: "Speed"
        case .distance: "Distance"
        case .time: "Time"
        case .heartRate: "Heart rate"
        case .map: "Map"
        }
    }

    var symbolName: String {
        switch self {
        case .speed: "gauge.with.needle"
        case .distance: "point.topleft.down.to.point.bottomright.curvepath"
        case .time: "stopwatch"
        case .heartRate: "heart"
        case .map: "map"
        }
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

enum ShortNumber {
    /// "0.25", "1", "10": no trailing zeros.
    static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// "4.20 nm · Tue": the last session of a sport, for its start card.
enum LastSessionText {
    static func text(distance: Double, date: Date, unit: DistanceUnit, now: Date = Date()) -> String {
        "\(unit.display(distance).text) · \(day(date, now: now))"
    }

    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A short banner for a distance alert, shown over the live session.
struct DistanceAlertBanner: View {
    let text: String

    var body: some View {
        // Solid, not glass: it must stay readable over numbers, in sunlight and in water lock.
        Label(text, systemImage: "flag.checkered")
            .font(.headline.monospacedDigit())
            .foregroundStyle(Theme.cream)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.teal, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.brightTeal, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("distanceAlert.banner")
    }
}
