import MapKit
import SwiftUI
import WaterKit

/// The iPhone app tabs (docs/PLAN.md §6).
struct ContentView: View {
    @State private var controller = SessionController.shared
    @State private var library = SessionLibrary()
    @State private var voyageRecorder = VoyageRecorder.shared
    @State private var tab = AppTab.record
    @Environment(SessionSync.self) private var sessionSync: SessionSync?

    enum AppTab: Hashable { case record, voyages, history, settings }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Record", systemImage: "record.circle", value: AppTab.record) {
                RecordView(controller: controller, library: library, showHistory: { tab = .history })
            }
            Tab("Voyages", systemImage: "sailboat", value: AppTab.voyages) {
                VoyagesView(recorder: voyageRecorder)
            }
            Tab("History", systemImage: "list.bullet", value: AppTab.history) {
                HistoryView(library: library)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            voyageRecorder.liveSharing = PrivateVoyageSync.shared?.liveSharing
            controller.onFinish = { _, _, _ in library.reload() }
            library.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didReceiveFile)) { _ in
            library.reload()
        }
        // New, finished and deleted recordings reach the upload queue.
        .onChange(of: library.items.map(\.entry)) { sessionSync?.recordingsChanged() }
        // A new trim re-freezes a queued session, or re-uploads a synced one.
        .onReceive(NotificationCenter.default.publisher(for: SessionLibrary.didChangeTrim)) { _ in
            sessionSync?.recordingsChanged()
        }
        #if DEBUG
            .onChange(of: controller.recorder.isRecording) { _, isRecording in
                if isRecording { WatchWorkoutMirror.shared.seedDemoIfRequested() }
            }
        #endif
    }
}

// MARK: - Record

private struct RecordView: View {
    let controller: SessionController
    let library: SessionLibrary
    let showHistory: () -> Void
    @State private var manOverboard = ManOverboard.shared
    @State private var showingManOverboard = false

    /// With no session or countdown, an active mark fills the tab instead of a sheet.
    private var showsManOverboardInline: Bool {
        controller.countdown == nil && controller.recorder.state == .idle && controller.watchWorkout == nil
            && manOverboard.isActive
    }

    var body: some View {
        let showManOverboard = { showingManOverboard = true }
        NavigationStack {
            if let countdown = controller.countdown {
                PhoneCountdownView(controller: controller, countdown: countdown, showManOverboard: showManOverboard)
            } else {
                switch controller.recorder.state {
                case .idle:
                    if let workout = controller.watchWorkout {
                        LiveView(watchWorkout: workout, library: library, showManOverboard: showManOverboard)
                            .id(workout.sessionID)
                    } else if manOverboard.isActive {
                        // An active mark outlives the session (and relaunches) until cleared,
                        // as on the watch.
                        ManOverboardScreen(manOverboard: manOverboard, sport: controller.sport ?? .sailing)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                NavigationLink {
                                    StartView(
                                        controller: controller, library: library, showHistory: showHistory,
                                        showManOverboard: showManOverboard)
                                } label: {
                                    Label("New session", systemImage: "record.circle")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .padding()
                                .background(.background)
                                .accessibilityIdentifier("mob.newSession")
                            }
                            .navigationTitle("Man Overboard")
                            .navigationBarTitleDisplayMode(.inline)
                    } else if WatchWorkoutMirror.shared.isAttached {
                        VStack(spacing: 16) {
                            WatchWorkoutStatus(snapshot: nil, connected: true)
                            PhoneManOverboardControl(show: showManOverboard)
                        }
                        .padding()
                        .navigationTitle("On Watch")
                    } else {
                        StartView(
                            controller: controller, library: library, showHistory: showHistory,
                            showManOverboard: showManOverboard)
                    }
                case .starting, .stopping:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .recording(_, let startedAt, let sport):
                    LiveView(
                        recorder: controller.recorder, startedAt: startedAt, sport: sport, library: library,
                        showManOverboard: showManOverboard)
                }
            }
        }
        .sheet(isPresented: $showingManOverboard) {
            NavigationStack {
                ManOverboardScreen(
                    manOverboard: manOverboard,
                    sport: controller.countdown?.sport ?? controller.watchWorkout?.sport ?? controller.sport ?? .sailing,
                    points: controller.recorder.isRecording ? controller.recorder.trackPoints : []
                )
                .navigationTitle("Man Overboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingManOverboard = false }
                            .accessibilityIdentifier("mob.done")
                    }
                }
            }
        }
        // A new mark or press, from any MOB control or from the watch, shows the way
        // back at once; clearing it closes the sheet.
        .onChange(of: manOverboard.mark?.identity) { old, new in
            if let new, new != old, !showsManOverboardInline { showingManOverboard = true }
        }
        .onChange(of: manOverboard.awaitingFixSince) { _, pressed in
            if pressed != nil, !showsManOverboardInline { showingManOverboard = true }
        }
        .onChange(of: manOverboard.isActive) { _, active in
            if !active { showingManOverboard = false }
        }
        .onChange(of: showsManOverboardInline) { _, inline in
            if inline { showingManOverboard = false }
        }
        // With no local recording feeding positions (a countdown, a mirrored watch
        // session, or none), guidance uses ManOverboard's own location updates.
        .onChange(of: manOverboard.isActive && !controller.recorder.isRecording, initial: true) { _, needed in
            manOverboard.setOwnUpdates(needed, owner: "record")
        }
    }
}

