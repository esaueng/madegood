import MapKit
import SwiftUI
import WaterKit

/// The iPhone app: record, history, settings (docs/PLAN.md §6). Voyages arrive in Phase 5.
struct ContentView: View {
    @State private var recorder = SessionRecorder()
    @State private var library = SessionLibrary()
    @State private var tab = AppTab.record

    enum AppTab: Hashable { case record, history, settings }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Record", systemImage: "record.circle", value: AppTab.record) {
                RecordView(recorder: recorder, library: library)
            }
            Tab("History", systemImage: "list.bullet", value: AppTab.history) {
                HistoryView(library: library)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            recorder.onFinish = { _ in library.reload() }
            library.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didReceiveFile)) { _ in
            library.reload()
        }
    }
}

// MARK: - Record

private struct RecordView: View {
    let recorder: SessionRecorder
    let library: SessionLibrary
    @AppStorage("recorder.sport") private var sportRaw = Sport.kayak.rawValue

    var body: some View {
        NavigationStack {
            switch recorder.state {
            case .idle:
                StartView(recorder: recorder, library: library, sportRaw: $sportRaw)
            case .starting, .stopping:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .recording(_, let startedAt, let sport):
                LiveView(recorder: recorder, startedAt: startedAt, sport: sport)
            }
        }
    }
}

private struct StartView: View {
    let recorder: SessionRecorder
    let library: SessionLibrary
    @Binding var sportRaw: String

    private var sport: Sport { Sport(rawValue: sportRaw) ?? .kayak }
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Sport.allCases, id: \.self) { option in
                        SportTile(sport: option, isSelected: option == sport) { sportRaw = option.rawValue }
                    }
                }

                Button {
                    Task { await recorder.start(sport: sport) }
                } label: {
                    Label("Start \(sport.displayName)", systemImage: "play.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("control.start")

                if let error = recorder.lastError {
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
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle(AppInfo.name)
        .navigationDestination(for: SessionLibrary.Item.self) { item in
            SessionDetailView(item: item, library: library)
        }
    }
}

private struct SportTile: View {
    let sport: Sport
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Image(systemName: sport.symbolName).font(.title2)
                Text(sport.displayName).font(.footnote.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background.secondary),
                in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sport.\(sport.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The live session: the numbers that matter at a glance, a small map, and controls.
private struct LiveView: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @State private var confirmStop = false

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

                VStack(spacing: 0) {
                    Text(display.speed(metrics?.speed))
                        .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .accessibilityIdentifier("metric.speed")
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Formatting.elapsed(context.date.timeIntervalSince(startedAt)))
                            .font(.title2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        StatTile(
                            title: "Distance", value: display.distance(metrics?.distance ?? 0),
                            identifier: "metric.distance")
                        StatTile(title: "Moving", value: Formatting.elapsed(metrics?.movingTime ?? 0))
                    }
                    GridRow {
                        StatTile(title: "Average", value: display.speed(metrics?.averageSpeed))
                        StatTile(title: "Max 10 s", value: display.speed(metrics?.maxSpeed10s))
                    }
                    GridRow {
                        StatTile(title: "Heart rate", value: LiveDisplay.heartRate(metrics?.heartRate))
                        StatTile(title: "Course", value: LiveDisplay.course(metrics?.course))
                    }
                }
                .padding()
                .background(.background.secondary, in: .rect(cornerRadius: 12))

                LiveTrackMap(points: recorder.trackPoints)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 12))

                HStack(spacing: 10) {
                    LiveControl(
                        title: recorder.isPaused ? "Resume" : "Pause",
                        symbol: recorder.isPaused ? "play.fill" : "pause.fill", identifier: "control.pause"
                    ) {
                        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                    }
                    LiveControl(title: "Lap", symbol: "stopwatch", identifier: "control.lap") { recorder.lap() }
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
