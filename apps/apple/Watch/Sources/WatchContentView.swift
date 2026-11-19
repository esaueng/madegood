import HealthKit
import MapKit
import SwiftUI
import WatchKit
import WaterKit

/// Watch app: pick a sport, count down if the sport has a countdown, record with live
/// metrics, a map and controls, then see a summary. Finished recordings are sent to the
/// iPhone and removed once delivered.
struct WatchContentView: View {
    @State private var controller = SessionController.shared
    @State private var waiting: [RecordingStore.Entry] = []
    @State private var summary: Summary?
    @State private var manOverboard = ManOverboard.shared

    struct Summary: Identifiable {
        let id = UUID()
        let sport: Sport
        let metrics: LiveMetrics
        var strokes: StrokeDetector.Metrics?
        var savedToHealth = false
    }

    private var recorder: SessionRecorder { controller.recorder }

    var body: some View {
        NavigationStack {
            if let countdown = controller.countdown {
                CountdownView(controller: controller, countdown: countdown)
            } else {
                switch recorder.state {
                case .idle where manOverboard.mark != nil:
                    // An active mark outlives the session (and relaunches) until cleared.
                    ManOverboardPage(
                        manOverboard: manOverboard, sport: controller.sport ?? .sailing,
                        newSession: {
                            AnyView(StartScreen(controller: controller, waiting: waiting, showsAbout: false))
                        }
                    )
                    .onAppear { manOverboard.startOwnUpdates() }
                    .onDisappear { manOverboard.stopOwnUpdates() }
                case .idle:
                    StartScreen(controller: controller, waiting: waiting)
                case .starting, .stopping:
                    ProgressView()
                case .recording(_, let startedAt, let sport):
                    SessionPages(recorder: recorder, startedAt: startedAt, sport: sport)
                }
            }
        }
        #if DEBUG
            // UI tests can't press the Action button: `-uiTestActionButton` adds a stand-in.
            .overlay(alignment: .topLeading) {
                if UserDefaults.standard.bool(forKey: "uiTestActionButton") {
                    Button("Action") { SessionController.shared.actionButtonPressed() }
                        .accessibilityIdentifier("debug.actionButton")
                        .font(.caption2)
                        .buttonStyle(.plain)
                }
            }
        #endif
        .sheet(item: $summary) { summary in
            SummaryView(summary: summary)
        }
        .onAppear {
            controller.onFinish = { sport, metrics, folder in
                if let metrics {
                    summary = Summary(
                        sport: sport, metrics: metrics, strokes: recorder.strokes, savedToHealth: recorder.savedToHealth)
                }
                RecordingTransfer.shared.send(folder: folder)
                reload()
            }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didDeliverRecording)) { _ in
            reload()
        }
    }

    private func reload() {
        waiting = RecordingStore.list()
    }
}

// MARK: - Start

/// Large sport cards, most recently used first (docs/PLAN.md §6). Tapping a card starts
/// that sport; its settings button opens the sport's settings.
private struct StartScreen: View {
    let controller: SessionController
    let waiting: [RecordingStore.Entry]
    /// Off when pushed from the man-overboard page, where the corner holds Back.
    var showsAbout = true
    @State private var store = SettingsStore.shared
    @State private var settingsSport: Sport?
    @State private var titleScale: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(store.startList(), id: \.self) { sport in
                    SportCard(
                        sport: sport, detail: detail(for: sport), countdownMinutes: store[sport].countdownMinutes,
                        titleScale: titleScale, start: { controller.begin(sport) }, openSettings: { settingsSport = sport })
                }
                if let error = controller.recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(waiting.count) waiting for iPhone", systemImage: "iphone.and.arrow.forward")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Send again") {
                            RecordingTransfer.shared.sendAllPending()
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onPreferenceChange(TitleScaleKey.self) { scale in
            titleScale = max(0.7, scale)
        }
        .navigationTitle(AppInfo.name)
        .toolbar {
            if showsAbout {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        WatchAboutView(waiting: waiting.count)
                    } label: {
                        Image(systemName: "info")
                    }
                    .accessibilityLabel("About and permissions")
                    .accessibilityIdentifier("start.about")
                }
            }
        }
        .navigationDestination(item: $settingsSport) { sport in
            SportSettingsForm(sport: sport)
        }
    }

    private func detail(for sport: Sport) -> String? {
        guard let last = store.lastSessions[sport] else { return nil }
        return LastSessionText.text(
            distance: last.distance, date: last.date, unit: store[sport].resolvedDistanceUnit(for: sport))
    }
}

