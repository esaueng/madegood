import SwiftUI
import WaterKit

/// One row per sport, each opening that sport's settings (the same form as on the watch),
/// then app-wide items. Every setting starts at an automatic value that follows the sport.
struct SettingsView: View {
    @Environment(PrivateVoyageSync.self) private var voyageSync: PrivateVoyageSync?
    @State private var store = SettingsStore.shared
    @AppStorage(UserSettings.Key.appearance) private var appearance: Appearance = .system
    @State private var exportingAll = false
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
                } header: {
                    Text("Sports")
                } footer: {
                    Text("Units, first screen, alerts, countdown and Health for each sport. Changes reach your watch.")
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

                SessionSyncSection()

                Section {
                    Button {
                        exportAll()
                    } label: {
                        Label(
                            exportingAll ? "Preparing Export…" : "Export All Recordings",
                            systemImage: "square.and.arrow.up.on.square")
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
                        "A ZIP file of every recording on this iPhone: raw sensor files and tracks. Exports contain precise locations and times. To download what is in your MadeGood account, use Settings on the website."
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
                    Label("Routes and charts are not for navigation.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $exportedAll) { file in
                ShareSheet(url: file.url)
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
        exportMessage = nil
        Task {
            defer { exportingAll = false }
            do {
                if let url = try await ZipExport.zipAllRecordings(root: RecordingStore.root) {
                    exportedAll = SessionDetailView.ShareFile(url: url)
                } else {
                    exportMessage = "There are no recordings on this iPhone yet."
                }
            } catch {
                exportMessage = "Couldn’t export your recordings. Try again."
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