/// Sport cards like the watch's: tap one to start (through its countdown), or its gear
/// for that sport's settings. Most recently used first until the user drags them into
/// their own order. Local conditions sit above them once turned on.
private struct StartView: View {
    let controller: SessionController
    let library: SessionLibrary
    let showHistory: () -> Void
    let showManOverboard: () -> Void
    @State private var store = SettingsStore.shared
    @State private var weather = LocalWeather.shared
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
            StartHeader()
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if weather.isEnabled {
                WeatherCard(weather: weather, sports: sports)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let lastConfirmed = WatchWorkoutMirror.shared.lastConfirmed {
                WatchWorkoutStatus(snapshot: lastConfirmed, connected: false)
            }

            // MOB before any session too: someone can fall in while getting under way.
            PhoneManOverboardControl(show: showManOverboard)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

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
                // Long-press and drag a card to reorder; the order sticks from then on.
                .onMove { from, to in
                    var moved = sports
                    moved.move(fromOffsets: from, toOffset: to)
                    store.reorderStartList(current: sports, to: moved)
                }
            }

            // The one-time offer sits under the sports so it never pushes them down.
            if weather.choice == nil {
                WeatherCard(weather: weather, sports: sports)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let error = controller.recorder.lastError {
                Label {
                    Text(error).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
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
                    HStack(alignment: .firstTextBaseline) {
                        Text("Recent")
                            .font(.title3.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Button("See All", action: showHistory)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("recent.seeAll")
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { if weather.isEnabled { await weather.refresh(force: true) } }
        .listSectionSpacing(12)
        // The cards and Recent are about one screen tall: when they fit, don't let the
        // list rubber-band; when they don't, it scrolls just the overflow.
        .scrollBounceBehavior(.basedOnSize)
        // The safe area already clears the status bar; drop the grouped list's extra top
        // margin so the header sits just under the bar.
        .contentMargins(.top, 0, for: .scrollContent)
        .background { StartBackground() }
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
        // The header row stands in for the title; the title stays for the Back button.
        // No bar, so the header sits just under the status bar; rows soften under the
        // clock and the Dynamic Island as they scroll.
        .navigationTitle(AppInfo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
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

/// The logo and a two-tone wordmark over today's date, in place of a plain large title.
private struct StartHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark(size: 36)
            VStack(alignment: .leading, spacing: 0) {
                (Text("Made").foregroundStyle(.primary) + Text("Good").foregroundStyle(Color.accentColor))
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Ticks so the date rolls over at midnight while the screen stays open.
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("start.header")
    }
}

/// A soft wash of the brand teal behind the top of the start screen.
private struct StartBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.04), .clear],
            startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)
        )
        .ignoresSafeArea()
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
                            .fontDesign(.rounded)
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
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            shape
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1))
        }
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
    let showManOverboard: () -> Void
    @State private var startLine = StartLineController.shared

    private var hasStartLine: Bool { countdown.sport == .sailing }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = SessionController.now
            let seconds = countdown.timer.displaySeconds(at: now)
            let fraction =
                countdown.timer.duration > 0 ? countdown.timer.remaining(at: now) / countdown.timer.duration : 0
            let isFinal = seconds <= 10
            ScrollView {
                VStack(spacing: hasStartLine ? 18 : 28) {
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
                    .frame(maxWidth: hasStartLine ? 210 : 280, maxHeight: hasStartLine ? 210 : 280)
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
                    // Above the start line panel, so it is always in reach.
                    PhoneManOverboardControl(show: showManOverboard)
                    if hasStartLine {
                        StartLinePanel(
                            startLine: startLine, remaining: countdown.timer.remaining(at: now),
                            display: UserSettings.display(for: countdown.sport)
                        )
                        .padding()
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
        }
        .navigationTitle("Countdown")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The live session: the numbers that matter at a glance, a small map, and controls.
private struct LiveView: View {
    let recorder: SessionRecorder?
    let startedAt: Date?
    let watchWorkout: WorkoutMirrorSnapshot?
    let sport: Sport
    let library: SessionLibrary
    @State private var banner: SessionRecorder.DistanceAlertEvent?
    let showManOverboard: () -> Void
    @State private var manOverboard = ManOverboard.shared
    @State private var startLine = StartLineController.shared
    @ScaledMetric(relativeTo: .largeTitle) private var primarySize = 64.0

    /// The sport's first screen, read once when the session opens.
    private let first: LiveScreen

    init(
        recorder: SessionRecorder, startedAt: Date, sport: Sport, library: SessionLibrary,
        showManOverboard: @escaping () -> Void
    ) {
        self.showManOverboard = showManOverboard
        self.recorder = recorder
        self.startedAt = startedAt
        self.sport = sport
        self.library = library
        watchWorkout = nil
        first = UserSettings.settings(for: sport).firstScreen
    }

    init(watchWorkout: WorkoutMirrorSnapshot, library: SessionLibrary, showManOverboard: @escaping () -> Void) {
        self.showManOverboard = showManOverboard
        recorder = nil
        startedAt = nil
        self.library = library
        self.watchWorkout = watchWorkout
        sport = watchWorkout.sport
        first = UserSettings.settings(for: sport).firstScreen
    }

    /// The metric shown large: the first screen, or speed when that is the map.
    private var heroScreen: LiveScreen { first == .map ? .speed : first }

    var body: some View {
        let display = UserSettings.display(for: sport)
        let readings = watchWorkout?.readings ?? LiveReadings(recorder?.metrics, strokes: recorder?.strokes)
        ScrollView {
            VStack(spacing: 16) {
                if let watchWorkout {
                    WatchWorkoutStatus(snapshot: watchWorkout, connected: true)
                } else {
                    localStatus(readings)
                }
                if manOverboard.isActive {
                    ManOverboardCard(manOverboard: manOverboard, sport: sport, open: showManOverboard)
                }

                if recorder != nil, let warning = startLine.warning {
                    OCSBanner(warning: warning, display: display) { startLine.dismissWarning() }
                }
                if recorder != nil, let failed = startLine.failedAtStart {
                    PingFailedBanner(end: failed) { startLine.dismissFailedAtStart() }
                }
                if let recorder, let startedAt {
                    if first == .map {
                        LiveTrackMap(points: recorder.trackPoints, manOverboard: manOverboard.mark)
                            .frame(height: 260)
                            .clipShape(.rect(cornerRadius: 16))
                            .accessibilityIdentifier("page.map")
                    }
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        metricCards(display: display, readings: readings, elapsed: context.date.timeIntervalSince(startedAt))
                    }
                    motorboatPage(display: display, readings: readings)
                    if first != .map {
                        LiveTrackMap(points: recorder.trackPoints, manOverboard: manOverboard.mark)
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
                } else {
                    metricCards(display: display, readings: readings, elapsed: readings.elapsed)
                    motorboatPage(display: display, readings: readings)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let recorder {
                LiveControls(recorder: recorder, sport: sport, display: display, showManOverboard: showManOverboard)
            } else {
                // The watch owns a mirrored recording, but MOB still works from here.
                PhoneManOverboardControl(show: showManOverboard)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(.background)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(sport.displayName)
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
        .onChange(of: recorder?.distanceAlert) { _, alert in
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

    /// The session on screen: this phone's recording, or the watch's mirrored one.
    private var activeSessionID: UUID? {
        if let watchWorkout { return watchWorkout.sessionID }
        if case .recording(let sessionId, _, _) = recorder?.state { return sessionId }
        return nil
    }

    /// The motorboat trip log (PLAN §5), under the headline metrics.
    @ViewBuilder
    private func motorboatPage(display: LiveDisplay, readings: LiveReadings) -> some View {
        if sport == .motorboating {
            MotorboatLiveCard(
                readings: readings, display: display,
                savedTrips: MotorboatStats.savedTrips(library, excluding: activeSessionID))
        }
    }

    private func localStatus(_ readings: LiveReadings) -> some View {
        let pause = LiveDisplay.pauseLabel(readings.pauseState)
        return HStack {
            Label {
                Text(pause ?? "Recording")
            } icon: {
                Image(systemName: pause == nil ? "record.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(pause == nil ? Color.red : Color.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.background.secondary, in: .capsule)
            .accessibilityIdentifier(pause == nil ? "recordingBadge" : "pauseBadge")
            Spacer(minLength: 8)
            if let lap = readings.lap {
                Text("Lap \(lap)")
                    .accessibilityIdentifier("metric.lap")
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func metricCards(display: LiveDisplay, readings: LiveReadings, elapsed: TimeInterval) -> some View {
        let metrics = liveMetrics(display: display, readings: readings, elapsed: elapsed)
        let primaryID = "metric.\(heroScreen.rawValue)"
        let supporting = metrics.filter { $0.id != primaryID }
        return VStack(spacing: 16) {
            if let primary = metrics.first(where: { $0.id == primaryID }) {
                primaryMetric(primary)
            }
            supportingMetrics(Array(supporting.prefix(3)))
            if sport.isPaddling {
                // The paddling sport page (PLAN §6): strokes on their own card.
                supportingMetrics(strokeMetrics(display: display, readings: readings))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("card.strokes")
            }
            if let categories = readings.speedCategories {
                speedBests(categories, display: display)
            }
            if let sailing = readings.sailing {
                sailingCard(sailing, course: readings.course, display: display)
            }
            DisclosureGroup("More metrics") {
                VStack(spacing: 12) {
                    ForEach(supporting.dropFirst(3)) { metric in
                        metricRow(metric)
                    }
                }
                .padding(.top, 12)
            }
            .font(.subheadline)
        }
    }

    private func liveMetrics(display: LiveDisplay, readings: LiveReadings, elapsed: TimeInterval) -> [LiveMetric] {
        let heartRate = LiveMetric(
            id: "metric.heartRate", title: "Heart rate", text: LiveDisplay.heartRate(readings.heartRate))
        let course = LiveMetric(id: "metric.course", title: "Course", text: LiveDisplay.course(readings.course))
        return [
            LiveMetric(id: "metric.speed", title: "Speed", text: display.speed(readings.speed)),
            LiveMetric(id: "metric.time", title: "Elapsed time", text: Formatting.elapsed(elapsed)),
            LiveMetric(id: "metric.distance", title: "Distance", text: display.distance(readings.distance)),
            sport.isPaddling ? heartRate : course,
            sport.isPaddling ? course : heartRate,
            LiveMetric(id: "metric.moving", title: "Moving time", text: Formatting.elapsed(readings.movingTime)),
            LiveMetric(id: "metric.average", title: "Average speed", text: display.speed(readings.averageSpeed)),
            LiveMetric(id: "metric.max", title: "Max speed (10 s)", text: display.speed(readings.maxSpeed10s)),
        ]
    }

    private func strokeMetrics(display: LiveDisplay, readings: LiveReadings) -> [LiveMetric] {
        [
            LiveMetric(
                id: "metric.strokeRate", title: "Stroke rate", text: LiveDisplay.strokeRate(readings.strokeRate)),
            LiveMetric(id: "metric.strokes", title: "Strokes", text: LiveDisplay.strokeCount(readings.strokeCount)),
            LiveMetric(
                id: "metric.distancePerStroke", title: "Per stroke",
                text: display.distancePerStroke(distance: readings.distance, strokes: readings.strokeCount)),
        ]
    }

    private func primaryMetric(_ metric: LiveMetric) -> some View {
        VStack(spacing: 2) {
            metric.caption.font(.headline)
            // Leave room for a supporting reading above the pinned controls on short screens.
            metric.reading(
                numberFont: .system(size: min(primarySize, 96), weight: .bold, design: .rounded),
                unitFont: .title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private func supportingMetrics(_ metrics: [LiveMetric]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        metric.caption.font(.subheadline)
                        metric.reading(numberFont: .title2.weight(.semibold), unitFont: .subheadline)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(spacing: 12) {
                ForEach(metrics) { metric in
                    metricRow(metric)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    /// Windsurfing: the speedsurfing categories (docs/metrics.md), two to a row.
    private func speedBests(_ categories: SpeedCategoryReadings, display: LiveDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speed bests")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            let column = GridItem(.flexible(), alignment: .leading)
            LazyVGrid(columns: [column, column], alignment: .leading, spacing: 12) {
                ForEach(categories.rows) { row in
                    let metric = LiveMetric(id: row.id, title: row.title, text: display.speed(row.value))
                    VStack(alignment: .leading, spacing: 2) {
                        metric.caption.font(.caption)
                        metric.reading(numberFont: .title3.weight(.semibold), unitFont: .footnote)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.speedBests")
    }

    /// The sailing sport page (PLAN §6): VMG, heading, the wind arrow once the track gives
    /// an estimate, and tacks and gybes (docs/metrics.md, "Sailing wind and VMG").
    private func sailingCard(_ sailing: SailingReadings, course: Double?, display: LiveDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Sailing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let wind = sailing.windFrom {
                    WindArrow(windFrom: wind, course: course, resolved: sailing.resolved, size: 52)
                }
            }
            let column = GridItem(.flexible(), alignment: .leading)
            LazyVGrid(columns: [column, column], alignment: .leading, spacing: 12) {
                ForEach(sailingMetrics(sailing, course: course, display: display)) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        metric.caption.font(.caption)
                        metric.reading(numberFont: .title3.weight(.semibold), unitFont: .footnote)
                    }
                }
            }
            Text(
                sailing.windFrom == nil
                    ? "Wind appears after a tack, once both tacks have some time."
                    : sailing.resolved
                        ? "Wind estimated from your tacks. Not for navigation."
                        : "Wind axis from your legs; which side the wind is on is not known yet. Not for navigation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.sailing")
    }

    private func sailingMetrics(_ sailing: SailingReadings, course: Double?, display: LiveDisplay) -> [LiveMetric] {
        [
            LiveMetric(id: "metric.vmg", title: sailing.vmgTitle, text: display.vmg(sailing.vmg)),
            LiveMetric(id: "metric.heading", title: "Heading", text: LiveDisplay.course(course)),
            LiveMetric(id: "metric.wind", title: "\(sailing.windTitle) (est.)", text: sailing.windText),
            LiveMetric(id: "metric.windAngle", title: sailing.angleTitle, text: sailing.angleText),
        ] + sailing.maneuverRows.map { LiveMetric(id: "metric.\($0.id)", title: $0.title, text: "\($0.count)") }
    }

    private func metricRow(_ metric: LiveMetric) -> some View {
        let reading = metric.reading(numberFont: .title2.weight(.semibold), unitFont: .footnote)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                metric.caption.font(.caption).fixedSize()
                Spacer(minLength: 0)
                reading.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                metric.caption.font(.caption)
                reading
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A formatted live reading and its spoken label. Display units and rounding come from LiveDisplay.
private struct LiveMetric: Identifiable {
    let id: String
    let title: String
    let text: String

    var caption: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    func reading(numberFont: Font, unitFont: Font) -> some View {
        // LiveDisplay renders a quantity with its unit after a space, except degrees.
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let degrees = text.hasSuffix("°")
        let number = degrees ? String(text.dropLast()) : parts.first ?? text
        let unit = degrees ? "°" : parts.dropFirst().first
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(number)
                .font(numberFont.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let unit {
                Text(unit)
                    .font(unitFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue(number: number, unit: unit))
        .accessibilityIdentifier(id)
    }

    private func spokenValue(number: String, unit: String?) -> String {
        switch unit {
        case "kn": "\(number) knots"
        case "km/h": "\(number) kilometers per hour"
        case "mph": "\(number) miles per hour"
        case "m/s": "\(number) meters per second"
        case "m": "\(number) meters"
        case "km": "\(number) kilometers"
        case "nm": "\(number) nautical miles"
        case "mi": "\(number) miles"
        case "bpm": "\(number) beats per minute"
        case "spm": "\(number) strokes per minute"
        case "ft": "\(number) feet"
        case "°": "\(number) degrees true"
        case "stbd": "\(number) starboard"
        case "port": "\(number) port"
        default: text == "–" ? "Unavailable" : text
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
    let showManOverboard: () -> Void
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
                    recordingActionLabel("Lap", systemImage: "stopwatch")
                }
                .accessibilityIdentifier("control.lap")
                Button {
                    recorder.mark()
                } label: {
                    recordingActionLabel("Mark", systemImage: "flag")
                }
                .accessibilityIdentifier("control.mark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.body.weight(.semibold))

            // Pause and MOB side by side, or stacked when large text doesn't fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pauseButton
                    manOverboardButton.frame(width: 132)
                }
                VStack(spacing: 10) {
                    pauseButton
                    manOverboardButton
                }
            }
        }
    }

    private var pauseButton: some View {
        Button {
            recorder.pause()
        } label: {
            Label("Pause", systemImage: "pause.fill")
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("control.pause")
    }

    private var manOverboardButton: some View {
        PhoneManOverboardControl(show: showManOverboard)
    }

    private func recordingActionLabel(_ title: String, systemImage: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: systemImage).fixedSize()
            Text(title).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
    }

    @ViewBuilder private var pausedButtons: some View {
        Button {
            recorder.resume()
        } label: {
            Label("Resume", systemImage: "play.fill")
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("control.pause")
        Button {
            saving = true
            Task { await recorder.stop() }
        } label: {
            Label("Save", systemImage: "checkmark")
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .disabled(saving)
        .accessibilityHint("Ends and saves the session")
        .accessibilityIdentifier("control.save")
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
            // Side by side, or stacked when large text doesn't fit on one line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { pausedButtons }
                VStack(spacing: 10) { pausedButtons }
            }
            .buttonBorderShape(.capsule)
            .font(.title3.weight(.bold))
            // Still on the water while paused: MOB stays one hold away.
            manOverboardButton
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

/// The live track, following the current position. Display only, like the watch.
private struct LiveTrackMap: View {
    let points: [SessionRecorder.TrackPoint]
    var manOverboard: ManOverboard.Mark?

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .userLocation(followsHeading: false, fallback: .automatic), interactionModes: []) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates).stroke(Color.accentColor, lineWidth: 4)
            }
            if let manOverboard {
                Marker(
                    "MOB", systemImage: "figure.wave",
                    coordinate: CLLocationCoordinate2D(latitude: manOverboard.latitude, longitude: manOverboard.longitude)
                )
                .tint(.red)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottomLeading) {
            if manOverboard != nil { NotForNavigationLabel() }
        }
    }
}

#Preview {
    ContentView()
}
