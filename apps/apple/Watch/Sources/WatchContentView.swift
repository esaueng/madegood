import MapKit
import SwiftUI
import WatchKit
import WaterKit

/// Watch app: pick a sport, record with live metrics, a map and controls, then see a
/// summary. Finished recordings are sent to the iPhone and removed once delivered.
struct WatchContentView: View {
    @State private var recorder = SessionRecorder()
    @State private var waiting: [RecordingStore.Entry] = []
    @State private var summary: Summary?
    @State private var manOverboard = ManOverboard.shared
    @AppStorage("watch.lastSport") private var lastSportRaw = ""

    struct Summary: Identifiable {
        let id = UUID()
        let sport: Sport
        let metrics: LiveMetrics
    }

    var body: some View {
        NavigationStack {
            switch recorder.state {
            case .idle where manOverboard.mark != nil:
                // An active mark outlives the session (and relaunches) until cleared.
                ManOverboardPage(manOverboard: manOverboard, sport: Sport(rawValue: lastSportRaw) ?? .sailing)
                    .onAppear { manOverboard.startOwnUpdates() }
                    .onDisappear { manOverboard.stopOwnUpdates() }
            case .idle:
                SportPicker(recorder: recorder, waiting: waiting, lastSport: Sport(rawValue: lastSportRaw)) { sport in
                    lastSportRaw = sport.rawValue
                    Task { await recorder.start(sport: sport) }
                }
            case .starting, .stopping:
                ProgressView()
            case .recording(_, let startedAt, let sport):
                SessionPages(recorder: recorder, startedAt: startedAt, sport: sport)
            }
        }
        .sheet(item: $summary) { summary in
            SummaryView(summary: summary)
        }
        .onAppear {
            recorder.onFinish = { folder in
                if let sport = Sport(rawValue: lastSportRaw), let metrics = recorder.metrics {
                    summary = Summary(sport: sport, metrics: metrics)
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

private struct SportPicker: View {
    let recorder: SessionRecorder
    let waiting: [RecordingStore.Entry]
    let lastSport: Sport?
    let start: (Sport) -> Void

    /// Last used first (docs/PLAN.md §6).
    private var sports: [Sport] {
        guard let lastSport else { return Sport.allCases }
        return [lastSport] + Sport.allCases.filter { $0 != lastSport }
    }

    var body: some View {
        List {
            ForEach(sports, id: \.self) { sport in
                Button {
                    start(sport)
                } label: {
                    Label(sport.displayName, systemImage: sport.symbolName)
                }
                .accessibilityIdentifier("sport.\(sport.rawValue)")
            }
            if let error = recorder.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !waiting.isEmpty {
                Section {
                    Label("\(waiting.count) waiting for iPhone", systemImage: "iphone.and.arrow.forward")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Send again") {
                        RecordingTransfer.shared.sendAllPending()
                    }
                }
            }
        }
        .navigationTitle("MadeGood")
    }
}

// MARK: - Session

private struct SessionPages: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @State private var page = Page.metrics
    @State private var manOverboard = ManOverboard.shared

    enum Page { case manOverboard, controls, metrics, map }

    var body: some View {
        TabView(selection: $page) {
            if manOverboard.mark != nil {
                ManOverboardPage(manOverboard: manOverboard, sport: sport).tag(Page.manOverboard)
            }
            ControlsPage(recorder: recorder) { page = .manOverboard }.tag(Page.controls)
            MetricsPage(recorder: recorder, startedAt: startedAt, sport: sport).tag(Page.metrics)
            MapPage(points: recorder.trackPoints, manOverboard: manOverboard.mark).tag(Page.map)
        }
        .tabViewStyle(.verticalPage)
    }
}

private struct MetricsPage: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let display = UserSettings.display(for: sport)
        let metrics = recorder.metrics
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(sport.displayName, systemImage: sport.symbolName)
                    .labelStyle(.iconOnly)
                if let state = metrics?.pauseState, let label = LiveDisplay.pauseLabel(state) {
                    Text(label).foregroundStyle(.yellow)
                        .accessibilityIdentifier("pauseBadge")
                } else if let lap = LiveDisplay.lapLabel(metrics) {
                    Text(lap).foregroundStyle(.blue)
                        .accessibilityIdentifier("metric.lap")
                }
                Spacer()
                // Always-on updates about once a minute, so seconds would just be wrong.
                TimelineView(.periodic(from: startedAt, by: isLuminanceReduced ? 60 : 1)) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt)
                    Text(isLuminanceReduced ? Formatting.duration(elapsed) : Formatting.elapsed(elapsed))
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            Text(display.speed(metrics?.speed))
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityIdentifier("metric.speed")
            Field(label: "Distance", value: display.distance(metrics?.distance ?? 0))
            if !isLuminanceReduced {
                Field(label: "Avg", value: display.speed(metrics?.averageSpeed))
                Field(label: "Max 10 s", value: display.speed(metrics?.maxSpeed10s))
                Field(label: "HR", value: LiveDisplay.heartRate(metrics?.heartRate))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    recorder.lap()
                    WKInterfaceDevice.current().play(.click)
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

    var body: some View {
        let display = UserSettings.display(for: sport)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                if let guidance = manOverboard.guidance(at: context.date) {
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
                Button("Clear", role: .destructive) { manOverboard.clear() }
                    .accessibilityIdentifier("mob.clear")
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
                Label(summary.sport.displayName, systemImage: summary.sport.symbolName)
                    .font(.headline)
                Field(label: "Time", value: Formatting.elapsed(metrics.elapsed))
                Field(label: "Moving", value: Formatting.elapsed(metrics.movingTime))
                Field(label: "Distance", value: display.distance(metrics.distance))
                Field(label: "Avg", value: display.speed(metrics.averageSpeed))
                Field(label: "Max 10 s", value: display.speed(metrics.maxSpeed10s))
                Field(label: "Max 2 s", value: display.speed(metrics.maxSpeed2s))
                Field(label: "Avg HR", value: LiveDisplay.heartRate(metrics.heartRateAverage))
                if !metrics.laps.isEmpty {
                    Field(label: "Laps", value: "\(metrics.laps.count + 1)")
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
