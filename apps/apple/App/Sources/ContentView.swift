import MapKit
import SwiftUI
import WaterKit

/// The iPhone app: record, history, settings (docs/PLAN.md §6). Voyages arrive in Phase 5.
struct ContentView: View {
    @State private var controller = SessionController.shared
    @State private var library = SessionLibrary()
    @State private var tab = AppTab.record

    enum AppTab: Hashable { case record, history, settings }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Record", systemImage: "record.circle", value: AppTab.record) {
                RecordView(controller: controller, library: library)
            }
            Tab("History", systemImage: "list.bullet", value: AppTab.history) {
                HistoryView(library: library)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            controller.onFinish = { _, _, _ in library.reload() }
            library.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didReceiveFile)) { _ in
            library.reload()
        }
    }
}

// MARK: - Record

private struct RecordView: View {
    let controller: SessionController
    let library: SessionLibrary

    var body: some View {
        NavigationStack {
            if let countdown = controller.countdown {
                PhoneCountdownView(controller: controller, countdown: countdown)
            } else {
                switch controller.recorder.state {
                case .idle:
                    StartView(controller: controller, library: library)
                case .starting, .stopping:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .recording(_, let startedAt, let sport):
                    LiveView(recorder: controller.recorder, startedAt: startedAt, sport: sport)
                }
            }
        }
    }
}

/// Sport cards like the watch's: tap one to start (through its countdown), or its gear
/// for that sport's settings. Most recently used first.
private struct StartView: View {
    let controller: SessionController
    let library: SessionLibrary
    @State private var store = SettingsStore.shared
    @State private var settingsSport: Sport?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    /// The newest session of each sport in the history (recorded here or on the watch).
    private var latest: [Sport: SessionLibrary.Summary] {
        library.items.compactMap(\.summary).reduce(into: [:]) { result, summary in
            if (result[summary.sport]?.startedAt ?? .distantPast) < summary.startedAt {
                result[summary.sport] = summary
            }
        }
    }

    var body: some View {
        let latest = latest
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(
                        store.startList(extraUse: latest.mapValues { $0.startedAt.timeIntervalSince1970 }), id: \.self
                    ) { sport in
                        PhoneSportCard(
                            sport: sport, detail: detail(for: sport, latest: latest[sport]),
                            countdownMinutes: store[sport].countdownMinutes,
                            start: { controller.begin(sport) }, openSettings: { settingsSport = sport })
                    }
                }

                if let error = controller.recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                let recent = Array(library.items.prefix(3))
                if !recent.isEmpty {
                    Text("Recent").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(recent) { item in
                            NavigationLink(value: item) {
                                SessionRow(item: item).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            if item.id != recent.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal)
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                }
            }
            .padding()
        }
        .navigationTitle(AppInfo.name)
        .navigationDestination(for: SessionLibrary.Item.self) { item in
            SessionDetailView(item: item, library: library)
        }
        .sheet(item: $settingsSport) { sport in
            NavigationStack {
                SportSettingsForm(sport: sport)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { settingsSport = nil }
                                .accessibilityIdentifier("sportSettings.done")
                        }
                    }
            }
        }
    }

    private func detail(for sport: Sport, latest: SessionLibrary.Summary?) -> String? {
        let unit = store[sport].resolvedDistanceUnit(for: sport)
        let local = store.lastSessions[sport]
        switch (latest, local) {
        case (let summary?, let local?) where local.date > summary.startedAt:
            return LastSessionText.text(distance: local.distance, date: local.date, unit: unit)
        case (let summary?, _):
            return LastSessionText.text(distance: summary.metrics.distance, date: summary.startedAt, unit: unit)
        case (nil, let local?):
            return LastSessionText.text(distance: local.distance, date: local.date, unit: unit)
        case (nil, nil):
            return nil
        }
    }
}

