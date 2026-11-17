import Charts
import MapKit
import SwiftUI
import WaterKit

/// One session: a map colored by speed, the stats, speed and heart-rate charts, laps,
/// and export. Everything is recomputed from the raw recording by `SessionReplay`.
struct SessionDetailView: View {
    let item: SessionLibrary.Item
    let library: SessionLibrary

    @State private var analysis: Analysis?
    @State private var failed = false
    @State private var share: ShareFile?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    struct Analysis {
        var session: RawSession
        var replay: SessionReplay
    }

    struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Group {
            if let analysis {
                content(analysis)
            } else if failed {
                ContentUnavailableView(
                    "Can't read this recording", systemImage: "exclamationmark.triangle",
                    description: Text("It may still be arriving from the watch."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(item.entry.meta?.sport.displayName ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $share) { file in
            ShareSheet(url: file.url)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(item)
                dismiss()
            }
        } message: {
            Text("The recording is removed from this iPhone.")
        }
    }

    private func load() async {
        let folder = item.entry.folder
        let result = await Task.detached(priority: .userInitiated) { () -> Analysis? in
            guard let session = try? RawSessionReader.read(folder: folder, includeMotion: false) else { return nil }
            let replay = SessionReplay(track: session.track(), profile: UserSettings.profile(for: session.meta.sport))
            return Analysis(session: session, replay: replay)
        }.value
        analysis = result
        failed = result == nil
    }

    @ViewBuilder
    private func content(_ analysis: Analysis) -> some View {
        let sport = analysis.session.meta.sport
        let display = UserSettings.display(for: sport)
        let metrics = analysis.replay.metrics
        List {
            Section {
                Label {
                    Text(
                        analysis.session.startedAt,
                        format: .dateTime.weekday(.wide).day().month().year().hour().minute())
                } icon: {
                    Image(systemName: sport.symbolName).foregroundStyle(Color.accentColor)
                }
                .font(.headline)
                if analysis.replay.fixes.count > 1 {
                    SpeedMap(fixes: analysis.replay.fixes)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                    if let range = SpeedSegments.range(analysis.replay.fixes), range.high > range.low {
                        HStack(spacing: 8) {
                            Text(display.speed(range.low))
                            Capsule()
                                .fill(
                                    LinearGradient(colors: Theme.speedScale, startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(height: 6)
                            Text(display.speed(range.high))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("map.legend")
                    }
                }
            }

            Section {
                Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        StatTile(title: "Distance", value: display.distance(metrics.distance))
                        StatTile(title: "Moving time", value: Formatting.elapsed(metrics.movingTime))
                    }
                    GridRow {
                        StatTile(title: "Average", value: display.speed(metrics.averageSpeed))
                        StatTile(title: "Total time", value: Formatting.elapsed(metrics.elapsed))
                    }
                    GridRow {
                        StatTile(title: "Max 10 s", value: display.speed(metrics.maxSpeed10s))
                        StatTile(title: "Max 2 s", value: display.speed(metrics.maxSpeed2s))
                    }
                    if metrics.heartRateAverage != nil {
                        GridRow {
                            StatTile(title: "Avg heart rate", value: LiveDisplay.heartRate(metrics.heartRateAverage))
                            StatTile(title: "Max heart rate", value: LiveDisplay.heartRate(metrics.heartRateMax))
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            let speeds = ChartSeries.speed(analysis.replay.fixes, display: display)
            if speeds.count > 1 {
                Section("Speed (\(display.speed.symbol))") {
                    Chart(speeds) { point in
                        AreaMark(x: .value("Minutes", point.minutes), y: .value("Speed", point.value))
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                        LineMark(x: .value("Minutes", point.minutes), y: .value("Speed", point.value))
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartXAxisLabel("min")
                    .frame(height: 160)
                    .accessibilityIdentifier("chart.speed")
                }
            }
            let heartRate = ChartSeries.heartRate(analysis.session.hr)
            if heartRate.count > 1 {
                Section("Heart rate (bpm)") {
                    Chart(heartRate) { point in
                        LineMark(x: .value("Minutes", point.minutes), y: .value("bpm", point.value))
                            .foregroundStyle(Theme.coral)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxisLabel("min")
                    .frame(height: 140)
                }
            }

            if !metrics.laps.isEmpty {
                Section("Laps") {
                    ForEach(metrics.laps + [metrics.currentLap], id: \.index) { lap in
                        HStack {
                            Text("Lap \(lap.index)").font(.body.weight(.medium))
                            if lap.isAuto { Text("auto").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(display.distance(lap.distance)).monospacedDigit()
                            Text(Formatting.elapsed(lap.movingTime)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                Button {
                    exportGPX(analysis)
                } label: {
                    Label("Export GPX", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export.gpx")
                Button {
                    exportZip()
                } label: {
                    Label("Share raw recording", systemImage: "doc.zipper")
                }
            } footer: {
                Text(
                    "Exports contain precise locations and times. Anonymize raw recordings before posting them publicly."
                )
            }

            Section {
                if analysis.session.meta.endedAt == nil {
                    Label(
                        "This recording did not stop cleanly; it holds everything saved before it ended.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                }
                LabeledContent("Device", value: analysis.session.meta.device.model)
                LabeledContent("GPS fixes", value: "\(analysis.session.gps.count) (\(metrics.rejectedFixes) rejected)")
                Button("Delete session", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private func exportGPX(_ analysis: Analysis) {
        let track = analysis.session.track()
        let name = "\(track.sport.rawValue)-\(Int(track.startedAt.timeIntervalSince1970)).gpx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try GPXWriter().data(for: track).write(to: url, options: .atomic)
            share = ShareFile(url: url)
        } catch {
            failed = true
        }
    }

    private func exportZip() {
        if let url = try? ZipExport.zip(folder: item.entry.folder) { share = ShareFile(url: url) }
    }
}

/// The track as polylines colored from slow to fast (Theme.speedScale).
private struct SpeedMap: View {
    let fixes: [GPSFix]

    var body: some View {
        Map(initialPosition: fitted) {
            ForEach(Array(SpeedSegments.make(fixes).enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(Theme.speedScale[segment.level], style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// The track's bounding box with a margin, so short sessions fill the map.
    private var fitted: MapCameraPosition {
        let points = fixes.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        guard let first = points.first else { return .automatic }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() { rect = rect.union(MKMapRect(origin: point, size: MKMapSize())) }
        let margin = max(rect.size.width, rect.size.height) * 0.25 + 200
        return .rect(rect.insetBy(dx: -margin, dy: -margin))
    }
}

/// Splits a track into runs of similar speed for coloring. Levels span the session's
/// own range, from the 5th to the 95th percentile, so the colors show variation within
/// a session and one spike or stop does not wash them out.
enum SpeedSegments {
    struct Segment {
        var level: Int
        var coordinates: [CLLocationCoordinate2D]
    }

    static func make(_ fixes: [GPSFix]) -> [Segment] {
        guard fixes.count > 1, let (low, high) = range(fixes) else {
            return [Segment(level: 1, coordinates: fixes.map(coordinate))]
        }
        let levels = Theme.speedScale.count
        func level(_ fix: GPSFix) -> Int {
            guard high > low else { return levels / 2 }
            let fraction = ((fix.speed ?? low) - low) / (high - low)
            return min(levels - 1, max(0, Int(fraction * Double(levels))))
        }
        var segments: [Segment] = []
        for (previous, fix) in zip(fixes, fixes.dropFirst()) {
            let current = level(fix)
            if let last = segments.last, last.level == current {
                segments[segments.count - 1].coordinates.append(coordinate(fix))
            } else {
                segments.append(Segment(level: current, coordinates: [coordinate(previous), coordinate(fix)]))
            }
        }
        return segments
    }

    /// The 5th and 95th percentile Doppler speeds, m/s.
    static func range(_ fixes: [GPSFix]) -> (low: Double, high: Double)? {
        let speeds = fixes.compactMap(\.speed).sorted()
        guard speeds.count > 1 else { return nil }
        return (speeds[Int(Double(speeds.count - 1) * 0.05)], speeds[Int(Double(speeds.count - 1) * 0.95)])
    }

    private static func coordinate(_ fix: GPSFix) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
    }
}

/// Chart points, averaged into at most ~300 buckets so long sessions stay light.
enum ChartSeries {
    struct Point: Identifiable {
        var id: Double { minutes }
        var minutes: Double
        var value: Double
    }

    static func speed(_ fixes: [GPSFix], display: LiveDisplay) -> [Point] {
        bucket(fixes.compactMap { fix in fix.speed.map { (fix.t, display.speed.fromSI($0)) } })
    }

    static func heartRate(_ samples: [HRSample]) -> [Point] {
        bucket(samples.map { ($0.t, $0.bpm) })
    }

    static func bucket(_ values: [(t: Double, value: Double)], maxPoints: Int = 300) -> [Point] {
        guard !values.isEmpty else { return [] }
        let size = max(1, values.count / maxPoints)
        return stride(from: 0, to: values.count, by: size).map { start in
            let slice = values[start..<min(start + size, values.count)]
            let t = slice.reduce(0) { $0 + $1.t } / Double(slice.count)
            let v = slice.reduce(0) { $0 + $1.value } / Double(slice.count)
            return Point(minutes: t / 60, value: v)
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
