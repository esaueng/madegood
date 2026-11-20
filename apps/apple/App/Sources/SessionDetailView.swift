import Charts
import SwiftUI
import WaterKit

/// One session: a map colored by speed, the stats, speed and heart-rate charts, laps,
/// and export. Everything is recomputed from the raw recording by `SessionReplay`.
struct SessionDetailView: View {
    let item: SessionLibrary.Item
    let library: SessionLibrary

    @State private var settings = SettingsStore.shared
    @State private var analysis: Analysis?
    @State private var selectedReplayElapsed: Double?
    @State private var isPlaying = false
    @State private var replayHighlight: SessionReplayView.Highlight?
    @State private var editing: Analysis?
    @State private var operationError: String?
    @State private var failed = false
    @State private var share: ShareFile?
    /// Progress of preparing the raw recording for sharing (nil when not preparing).
    @State private var rawExportProgress: Double?
    /// Why the last attempt to prepare the raw recording failed, shown on its row.
    @State private var rawExportError: String?
    @State private var confirmDelete = false
    /// Bumped when a file arrives from the watch, to reload a recording still arriving.
    @State private var reloads = 0
    @Environment(\.dismiss) private var dismiss

    struct Presentation: Sendable {
        let selection: SessionSelection
        let replayData: SessionReplayView.Data
        let summary: SessionLibrary.Summary
        let heartRateZones: HeartRateZones
        let zoneDurations: [HeartRateZones.Zone: Double]

