import SwiftUI
import WaterKit

/// One row per sport, each opening that sport's settings (the same form as on the watch),
/// then app-wide items.
struct SettingsView: View {
    @Environment(PrivateVoyageSync.self) private var voyageSync: PrivateVoyageSync?
    @State private var store = SettingsStore.shared
    @State private var weather = LocalWeather.shared
    @AppStorage(UserSettings.Key.appearance) private var appearance: Appearance = .system
    @AppStorage(UserSettings.Key.showManOverboardButton) private var showManOverboardButton = false
    @State private var exportingAll = false
    /// Progress of preparing Export All Recordings, 0 to 1.
    @State private var exportAllProgress = 0.0
    @State private var exportedAll: SessionDetailView.ShareFile?
    @State private var exportMessage: String?

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
                    if store.startOrder != nil {
                        Button("Order Start Screen by Recent Use", systemImage: "clock.arrow.circlepath") {
                            store.useRecentStartOrder()
                        }
                        .accessibilityIdentifier("settings.recentOrder")
                    }
                } header: {
                    Text("Sports")
                } footer: {
                    Text(
                        "Units, first screen, alerts, countdown and Health for each sport. Changes reach your watch. "
                            + "Touch and hold a sport on the start screen to drag it into your own order.")
                }

                Section {
                    NavigationLink("Heart Rate Zones") {
                        HeartRateZoneSettingsView()
                    }
                } footer: {
                    Text("Maximum heart rate and zone thresholds apply to every sport and sync to your watch.")
                }

                Section {
                    Toggle(
                        "Local Conditions",
                        isOn: Binding(get: { weather.isEnabled }, set: { weather.setEnabled($0) })
                    )
                    .accessibilityIdentifier("settings.localWeather")
                } header: {
                    Text("Weather")
                } footer: {
                    Text(
                        "Wind and weather where you are, rated for your sports, on the start screen. Your position "
                            + "is rounded to about 10 km and sent to Open-Meteo. A guide only, not a marine forecast.")
                }

                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .accessibilityIdentifier("settings.appearance")
                    // The control is its own pill; no list card around it.
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your iPhone. The watch app is always dark.")
                }

                Section("Safety") {
                    Toggle("Show Man Overboard (MOB) Button", isOn: $showManOverboardButton)
                        .accessibilityIdentifier("settings.showManOverboardButton")
                }

                SessionSyncSection()

                Section {
                    Button {
                        exportAll()
                    } label: {
                        if exportingAll {
                            HStack {
                                Label("Preparing Export…", systemImage: "square.and.arrow.up.on.square")
                                Spacer()
                                ProgressView(value: exportAllProgress).frame(width: 60)
                            }
                        } else {
                            Label("Export All Recordings", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    .disabled(exportingAll)
                    .accessibilityIdentifier("settings.exportAll")
                    if let exportMessage {
                        Text(exportMessage).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.exportAllMessage")
                    }
                } header: {
                    Text("Your Data")
                } footer: {
                    Text(
                        "A ZIP file of every recording on this iPhone, each as Share Raw Recording sends it: the raw sensor files in the current format. Exports contain precise locations and times. To download what is in your MadeGood account, use Settings on the website."
                    )
                }

                if voyageSync != nil {
                    PrivateVoyageAccountSection()
                }

                Section("About") {
                    LabeledContent("Version", value: AppInfo.version)
                    Link(destination: URL(string: "https://github.com/esaueng/madegood")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    if let privacy = AppInfo.privacyPolicyURL {
                        Link(destination: privacy) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                        .accessibilityIdentifier("settings.privacyPolicy")
                    }
                    Label("Routes and charts are not for navigation.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $exportedAll) { file in
                ShareSheet(url: file.url) { ExportFiles.discard(file.url) }
            }
            .navigationDestination(for: Sport.self) { sport in
                SportSettingsForm(sport: sport)
            }
        }
    }
}

extension SettingsView {
    private func exportAll() {
        exportingAll = true
        exportAllProgress = 0
        exportMessage = nil
        Task {
            defer { exportingAll = false }
            do {
                let made = try await ZipExport.zipAllRecordings(root: RecordingStore.root) { fraction in
                    Task { @MainActor in exportAllProgress = fraction }
                }
                if let made {
                    if made.skipped > 0 {
                        exportMessage =
                            made.skipped == 1
                            ? "1 folder isn’t a readable recording and was left out."
                            : "\(made.skipped) folders aren’t readable recordings and were left out."
                    }
                    exportedAll = SessionDetailView.ShareFile(url: made.zip)
                } else {
                    exportMessage = "There are no recordings on this iPhone yet."
                }
            } catch {
                exportMessage =
                    error is CancellationError
                    ? nil : "Couldn’t export your recordings. Check that there is free storage, then try again."
            }
        }
    }
}

private struct SportRow: View {
    let sport: Sport
    let settings: SportSettings

    var body: some View {
        HStack(spacing: 12) {
            SportBadge(sport: sport, diameter: 36, dimmed: settings.isHidden)
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