private struct PhoneSportCard: View {
    let sport: Sport
    let detail: String?
    let countdownMinutes: Int
    let start: () -> Void
    let openSettings: () -> Void

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: sport.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.cream)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: .circle)
                    .padding(.bottom, 6)
                Text(sport.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Group {
                    if let detail {
                        Text(detail).monospacedDigit()
                    } else if countdownMinutes > 0 {
                        Label("\(countdownMinutes) min countdown", systemImage: "timer")
                    } else {
                        Text("Tap to start")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .bottomLeading)
            .padding(14)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 24, style: .continuous))
            .contentShape(.rect(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport.displayName)
        .accessibilityValue(detail.map { "Last session \($0)" } ?? "")
        .accessibilityHint("Starts a session")
        .accessibilityIdentifier("sport.\(sport.rawValue)")
        .overlay(alignment: .topTrailing) {
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(8)
            .accessibilityLabel("\(sport.displayName) settings")
            .accessibilityIdentifier("sportSettings.open.\(sport.rawValue)")
        }
    }
}

/// The countdown before recording, on iPhone.
private struct PhoneCountdownView: View {
    let controller: SessionController
    let countdown: SessionController.Countdown

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = SessionController.now
            let seconds = countdown.timer.displaySeconds(at: now)
            let fraction =
                countdown.timer.duration > 0 ? countdown.timer.remaining(at: now) / countdown.timer.duration : 0
            let isFinal = seconds <= 10
            VStack(spacing: 28) {
                Label(countdown.sport.displayName, systemImage: countdown.sport.symbolName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(
                            isFinal ? Theme.coral : Color.accentColor,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(Formatting.elapsed(Double(seconds)))
                        .font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isFinal ? Theme.coral : .primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, 28)
                        .accessibilityLabel("\(seconds) seconds to start")
                        .accessibilityIdentifier("countdown.time")
                }
                .frame(maxWidth: 280, maxHeight: 280)
                Text("Recording starts at zero")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        controller.cancelCountdown()
                    } label: {
                        Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("countdown.cancel")
                    if countdown.canSync {
                        Button {
                            controller.sync()
                        } label: {
                            Label("Sync", systemImage: "arrow.trianglehead.2.clockwise")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityHint("Rounds to the nearest minute")
                        .accessibilityIdentifier("countdown.sync")
                    }
                    Button {
                        controller.startNow()
                    } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Start now")
                    .accessibilityIdentifier("countdown.startNow")
                }
                .font(.headline)
                .labelStyle(.titleAndIcon)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Countdown")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The live session: the numbers that matter at a glance, a small map, and controls.
private struct LiveView: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @State private var confirmStop = false
    @State private var banner: SessionRecorder.DistanceAlertEvent?

    /// The sport's first screen, read once when the session opens.
    private let first: LiveScreen

    init(recorder: SessionRecorder, startedAt: Date, sport: Sport) {
        self.recorder = recorder
        self.startedAt = startedAt
        self.sport = sport
        first = UserSettings.settings(for: sport).firstScreen
    }

    /// The metric shown large: the first screen, or speed when that is the map.
    private var heroScreen: LiveScreen { first == .map ? .speed : first }

    private func heroValue(_ hero: LiveScreen, display: LiveDisplay, metrics: LiveMetrics?, time: String) -> String {
        switch hero {
        case .speed, .map: display.speed(metrics?.speed)
        case .distance: display.distance(metrics?.distance ?? 0)
        case .time: time
        case .heartRate: LiveDisplay.heartRate(metrics?.heartRate)
        }
    }

    var body: some View {
        let display = UserSettings.display(for: sport)
        let metrics = recorder.metrics
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Label(sport.displayName, systemImage: sport.symbolName).font(.headline)
                    Spacer()
                    if let state = metrics?.pauseState, let label = LiveDisplay.pauseLabel(state) {
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.yellow.opacity(0.25), in: .capsule)
                            .accessibilityIdentifier("pauseBadge")
                    } else if let lap = LiveDisplay.lapLabel(metrics) {
                        Text(lap).font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("metric.lap")
                    }
                }