        init(
            selection: SessionSelection, display: LiveDisplay, isTrimmed: Bool, trimUnavailable: Bool = false
        ) {
            self.selection = selection
            let timeline = SessionReplayTimeline(
                replay: selection.replay, recordedFixes: selection.track.gps, endTime: selection.duration)
            replayData = SessionReplayView.Data(timeline: timeline, speedUnit: display.speed)
            heartRateZones = UserSettings.heartRateZones
            zoneDurations = heartRateZones.durations(in: selection)
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
        /// Strokes over the whole recording (kayak, canoe, SUP), detected once from the
        /// motion stream; nil for other sports. Trims re-derive `strokes` from it.
        let strokeDetection: StrokeAnalysis.Detection?
        /// Whether the recording has a motion stream at all.
        let hasMotion: Bool
        var strokes: StrokeAnalysis?
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
        .onChange(of: settings.heartRateZones) {
            reloads += 1
        }
        .onChange(of: analysis?.source) {
            if editing?.source != analysis?.source { editing = nil }
        }
        .sheet(item: $editing) { analysis in
            SessionTrimEditor(
                analysis: analysis, boundaryPack: DemoOffWater.boundaryPack(for: analysis.session.meta.sessionId)
            ) { trim, preview in
                try applyTrim(trim, preview: preview, to: analysis)
            }
        }
        .sheet(item: $share) { file in
            ShareSheet(url: file.url) { ExportFiles.discard(file.url) }
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
            let sport = loaded.session.meta.sport
            var detection: StrokeAnalysis.Detection?
            var hasMotion = false
            if sport.isPaddling {
                let full = try? RawSessionReader.read(folder: folder)
                hasMotion = !(full?.motion.isEmpty ?? true)
                detection = full.map { StrokeAnalysis.detect(session: $0) } ?? .init(cycles: [], strokes: [])
            }
            return Analysis(
                source: source, session: loaded.session, profile: loaded.profile, original: original,
                current: current, trim: loaded.trim, display: display, strokeDetection: detection,
                hasMotion: hasMotion,
                strokes: detection.map { StrokeAnalysis(detection: $0, sport: sport, selection: current.selection) })
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
        edited.strokes = original.strokeDetection.map {
            StrokeAnalysis(detection: $0, sport: original.session.meta.sport, selection: preview.selection)
        }
        clearReplay()
        analysis = edited
    }

    private func clearReplay() {
        isPlaying = false
        selectedReplayElapsed = nil
        replayHighlight = nil
    }

    private func selectRange(
        _ range: ClosedRange<Double>, ranges: [ClosedRange<Double>]? = nil, title: String,
        data: SessionReplayView.Data, scroll: ScrollViewProxy, showsSpeedWindow: Bool = false
    ) {
        selectHighlight(
            SessionReplayView.Highlight(
                title: title, range: range, ranges: ranges, data: data, showsSpeedWindow: showsSpeedWindow),
            scroll: scroll)
    }

    private func selectHighlight(_ highlight: SessionReplayView.Highlight, scroll: ScrollViewProxy) {
        isPlaying = false
        replayHighlight = highlight
        selectedReplayElapsed = highlight.eventTime ?? highlight.range.lowerBound
        scroll.scrollTo("session.replay", anchor: .top)
    }

    @ViewBuilder
    private func speedTile(
        _ title: String, value: Double?, range: ClosedRange<Double>?, ranges: [ClosedRange<Double>]? = nil,
        analysis: Analysis, scroll: ScrollViewProxy
    ) -> some View {
        let tile = StatTile(title: title, value: analysis.display.speed(value))
        if let range, !analysis.current.replayData.timeline.points.isEmpty {
            Button {
                // Several windows (5 × 10 s) are highlighted on the route; the speed window
                // view is for one span.
                selectRange(
                    range, ranges: ranges, title: title, data: analysis.current.replayData, scroll: scroll,
                    showsSpeedWindow: ranges == nil)
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

    /// Windsurfing: the speedsurfing categories beyond the 2 s and 10 s maxima above.
    private func speedBests(_ categories: SpeedCategories, analysis: Analysis, scroll: ScrollViewProxy) -> some View {
        let fiveByTen = categories.best5x10sRanges
        let fiveByTenSpan = fiveByTen.first.flatMap { first in fiveByTen.last.map { first.lowerBound...$0.upperBound } }
        return Section {
            Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    speedTile(
                        "5 × 10 s", value: categories.best5x10s, range: fiveByTenSpan, ranges: fiveByTen,
                        analysis: analysis, scroll: scroll)
                    speedTile(
                        "100 m", value: categories.best100m?.speed, range: categories.best100m?.range,
                        analysis: analysis, scroll: scroll)
                }
                GridRow {
                    speedTile(
                        "500 m", value: categories.best500m?.speed, range: categories.best500m?.range,
                        analysis: analysis, scroll: scroll)
                    speedTile(
                        "Nautical mile", value: categories.nauticalMile?.speed, range: categories.nauticalMile?.range,
                        analysis: analysis, scroll: scroll)
                }
                GridRow {
                    speedTile(
                        "1 hour", value: categories.hour?.speed, range: categories.hour?.range,
                        analysis: analysis, scroll: scroll)
                    speedTile(
                        "Alpha 500", value: categories.alpha500?.speed, range: categories.alpha500?.range,
                        analysis: analysis, scroll: scroll)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Speed bests")
        } footer: {
            Text("From Doppler speed. Alpha 500 is the fastest 500 m that ends within 50 m of its start.")
        }
        .id("session.speedBests")
    }

    @ViewBuilder
    private func content(_ analysis: Analysis, scroll: ScrollViewProxy) -> some View {
        let sport = analysis.session.meta.sport
        let display = analysis.display
        let selectedTrack = analysis.current.selection.track
        let selectedTrackDuration = analysis.current.selection.retainedDuration
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

            if !replayData.timeline.removedIntervals.isEmpty {
                Section {
                    ForEach(replayData.timeline.removedIntervals, id: \.self) { range in
                        let start = SessionReplayView.Highlight.time(range.lowerBound)
                        let end = SessionReplayView.Highlight.time(range.upperBound)
                        Label("\(start) to \(end)", systemImage: "scissors")
                            .monospacedDigit()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(start) to \(end)")
                            .accessibilityIdentifier("replay.removedInterval")
                    }
                } header: {
                    Text("Removed intervals")
                } footer: {
                    Text("Times follow the replay clock. Playback skips the removed intervals.")
                }
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
                .id("session.stats")
            }

            if sport == .motorboating {
                MotorboatDetailSection(
                    metrics: metrics, startedAt: analysis.session.startedAt, display: display, library: library)
            }

            if let categories = metrics.speedCategories {
                speedBests(categories, analysis: analysis, scroll: scroll)
            }

            let heartRate = ChartSeries.heartRate(selectedTrack.hr, cuts: replayData.timeline.removedIntervals)
            if heartRate.reduce(0, { $0 + $1.count }) > 1 {
                let start = min(replayData.timeline.start / 60, heartRate.first?.first?.minutes ?? 0)
                let end = max(heartRate.last?.last?.minutes ?? 0, replayData.timeline.duration / 60)
                Section("Heart rate (bpm)") {
                    Chart {
                        ForEach(replayHighlight?.ranges ?? [], id: \.self) { range in
                            RectangleMark(
                                xStart: .value("Start", range.lowerBound / 60),
                                xEnd: .value("End", range.upperBound / 60)
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.2))
                        }
                        ForEach(heartRate.indices, id: \.self) { index in
                            ForEach(heartRate[index]) { point in
                                if heartRate[index].count == 1 {
                                    PointMark(x: .value("Minutes", point.minutes), y: .value("bpm", point.value))
                                        .foregroundStyle(Theme.coral)
                                } else {
                                    LineMark(
                                        x: .value("Minutes", point.minutes), y: .value("bpm", point.value),
                                        series: .value("Span", index)
                                    )
                                    .foregroundStyle(Theme.coral)
                                }
                            }
                        }
                    }
                    .chartXScale(domain: start...end)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxisLabel("min")
                    .frame(height: 140)
                }
            }

            if !analysis.current.zoneDurations.isEmpty {
                Section {
                    ForEach(HeartRateZones.Zone.allCases, id: \.self) { zone in
                        LabeledContent {
                            Text(Formatting.elapsed(analysis.current.zoneDurations[zone, default: 0]))
                                .monospacedDigit()
                        } label: {
                            Text("Zone \(zone.rawValue)")
                        }
                    }
                } header: {
                    Text("Time in heart rate zones")
                } footer: {
                    Text(
                        "Based on a maximum of \(analysis.current.heartRateZones.maximum) bpm. Pauses and gaps in readings are excluded."
                    )
                    .accessibilityIdentifier("session.heartRateZones.maximum")
                }
            }

            if let strokes = analysis.strokes {
                strokeSection(strokes, analysis: analysis, replayData: replayData)
            }

            SessionMomentsSection(
                presentation: analysis.current, source: analysis.source, display: display,
                highlightedTitle: replayHighlight?.title,
                windChanged: {
                    if replayHighlight?.eventTime != nil { replayHighlight = nil }
                },
                select: { selectHighlight($0, scroll: scroll) })

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
                    if let rawExportProgress {
                        HStack {
                            Label("Preparing raw recording…", systemImage: "doc.zipper")
                            Spacer()
                            ProgressView(value: rawExportProgress).frame(width: 60)
                        }
                    } else {
                        Label("Share raw recording", systemImage: "doc.zipper")
                    }
                }
                .disabled(rawExportProgress != nil)
                .accessibilityIdentifier("export.raw")
                if let rawExportError {
                    Text(rawExportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("export.raw.error")
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
                SessionSyncDetailRow(sessionID: analysis.session.meta.sessionId)
                Button("Delete session", role: .destructive) { confirmDelete = true }
            }
        }
        .onChange(of: analysis.trim) { _, trim in
            if trim != nil {
                scroll.scrollTo("session.stats", anchor: .top)
            }
        }
    }

    /// Paddling: stroke totals and the stroke rate over time (docs/metrics.md "Strokes").
    @ViewBuilder
    private func strokeSection(
        _ strokes: StrokeAnalysis, analysis: Analysis, replayData: SessionReplayView.Data
    ) -> some View {
        let display = analysis.display
        let distance = analysis.current.selection.replay.metrics.distance
        Section {
            if !analysis.hasMotion {
                Label("No wrist motion was recorded, so strokes aren't available.", systemImage: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        StatTile(title: "Strokes", value: LiveDisplay.strokeCount(strokes.strokeCount))
                        StatTile(title: "Avg stroke rate", value: LiveDisplay.strokeRate(strokes.averageStrokeRate))
                    }
                    GridRow {
                        StatTile(
                            title: "Per stroke",
                            value: display.distancePerStroke(distance: distance, strokes: strokes.strokeCount))
                        if strokes.sideBalance != nil {
                            StatTile(title: "Side switches", value: "\(strokes.sideSwitches)")
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                    if let balance = strokes.sideBalance {
                        let first = Int((balance * 100).rounded())
                        GridRow {
                            StatTile(title: "Side balance", value: "\(first) / \(100 - first) %")
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
                .padding(.vertical, 6)
                let spans = ChartSeries.strokeRate(strokes.rateSeries)
                if spans.reduce(0, { $0 + $1.count }) > 1 {
                    let start = min(replayData.timeline.start / 60, spans.first?.first?.minutes ?? 0)
                    let end = max(spans.last?.last?.minutes ?? 0, replayData.timeline.duration / 60)
                    Chart {
                        ForEach(replayHighlight?.ranges ?? [], id: \.self) { range in
                            RectangleMark(
                                xStart: .value("Start", range.lowerBound / 60),
                                xEnd: .value("End", range.upperBound / 60)
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.2))
                        }
                        ForEach(spans.indices, id: \.self) { index in
                            ForEach(spans[index]) { point in
                                LineMark(
                                    x: .value("Minutes", point.minutes), y: .value("spm", point.value),
                                    series: .value("Span", index)
                                )
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .chartXScale(domain: start...end)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxisLabel("min")
                    .chartYAxisLabel("spm")
                    .frame(height: 140)
                    .accessibilityIdentifier("chart.strokeRate")
                }
            }
        } header: {
            Text("Strokes")
        } footer: {
            if analysis.hasMotion, strokes.sideBalance != nil {
                Text("Side balance is the share of strokes on the side paddled first, then on the other side.")
            }
        }
        .id("session.strokes")
    }

    private func exportGPX(_ analysis: Analysis) {
        isPlaying = false
        let track = analysis.current.selection.track
        let name = "\(track.sport.rawValue)-\(Int(track.startedAt.timeIntervalSince1970)).gpx"
        do {
            let url = try ExportFiles.url(named: name)
            try GPXWriter().data(for: analysis.current.selection).write(to: url, options: .atomic)
            share = ShareFile(url: url)
        } catch {
            operationError = "Couldn't export this GPX file."
        }
    }

    private func exportZip() {
        isPlaying = false
        rawExportProgress = 0
        rawExportError = nil
        let folder = item.entry.folder
        Task {
            defer { rawExportProgress = nil }
            do {
                let url = try await ZipExport.zipRecording(folder: folder) { fraction in
                    Task { @MainActor in
                        if rawExportProgress != nil { rawExportProgress = fraction }
                    }
                }
                share = ShareFile(url: url)
            } catch {
                rawExportError = "Couldn't prepare the raw recording. Part of it could not be read; try again."
            }
        }
    }
}

/// Chart points, averaged into at most ~300 buckets so long sessions stay light.
enum ChartSeries {
    struct Point: Identifiable {
        var id: Double { minutes }
        var minutes: Double
        var value: Double
    }

    static func heartRate(_ samples: [HRSample], cuts: [ClosedRange<Double>]) -> [[Point]] {
        var start = samples.startIndex
        var spans: [[Point]] = []
        for cut in cuts {
            let split = samples[start...].firstIndex { $0.t >= cut.upperBound } ?? samples.endIndex
            spans.append(bucket(samples[start..<split].map { ($0.t, $0.bpm) }))
            start = split
        }
        spans.append(bucket(samples[start...].map { ($0.t, $0.bpm) }))
        return spans.filter { !$0.isEmpty }
    }

    /// Stroke-rate points split at pauses (no point for 20 s), so a line never bridges one.
    static func strokeRate(_ points: [StrokeAnalysis.RatePoint]) -> [[Point]] {
        var spans: [[(t: Double, value: Double)]] = []
        var last: Double?
        for point in points {
            if let last, point.t - last <= 20 {
                spans[spans.count - 1].append((point.t, point.strokeRate))
            } else {
                spans.append([(point.t, point.strokeRate)])
            }
            last = point.t
        }
        let total = max(1, points.count)
        return spans.map { bucket($0, maxPoints: max(2, 300 * $0.count / total)) }
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

/// The system share sheet for one file (AirDrop, Files, Mail). `onComplete` runs once the
/// chosen activity has finished with the file, or the sheet was dismissed without one.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