private struct SportCard: View {
    let sport: Sport
    let detail: String?
    let countdownMinutes: Int
    /// Shared by every card so the titles stay one size (see `TitleScaleKey`).
    let titleScale: CGFloat
    let start: () -> Void
    let openSettings: () -> Void
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    @State private var titleWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Button(action: start) {
                HStack(spacing: 8) {
                    SportIcon(sport: sport, size: 24)
                        .foregroundStyle(Theme.pearl)
                        .frame(width: 32, height: 32)
                        .background(Theme.brightPetrol.opacity(isLuminanceReduced ? 0.4 : 1), in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        title
                        subtitle
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
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
                    .font(.system(size: 17))
                    .frame(width: 34, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.pearl.opacity(0.9))
            .padding(.trailing, 2)
            .accessibilityLabel("\(sport.displayName) settings")
            .accessibilityIdentifier("sportSettings.open.\(sport.rawValue)")
        }
        .background(
            Theme.petrol.opacity(isLuminanceReduced ? 0.25 : 0.55),
            in: .rect(cornerRadius: 22, style: .continuous)
        )
        .preference(key: TitleScaleKey.self, value: fittingScale)
    }

    private var title: some View {
        Text(sport.displayName)
            .font(.system(size: titleSize * titleScale, weight: .semibold))
            // No per-card shrinking, so every title stays the shared size. A name that
            // still doesn't fit at the smallest shared scale wraps instead.
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .background {
                // The name's width at full size, to work out the scale it needs.
                Text(sport.displayName)
                    .font(.system(size: titleSize, weight: .semibold))
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
            }
    }

    @ViewBuilder private var subtitle: some View {
        Group {
            if let detail {
                Text(detail).monospacedDigit()
            } else if countdownMinutes > 0 {
                Label("\(countdownMinutes) min countdown", systemImage: "timer")
            } else {
                Text("Tap to start")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// The scale at which this card's name fits on one line, at most 1.
    private var fittingScale: CGFloat {
        guard titleWidth > 0, availableWidth > 0, titleWidth > availableWidth else { return 1 }
        // A little slack, as glyph widths don't scale exactly with point size.
        return availableWidth * 0.98 / titleWidth
    }
}

/// The smallest title scale any sport card needs, so every card can use it and the
/// titles on the start screen stay one size.
private struct TitleScaleKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// The countdown before recording: a ring and the time left, with Sync for race starts.
/// Sailing adds a second page for the start line.
private struct CountdownView: View {
    let controller: SessionController
    let countdown: SessionController.Countdown

    var body: some View {
        if countdown.sport == .sailing {
            TabView {
                CountdownTimerPage(controller: controller, countdown: countdown)
                StartLinePage(countdown: countdown)
            }
            .tabViewStyle(.verticalPage)
            .toolbar(.hidden, for: .navigationBar)
        } else {
            CountdownTimerPage(controller: controller, countdown: countdown)
        }
    }
}

/// The start line during a sailing countdown (docs/metrics.md, "Start line").
private struct StartLinePage: View {
    let countdown: SessionController.Countdown
    @State private var startLine = StartLineController.shared
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 1 : 0.5)) { _ in
            ScrollView {
                StartLinePanel(
                    startLine: startLine, remaining: countdown.timer.remaining(at: SessionController.now),
                    display: UserSettings.display(for: .sailing), compact: true
                )
                // Clear of the page indicator on the right edge.
                .padding(.trailing, 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct CountdownTimerPage: View {
    let controller: SessionController
    let countdown: SessionController.Countdown
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 1 : 0.25)) { _ in
            let now = SessionController.now
            let seconds = countdown.timer.displaySeconds(at: now)
            let fraction =
                countdown.timer.duration > 0 ? countdown.timer.remaining(at: now) / countdown.timer.duration : 0
            let isFinal = seconds <= 10
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Theme.brightPetrol.opacity(0.25), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(
                            isFinal ? Theme.coral : Theme.brightPetrol, style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(countdown.sport.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Formatting.elapsed(Double(seconds)))
                            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(isFinal ? Theme.coral : .primary)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .accessibilityLabel("\(seconds) seconds to start")
                            .accessibilityIdentifier("countdown.time")
                    }
                    .padding(.horizontal, 14)
                }
                .frame(maxWidth: 130, maxHeight: 130)
                HStack(spacing: 6) {
                    Button(role: .cancel) {
                        controller.cancelCountdown()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel countdown")
                    .accessibilityIdentifier("countdown.cancel")
                    if countdown.canSync {
                        Button {
                            controller.sync()
                        } label: {
                            Text("Sync").font(.footnote.weight(.semibold))
                        }
                        .tint(Theme.brightPetrol)
                        .accessibilityHint("Rounds to the nearest minute")
                        .accessibilityIdentifier("countdown.sync")
                    }
                    Button {
                        controller.startNow()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .tint(.green)
                    .accessibilityLabel("Start now")
                    .accessibilityIdentifier("countdown.startNow")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// App-wide items: permissions, delivery to the iPhone, version.
private struct WatchAboutView: View {
    let waiting: Int

    private var locationStatus: String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: "Allowed"
        case .denied, .restricted: "Off"
        case .notDetermined: "Not asked"
        @unknown default: "Unknown"
        }
    }

    private var healthStatus: String {
        guard HKHealthStore.isHealthDataAvailable() else { return "Unavailable" }
        return switch HKHealthStore().authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: "Allowed"
        case .sharingDenied: "Off"
        case .notDetermined: "Not asked"
        @unknown default: "Unknown"
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Location", value: locationStatus)
                LabeledContent("Health", value: healthStatus)
            } header: {
                Text("Permissions")
            } footer: {
                Text("MadeGood asks the first time you start a session. Change access in the Settings app.")
            }
            Section("iPhone") {
                LabeledContent("Waiting to send", value: "\(waiting)")
                Text("Settings you change here or on iPhone stay in sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                Text("Routes and charts are not for navigation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(AppInfo.name)
    }
}

// MARK: - Session

private struct SessionPages: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @State private var page: Page
    @State private var manOverboard = ManOverboard.shared
    @State private var startLine = StartLineController.shared
    @State private var banner: SessionRecorder.DistanceAlertEvent?
    private let hero: LiveScreen

    enum Page { case manOverboard, controls, metrics, strokes, speed, sailing, map }

    init(recorder: SessionRecorder, startedAt: Date, sport: Sport) {
        self.recorder = recorder
        self.startedAt = startedAt
        self.sport = sport
        // Opens on the sport's first screen (its settings); the map has its own page.
        let first = UserSettings.settings(for: sport).firstScreen
        _page = State(initialValue: first == .map ? .map : .metrics)
        hero = first == .map ? .speed : first
    }

    var body: some View {
        TabView(selection: $page) {
            if manOverboard.mark != nil {
                ManOverboardPage(manOverboard: manOverboard, sport: sport).tag(Page.manOverboard)
            }
            ControlsPage(recorder: recorder) { page = .manOverboard }.tag(Page.controls)
            MetricsPage(recorder: recorder, startedAt: startedAt, sport: sport, hero: hero).tag(Page.metrics)
            if sport.isPaddling {
                StrokesPage(recorder: recorder, startedAt: startedAt, sport: sport).tag(Page.strokes)
            }
            if UserSettings.profile(for: sport).tracksSpeedCategories {
                SpeedPage(recorder: recorder, sport: sport).tag(Page.speed)
            }
            if UserSettings.profile(for: sport).tracksSailing {
                SailingPage(recorder: recorder, sport: sport).tag(Page.sailing)
            }
            MapPage(points: recorder.trackPoints, manOverboard: manOverboard.mark).tag(Page.map)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
                if let warning = startLine.warning {
                    OCSBanner(warning: warning, display: UserSettings.display(for: sport), compact: true) {
                        startLine.dismissWarning()
                    }
                }
                if let failed = startLine.failedAtStart {
                    PingFailedBanner(end: failed, compact: true) { startLine.dismissFailedAtStart() }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.snappy, value: startLine.warning)
        .animation(.snappy, value: startLine.failedAtStart)
        .overlay(alignment: .bottom) {
            if let banner {
                DistanceAlertBanner(text: UserSettings.display(for: sport).distance(banner.distance))
                    .accessibilityLabel("Distance alert, \(UserSettings.display(for: sport).distance(banner.distance))")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: banner)
        // A new mark from anywhere (the controls or the Action button), including one that
        // replaces an earlier mark, shows the way back.
        .onChange(of: manOverboard.mark) { old, new in
            // Wait a turn: the page only exists once the mark has redrawn the pages.
            if let new, new != old { Task { @MainActor in page = .manOverboard } }
        }
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

private struct MetricsPage: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    /// The metric shown large (the sport's first screen).
    let hero: LiveScreen
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let display = UserSettings.display(for: sport)
        let metrics = recorder.metrics
        // Always-on updates about once a minute, so seconds would just be wrong.
        TimelineView(.periodic(from: startedAt, by: isLuminanceReduced ? 60 : 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let time = isLuminanceReduced ? Formatting.duration(elapsed) : Formatting.elapsed(elapsed)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    SportIcon(sport: sport, size: 18, labeled: true)
                    if let state = metrics?.pauseState, let label = LiveDisplay.pauseLabel(state) {
                        Text(label).foregroundStyle(.yellow)
                            .accessibilityIdentifier("pauseBadge")
                    } else if let lap = LiveDisplay.lapLabel(metrics) {
                        Text(lap).foregroundStyle(Theme.brightPetrol)
                            .accessibilityIdentifier("metric.lap")
                    }
                    Spacer()
                    if hero != .time {
                        Text(time).monospacedDigit()
                    }
                }
                .font(.footnote)
                Text(heroValue(display: display, metrics: metrics, time: time))
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityHint(hero.title)
                    .accessibilityIdentifier("metric.\(hero.rawValue)")
                if hero != .speed {
                    Field(label: "Speed", value: display.speed(metrics?.speed))
                }
                if hero != .distance {
                    Field(label: "Distance", value: display.distance(metrics?.distance ?? 0))
                }
                if !isLuminanceReduced {
                    Field(label: "Avg", value: display.speed(metrics?.averageSpeed))
                    if hero == .speed || hero == .heartRate {
                        Field(label: "Max 10 s", value: display.speed(metrics?.maxSpeed10s))
                    }
                    if hero != .heartRate {
                        Field(label: "HR", value: LiveDisplay.heartRate(metrics?.heartRate))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heroValue(display: LiveDisplay, metrics: LiveMetrics?, time: String) -> String {
        switch hero {
        case .speed, .map: display.speed(metrics?.speed)
        case .distance: display.distance(metrics?.distance ?? 0)
        case .time: time
        case .heartRate: LiveDisplay.heartRate(metrics?.heartRate)
        }
    }
}

/// The paddling sport page (PLAN §6): stroke rate large, then strokes and distance per stroke.
private struct StrokesPage: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let display = UserSettings.display(for: sport)
        let metrics = recorder.metrics
        let strokes = recorder.strokes
        TimelineView(.periodic(from: startedAt, by: isLuminanceReduced ? 60 : 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    SportIcon(sport: sport, size: 18, labeled: true)
                    Spacer()
                    Text(isLuminanceReduced ? Formatting.duration(elapsed) : Formatting.elapsed(elapsed))
                        .monospacedDigit()
                }
                .font(.footnote)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(strokes?.strokeRate.map { "\(Int($0.rounded()))" } ?? "–")
                        .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("spm").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Stroke rate")
                .accessibilityValue(strokes?.strokeRate.map { "\(Int($0.rounded())) strokes per minute" } ?? "Unavailable")
                .accessibilityIdentifier("metric.strokeRate")
                Field(label: "Strokes", value: LiveDisplay.strokeCount(strokes?.strokeCount))
                Field(
                    label: "Per stroke",
                    value: display.distancePerStroke(distance: metrics?.distance ?? 0, strokes: strokes?.strokeCount))
                if !isLuminanceReduced {
                    Field(label: "Speed", value: display.speed(metrics?.speed))
                    if let switches = strokes?.sideSwitches, sport != .kayak {
                        Field(label: "Switches", value: "\(switches)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Windsurfing: the speedsurfing categories (docs/metrics.md), two columns so all eight
/// fit without scrolling, which would fight the vertical page swipes.
private struct SpeedPage: View {
    let recorder: SessionRecorder
    let sport: Sport
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let display = UserSettings.display(for: sport)
        let categories = recorder.metrics?.speedCategories ?? SpeedCategories()
        let rows = SpeedCategoryReadings(categories).rows
        VStack(alignment: .leading, spacing: 4) {
            Text("Speed bests")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.brightPetrol)
                .accessibilityIdentifier("page.speed")
            ForEach(0..<(rows.count + 1) / 2, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(rows[(line * 2)..<min(rows.count, line * 2 + 2)]) { row in
                        VStack(alignment: .leading, spacing: -2) {
                            Text(row.shortTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(display.speed(row.value))
                                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(isLuminanceReduced ? .secondary : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.title)
                        .accessibilityValue(display.speed(row.value))
                        .accessibilityIdentifier(row.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The sailing sport page (PLAN §6): VMG large, heading, the wind arrow once the track
/// gives an estimate, and the maneuver count (docs/metrics.md, "Sailing wind and VMG").
private struct SailingPage: View {
    let recorder: SessionRecorder
    let sport: Sport
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let display = UserSettings.display(for: sport)
        let metrics = recorder.metrics
        let sailing = metrics?.sailing.map(SailingReadings.init)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sailing")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.brightPetrol)
                        .accessibilityIdentifier("page.sailing")
                    Text(sailing?.vmgTitle ?? "VMG")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let wind = sailing?.windFrom {
                    WindArrow(windFrom: wind, course: metrics?.course, resolved: sailing?.resolved ?? false, size: 40)
                        .opacity(isLuminanceReduced ? 0.6 : 1)
                }
            }
            Text(display.vmg(sailing?.vmg))
                .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel(sailing?.vmgTitle ?? "VMG")
                .accessibilityValue(sailing?.vmg == nil ? "Unavailable" : display.vmg(sailing?.vmg))
                .accessibilityIdentifier("metric.vmg")
            Field(label: "Heading", value: LiveDisplay.course(metrics?.course))
            Field(label: sailing?.windTitle ?? "Wind axis", value: sailing?.windText ?? "–")
            ForEach(sailing?.maneuverRows ?? [("maneuvers", "Tacks/gybes", 0)], id: \.id) { row in
                Field(label: row.title, value: "\(row.count)")
            }
            if !isLuminanceReduced, let sailing, sailing.trueWindAngle != nil {
                Field(label: sailing.angleTitle, value: sailing.angleText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Field: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
                .accessibilityIdentifier("field.\(label)")
        }
        .font(.body)
    }
}

private struct MapPage: View {
    let points: [SessionRecorder.TrackPoint]
    let manOverboard: ManOverboard.Mark?

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        // Display only: an interactive map takes the swipes and the Digital Crown, which
        // trapped the user on this page. It follows the current position instead.
        Map(initialPosition: .userLocation(followsHeading: false, fallback: .automatic), interactionModes: []) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates).stroke(.cyan, lineWidth: 3)
            }
            if let manOverboard {
                Marker(
                    "MOB", systemImage: "figure.wave",
                    coordinate: CLLocationCoordinate2D(
                        latitude: manOverboard.latitude, longitude: manOverboard.longitude)
                )
                .tint(.red)
            }
            UserAnnotation()
        }
        .accessibilityIdentifier("page.map")
    }
}

private struct ControlsPage: View {
    let recorder: SessionRecorder
    let showManOverboard: () -> Void
    @State private var confirmEnd = false

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                ControlButton(
                    title: recorder.isPaused ? "Resume" : "Pause",
                    symbol: recorder.isPaused ? "play.fill" : "pause.fill", tint: .yellow
                ) {
                    if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                    WKInterfaceDevice.current().play(recorder.isPaused ? .stop : .start)
                }
                ControlButton(title: "Lap", symbol: "stopwatch", tint: .blue) {
                    SessionController.shared.lap()
                }
            }
            GridRow {
                ControlButton(title: "MOB", symbol: "figure.wave", tint: .red) {
                    recorder.markManOverboard()
                    WKInterfaceDevice.current().play(.notification)
                    if ManOverboard.shared.mark != nil { showManOverboard() }
                }
                ControlButton(title: "Lock", symbol: "drop.fill", tint: .cyan) {
                    // Water lock ignores taps until the user turns the Digital Crown.
                    WKInterfaceDevice.current().enableWaterLock()
                }
            }
            GridRow {
                ControlButton(title: "Mark", symbol: "flag.fill", tint: .teal) {
                    recorder.mark()
                    WKInterfaceDevice.current().play(.click)
                }
                ControlButton(title: "End", symbol: "xmark", tint: .red) { confirmEnd = true }
            }
        }
        .confirmationDialog("End session?", isPresented: $confirmEnd) {
            Button("End", role: .destructive) {
                Task { await recorder.stop() }
            }
        }
    }
}

/// Bearing and distance back to the man-overboard mark. Guidance needs a position from
/// the last 10 s; the arrow is relative to the course only while moving at 0.5 m/s or
/// more, and points from true north otherwise.
struct ManOverboardPage: View {
    let manOverboard: ManOverboard
    let sport: Sport
    /// Shown outside a session: lets the user record again without clearing the mark.
    var newSession: (() -> AnyView)?

    var body: some View {
        let display = UserSettings.display(for: sport)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(spacing: 4) {
                    let _ = context.date  // re-evaluate freshness every second
                    if let guidance = manOverboard.guidance() {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.red)
                            .rotationEffect(.degrees(guidance.arrow))
                            .accessibilityLabel("Bearing \(Int(guidance.bearing.rounded())) degrees")
                        Text(display.distance(guidance.distance))
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .accessibilityIdentifier("mob.distance")
                        Text(
                            "Man overboard · \(Int(guidance.bearing.rounded()))°\(guidance.isCourseRelative ? "" : " true")"
                        )
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.red)
                    } else {
                        Image(systemName: "location.slash").font(.title).foregroundStyle(.red)
                        Text("Man overboard").font(.headline).foregroundStyle(.red)
                        Text("Waiting for GPS").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("mob.waiting")
                    }
                    if let mark = manOverboard.mark {
                        if mark.positionAge > ManOverboard.freshFor {
                            Text("Marked from a fix \(Formatting.duration(mark.positionAge)) old")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Text(mark.markedAt, style: .relative).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let newSession {
                        NavigationLink("New session") { newSession() }
                            .accessibilityIdentifier("mob.newSession")
                    }
                    Button("Clear", role: .destructive) { manOverboard.clear() }
                        .accessibilityIdentifier("mob.clear")
                }
            }
        }
    }
}

private struct ControlButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.footnote)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .tint(tint)
        .accessibilityIdentifier("control.\(title.lowercased())")
    }
}

// MARK: - Summary

private struct SummaryView: View {
    let summary: WatchContentView.Summary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let display = UserSettings.display(for: summary.sport)
        let metrics = summary.metrics
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(summary.sport.displayName)
                } icon: {
                    SportIcon(sport: summary.sport, size: 20)
                }
                    .font(.headline)
                Field(label: "Time", value: Formatting.elapsed(metrics.elapsed))
                Field(label: "Moving", value: Formatting.elapsed(metrics.movingTime))
                Field(label: "Distance", value: display.distance(metrics.distance))
                Field(label: "Avg", value: display.speed(metrics.averageSpeed))
                Field(label: "Max 10 s", value: display.speed(metrics.maxSpeed10s))
                Field(label: "Max 2 s", value: display.speed(metrics.maxSpeed2s))
                Field(label: "Avg HR", value: LiveDisplay.heartRate(metrics.heartRateAverage))
                if let strokes = summary.strokes {
                    Field(label: "Strokes", value: LiveDisplay.strokeCount(strokes.strokeCount))
                    Field(
                        label: "Per stroke",
                        value: display.distancePerStroke(distance: metrics.distance, strokes: strokes.strokeCount))
                }
                if let categories = metrics.speedCategories {
                    Text("Speed bests")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.brightPetrol)
                        .padding(.top, 4)
                    // The 2 s and 10 s bests are the max speeds above.
                    ForEach(SpeedCategoryReadings(categories).rows.dropFirst(2)) { row in
                        Field(label: row.title, value: display.speed(row.value))
                    }
                }
                if let live = metrics.sailing {
                    let sailing = SailingReadings(live)
                    ForEach(sailing.maneuverRows, id: \.id) { row in
                        Field(label: row.title, value: "\(row.count)")
                    }
                    if sailing.windFrom != nil {
                        Field(label: sailing.windTitle, value: sailing.windText)
                    }
                }
                if !metrics.laps.isEmpty {
                    Field(label: "Laps", value: "\(metrics.laps.count + 1)")
                }
                if summary.savedToHealth {
                    Label("Saved to Health", systemImage: "heart.fill")
                        .font(.footnote)
                        .foregroundStyle(.pink)
                }
                Button("Done") { dismiss() }
                    .padding(.top, 6)
                    .accessibilityIdentifier("summary.done")
            }
        }
    }
}

#Preview {
    WatchContentView()
}
