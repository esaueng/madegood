import Charts
import SwiftUI
import WaterKit

/// One session: a map colored by speed, the stats, speed and heart-rate charts, laps,
/// and export. Everything is recomputed from the raw recording by `SessionReplay`.
struct SessionDetailView: View {
    let item: SessionLibrary.Item
    let library: SessionLibrary

    @State private var analysis: Analysis?
    @State private var selectedReplayElapsed: Double?
    @State private var isPlaying = false
    @State private var replayHighlight: SessionReplayView.Highlight?
    @State private var editing: Analysis?
    @State private var operationError: String?
    @State private var failed = false
    @State private var share: ShareFile?
    @State private var confirmDelete = false
    /// Bumped when a file arrives from the watch, to reload a recording still arriving.
    @State private var reloads = 0
    @Environment(\.dismiss) private var dismiss

    struct Presentation: Sendable {
        let selection: SessionSelection
        let replayData: SessionReplayView.Data
        let summary: SessionLibrary.Summary

        init(
            selection: SessionSelection, display: LiveDisplay, isTrimmed: Bool, trimUnavailable: Bool = false
        ) {
            self.selection = selection
            let timeline = SessionReplayTimeline(
                replay: selection.replay, recordedFixes: selection.track.gps, endTime: selection.duration)
            replayData = SessionReplayView.Data(timeline: timeline, speedUnit: display.speed)
            summary = SessionLibrary.Summary(
                selection: selection, isTrimmed: isTrimmed, trimUnavailable: trimUnavailable)
        }
    }

    struct Analysis: Identifiable, Sendable {
        var id: SessionLibrary.Source { source }
        var source: SessionLibrary.Source
        let session: RawSession
        let profile: SportProfile
        let original: Presentation
        var current: Presentation
        var trim: SessionTrim?
        let display: LiveDisplay
    }

    struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Group {
            if let analysis {
                ScrollViewReader { scroll in
                    content(analysis, scroll: scroll)
                }
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
        .task(id: reloads) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didReceiveFile)) { _ in
            reloads += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UserSettings.didChangeRemotely)) { _ in
            reloads += 1
        }
        .sheet(item: $editing) { analysis in
            SessionTrimEditor(analysis: analysis) { trim, preview in
                try applyTrim(trim, preview: preview, to: analysis)
            }
        }
        .sheet(item: $share) { file in
            ShareSheet(url: file.url)
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try library.delete(item)
                    dismiss()
                } catch {
                    operationError = "Couldn't delete this session or its local trim."
                }
            }
        } message: {
            Text("The recording is removed from this iPhone.")
        }
        .alert(
            "Session",
            isPresented: Binding(
                get: { operationError != nil }, set: { if !$0 { operationError = nil } })
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    private func load() async {
        let folder = item.entry.folder
        let result = await Task.detached(priority: .userInitiated) { () -> Analysis? in
            guard let source = SessionLibrary.source(for: folder), let loaded = source.analyze() else { return nil }
            let display = UserSettings.display(for: loaded.session.meta.sport)
            let original = Presentation(selection: loaded.original, display: display, isTrimmed: false)
            let current =
                loaded.trim != nil || loaded.trimUnavailable
                ? Presentation(
                    selection: loaded.selection, display: display, isTrimmed: loaded.trim != nil,
                    trimUnavailable: loaded.trimUnavailable)
                : original
            return Analysis(
                source: source, session: loaded.session, profile: loaded.profile, original: original,
                current: current, trim: loaded.trim, display: display)
        }.value
        guard !Task.isCancelled else { return }
        if let result, SessionLibrary.source(for: folder) != result.source {
            reloads += 1
            return
        }
        if analysis?.source != result?.source { clearReplay() }
        analysis = result
        failed = result == nil
    }

    private func applyTrim(_ trim: SessionTrim?, preview: Presentation, to original: Analysis) throws {
        var edited = original
        edited.source = try library.updateTrim(
            trim, for: original.session, source: original.source, summary: preview.summary)
        edited.trim = trim
        edited.current = preview
        clearReplay()
        analysis = edited
    }

    private func clearReplay() {
        isPlaying = false
        selectedReplayElapsed = nil
        replayHighlight = nil
    }

    private func selectRange(
        _ range: ClosedRange<Double>, title: String, data: SessionReplayView.Data, scroll: ScrollViewProxy,
        showsSpeedWindow: Bool = false
    ) {
        isPlaying = false
        replayHighlight = SessionReplayView.Highlight(
            title: title, range: range, data: data, showsSpeedWindow: showsSpeedWindow)
        selectedReplayElapsed = range.lowerBound
        scroll.scrollTo("session.replay", anchor: .top)
    }

    @ViewBuilder
    private func speedTile(
        _ title: String, value: Double?, range: ClosedRange<Double>?, analysis: Analysis, scroll: ScrollViewProxy
    ) -> some View {
        let tile = StatTile(title: title, value: analysis.display.speed(value))
        if let range, !analysis.current.replayData.timeline.points.isEmpty {
            Button {
                selectRange(
                    range, title: title, data: analysis.current.replayData, scroll: scroll, showsSpeedWindow: true)
            } label: {
                tile.overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(title), \(analysis.display.speed(value))")
            .accessibilityHint("Show this interval in replay")
            .accessibilityAddTraits(replayHighlight?.title == title ? .isSelected : [])
            .accessibilityIdentifier("replay.\(title)")
        } else {
            tile
        }
    }

    @ViewBuilder
    private func content(_ analysis: Analysis, scroll: ScrollViewProxy) -> some View {
        let sport = analysis.session.meta.sport
        let display = analysis.display
        let selectedTrack = analysis.current.selection.track
        let selectedTrackDuration = analysis.current.selection.duration
        let metrics = analysis.current.selection.replay.metrics
        let replayData = analysis.current.replayData
        List {
            Section {
                HStack(spacing: 12) {
                    SportBadge(sport: sport, diameter: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(analysis.session.startedAt, format: .dateTime.weekday(.wide).day().month(.wide).year())
                            .font(.headline)
                            .fontDesign(.rounded)
                        Text(analysis.session.startedAt, format: .dateTime.hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if analysis.trim != nil {
                            Label("Trimmed", systemImage: "scissors")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }

            if !replayData.timeline.points.isEmpty {
                SessionReplayView(
                    data: replayData, display: display, elapsed: $selectedReplayElapsed, isPlaying: $isPlaying,
                    highlight: replayHighlight
                ) { time in
                    if replayHighlight?.range.contains(time) == false { replayHighlight = nil }
                }
                .id(analysis.source)
                .id("session.replay")
            }

            Section {
                Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        StatTile(title: "Distance", value: display.distance(metrics.distance))
                        StatTile(title: "Moving time", value: Formatting.elapsed(metrics.movingTime))
                    }
                    GridRow {
                        StatTile(title: "Average", value: display.speed(metrics.averageSpeed))
                        StatTile(title: "Total time", value: Formatting.elapsed(selectedTrackDuration))
                    }
                    GridRow {
                        speedTile(
                            "Max 10 s", value: metrics.maxSpeed10s, range: metrics.maxSpeed10sRange,
                            analysis: analysis, scroll: scroll)
                        speedTile(
                            "Max 2 s", value: metrics.maxSpeed2s, range: metrics.maxSpeed2sRange,
                            analysis: analysis, scroll: scroll)
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

            let heartRate = ChartSeries.heartRate(selectedTrack.hr)
            if heartRate.count > 1 {
                let start = min(replayData.timeline.start / 60, heartRate.first?.minutes ?? 0)
                let end = max(heartRate.last?.minutes ?? 0, selectedTrackDuration / 60)
                Section("Heart rate (bpm)") {
                    Chart {
                        if let range = replayHighlight?.range {
                            RectangleMark(
                                xStart: .value("Start", range.lowerBound / 60),
                                xEnd: .value("End", range.upperBound / 60)
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.2))
                        }
                        ForEach(heartRate) { point in
                            LineMark(x: .value("Minutes", point.minutes), y: .value("bpm", point.value))
                                .foregroundStyle(Theme.coral)
                        }
                    }
                    .chartXScale(domain: start...end)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxisLabel("min")
                    .frame(height: 140)
                }
            }

            if !metrics.laps.isEmpty {
                Section("Laps") {
                    ForEach(metrics.laps + [metrics.currentLap], id: \.index) { lap in
                        let title = "Lap \(lap.index)"
                        let row = HStack {
                            Text(title).font(.body.weight(.medium))
                            if lap.isAuto { Text("auto").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(display.distance(lap.distance)).monospacedDigit()
                            Text(Formatting.elapsed(lap.movingTime)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        if lap.start <= lap.end, !replayData.timeline.points.isEmpty {
                            Button {
                                selectRange(lap.start...lap.end, title: title, data: replayData, scroll: scroll)
                            } label: {
                                row.contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Show this interval in replay")
                            .accessibilityAddTraits(replayHighlight?.title == title ? .isSelected : [])
                            .accessibilityIdentifier("replay.lap.\(lap.index)")
                        } else {
                            row
                        }
                    }
                }
            }

            Section {
                if analysis.current.summary.trimUnavailable {
                    Label(
                        "Couldn't read the saved trim. Showing the original recording.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    Button("Restore Original") {
                        do {
                            try applyTrim(nil, preview: analysis.original, to: analysis)
                        } catch {
                            operationError = "Couldn't remove the local trim."
                        }
                    }
                } else if SessionTrim.availableEnd(in: analysis.session) > 0 {
                    Button {
                        isPlaying = false
                        editing = analysis
                    } label: {
                        Label(analysis.trim == nil ? "Trim Session" : "Edit Trim", systemImage: "scissors")
                    }
                    .accessibilityIdentifier("session.trim")
                }
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
                LabeledContent("GPS fixes", value: "\(selectedTrack.gps.count) (\(metrics.rejectedFixes) rejected)")
                Button("Delete session", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private func exportGPX(_ analysis: Analysis) {
        isPlaying = false
        let track = analysis.current.selection.track
        let name = "\(track.sport.rawValue)-\(Int(track.startedAt.timeIntervalSince1970)).gpx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try GPXWriter().data(for: analysis.current.selection).write(to: url, options: .atomic)
            share = ShareFile(url: url)
        } catch {
            operationError = "Couldn't export this GPX file."
        }
    }

    private func exportZip() {
        isPlaying = false
        if let url = try? ZipExport.zip(folder: item.entry.folder) { share = ShareFile(url: url) }
    }
}

/// Chart points, averaged into at most ~300 buckets so long sessions stay light.
enum ChartSeries {
    struct Point: Identifiable {
        var id: Double { minutes }
        var minutes: Double
        var value: Double
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
