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
    /// The sport just hidden by a swipe, while its Undo toast shows.
    @State private var hiddenSport: Sport?

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
        let sports = store.startList(extraUse: latest.mapValues { $0.startedAt.timeIntervalSince1970 })
        List {
            Section {
                ForEach(sports, id: \.self) { sport in
                    PhoneSportCard(
                        sport: sport, detail: detail(for: sport, latest: latest[sport]),
                        countdownMinutes: store[sport].countdownMinutes,
                        start: { controller.begin(sport) }, openSettings: { settingsSport = sport })
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        // The last visible sport can't be hidden.
                        if store.canHide(sport) {
                            Button("Hide", systemImage: "eye.slash") { hide(sport) }
                                .tint(.gray)
                                .accessibilityIdentifier("sport.hide.\(sport.rawValue)")
                        }
                    }
                }
            }

            if let error = controller.recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
            }

            let recent = Array(library.items.prefix(3))
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { item in
                        NavigationLink(value: item) {
                            SessionRow(item: item).padding(.vertical, 4)
                        }
                        .listRowBackground(Color(.secondarySystemBackground))
                    }
                } header: {
                    Text("Recent").font(.headline).foregroundStyle(.primary).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(12)
        .overlay(alignment: .bottom) {
            if let hidden = hiddenSport {
                HiddenSportToast(sport: hidden) { undoHide(hidden) }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: hiddenSport)
        .task(id: hiddenSport) {
            guard hiddenSport != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { hiddenSport = nil }
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

    /// Hides a sport from this screen (Settings > the sport > Show on start screen).
    private func hide(_ sport: Sport) {
        guard store.canHide(sport) else { return }
        store.update(sport) { $0.isHidden = true }
        hiddenSport = sport
    }

    private func undoHide(_ sport: Sport) {
        store.update(sport) { $0.isHidden = false }
        hiddenSport = nil
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

/// One full-width row per sport: icon, name over the last session, and a settings
/// button. Tapping the rest of the row starts the sport.
private struct PhoneSportCard: View {
    let sport: Sport
    let detail: String?
    let countdownMinutes: Int
    let start: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: start) {
                HStack(spacing: 12) {
                    SportBadge(sport: sport, diameter: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sport.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            // Wraps rather than truncates at large text sizes.
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
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
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sport.displayName)
            .accessibilityValue(detail.map { "Last session \($0)" } ?? "")
            .accessibilityHint("Starts a session")
            .accessibilityIdentifier("sport.\(sport.rawValue)")

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.trailing, 10)
            .accessibilityLabel("\(sport.displayName) settings")
            .accessibilityIdentifier("sportSettings.open.\(sport.rawValue)")
        }
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
    }
}

/// "Kayak hidden" with Undo, after a sport is hidden by a swipe.
private struct HiddenSportToast: View {
    let sport: Sport
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(sport.displayName) hidden")
                .font(.subheadline.weight(.semibold))
            Button("Undo", action: undo)
                .font(.subheadline.weight(.bold))
                .accessibilityIdentifier("sport.undoHide")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
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
                Label {
                    Text(countdown.sport.displayName)
                } icon: {
                    SportIcon(sport: countdown.sport, size: 22)
                }
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
                    Label {
                        Text(sport.displayName)
                    } icon: {
                        SportIcon(sport: sport, size: 22)
                    }
                    .font(.headline)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LiveControls(recorder: recorder, sport: sport, display: display)
        }
        .toolbar(.hidden, for: .tabBar)
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
    }
}

/// The recording controls, pinned to the bottom within thumb reach. While recording:
/// Lap and Mark, over a full-width Pause. After a pause: a summary with Resume and Save,
/// so ending a session always takes two deliberate taps. Auto-pause keeps the recording
/// controls; tapping Pause from there pauses for real.
private struct LiveControls: View {
    let recorder: SessionRecorder
    let sport: Sport
    let display: LiveDisplay
    @State private var saving = false

    var body: some View {
        Group {
            if recorder.metrics?.pauseState == .manuallyPaused {
                paused
            } else {
                recording
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.background)
        .animation(.snappy, value: recorder.metrics?.pauseState == .manuallyPaused)
    }

    private var recording: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    SessionController.shared.lap()
                } label: {
                    Label("Lap", systemImage: "stopwatch").frame(maxWidth: .infinity, minHeight: 36)
                }
                .accessibilityIdentifier("control.lap")
                Button {
                    recorder.mark()
                } label: {
                    Label("Mark", systemImage: "flag").frame(maxWidth: .infinity, minHeight: 36)
                }
                .accessibilityIdentifier("control.mark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.body.weight(.semibold))

            Button {
                recorder.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("control.pause")
        }
    }

    private var paused: some View {
        let metrics = recorder.metrics
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Paused").font(.title3.weight(.bold))
                Text(
                    "\(sport.displayName) · \(display.distance(metrics?.distance ?? 0)) · \(Formatting.elapsed(metrics?.movingTime ?? 0))"
                )
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("control.pause")
                Button {
                    saving = true
                    Task { await recorder.stop() }
                } label: {
                    Label("Save", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .disabled(saving)
                .accessibilityHint("Ends and saves the session")
                .accessibilityIdentifier("control.save")
            }
            .buttonBorderShape(.capsule)
            .font(.title3.weight(.bold))
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 24, style: .continuous))
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