                if first == .map {
                    LiveTrackMap(points: recorder.trackPoints)
                        .frame(height: 260)
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityIdentifier("page.map")
                }

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let time = Formatting.elapsed(context.date.timeIntervalSince(startedAt))
                    let hero = heroScreen
                    VStack(spacing: 0) {
                        Text(heroValue(hero, display: display, metrics: metrics, time: time))
                            .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .accessibilityHint(hero.title)
                            .accessibilityIdentifier("metric.\(hero.rawValue)")
                        Text(hero == .time ? display.speed(metrics?.speed) : time)
                            .font(.title2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(hero == .time ? "metric.speed" : "metric.time")
                    }
                }

                Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        if heroScreen == .distance {
                            StatTile(title: "Speed", value: display.speed(metrics?.speed))
                        } else {
                            StatTile(
                                title: "Distance", value: display.distance(metrics?.distance ?? 0),
                                identifier: "metric.distance")
                        }
                        StatTile(title: "Moving", value: Formatting.elapsed(metrics?.movingTime ?? 0))
                    }
                    GridRow {
                        StatTile(title: "Average", value: display.speed(metrics?.averageSpeed))
                        StatTile(title: "Max 10 s", value: display.speed(metrics?.maxSpeed10s))
                    }
                    GridRow {
                        if heroScreen == .heartRate {
                            StatTile(title: "Speed", value: display.speed(metrics?.speed))
                        } else {
                            StatTile(title: "Heart rate", value: LiveDisplay.heartRate(metrics?.heartRate))
                        }
                        StatTile(title: "Course", value: LiveDisplay.course(metrics?.course))
                    }
                }
                .padding()
                .background(.background.secondary, in: .rect(cornerRadius: 12))

                if first != .map {
                    LiveTrackMap(points: recorder.trackPoints)
                        .frame(height: 180)
                        .clipShape(.rect(cornerRadius: 16))
                }

                HStack(spacing: 10) {
                    LiveControl(
                        title: recorder.isPaused ? "Resume" : "Pause",
                        symbol: recorder.isPaused ? "play.fill" : "pause.fill", identifier: "control.pause"
                    ) {
                        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                    }
                    LiveControl(title: "Lap", symbol: "stopwatch", identifier: "control.lap") {
                        SessionController.shared.lap()
                    }
                    LiveControl(title: "Mark", symbol: "flag", identifier: "control.mark") { recorder.mark() }
                    LiveControl(title: "Stop", symbol: "stop.fill", tint: .red, identifier: "control.stop") {
                        confirmStop = true
                    }
                }

                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                DisclosureGroup("Sensors") {
                    CountsGrid(counts: recorder.counts).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
            .padding()
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let banner {
                let text = UserSettings.display(for: sport).distance(banner.distance)
                DistanceAlertBanner(text: text)
                    .accessibilityLabel("Distance alert, \(text)")
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.snappy, value: banner)
        .onChange(of: recorder.distanceAlert) { _, alert in
            guard let alert else { return }
            Haptics.play(.distanceAlert)
            banner = alert
        }
        .task(id: banner) {
            guard banner != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { banner = nil }
        }
        .confirmationDialog("End this session?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("End session", role: .destructive) {
                Task { await recorder.stop() }
            }
            .accessibilityIdentifier("control.confirmStop")
        }
    }
}

private struct LiveControl: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityIdentifier(identifier)
    }
}

/// The live track, following the current position. Display only, like the watch.
private struct LiveTrackMap: View {
    let points: [SessionRecorder.TrackPoint]

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .userLocation(followsHeading: false, fallback: .automatic), interactionModes: []) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates).stroke(Color.accentColor, lineWidth: 4)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

#Preview {
    ContentView()
}
