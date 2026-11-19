import SwiftUI
import WaterKit

struct SessionMomentsSection: View {
    let presentation: SessionDetailView.Presentation
    let source: SessionLibrary.Source
    let display: LiveDisplay
    let highlightedTitle: String?
    let windChanged: () -> Void
    let select: (SessionReplayView.Highlight) -> Void

    @State private var wind: Double?
    @State private var editingWind = false
    @State private var sailingResult: (request: SailingRequest, analysis: SailingAnalysis)?
    /// The fetched forecast and the query it answers; shown only for that query, so a
    /// trimmed or edited selection in another area or on another day asks again.
    @State private var forecast: (query: OpenMeteo.Query, wind: OpenMeteoWind)?
    @State private var forecastState = ForecastState.idle

    private enum ForecastState: Equatable { case idle, loading, failed }

    private var forecastQuery: OpenMeteo.Query? {
        OpenMeteo.query(track: presentation.selection.track, duration: presentation.selection.duration)
    }

    /// The forecast for the displayed selection, if one has been fetched for it.
    private var currentForecast: OpenMeteoWind? {
        guard let forecast, forecast.query == forecastQuery else { return nil }
        return forecast.wind
    }

    private struct SailingRequest: Equatable {
        let source: SessionLibrary.Source
        let wind: Double?
        let prior: Double?
    }

    var body: some View {
        let selection = presentation.selection
        let sport = selection.track.sport
        let splits = selection.replay.paddlingSplits
        if sport == .sailing {
            sailingSection
                .task(id: forecastQuery) { loadCachedForecast() }
        } else if !splits.isEmpty {
            Section {
                ForEach(splits, id: \.index) { split in
                    let title = split.isComplete ? "Split \(split.index)" : "Split \(split.index) (partial)"
                    let distance = display.distance(split.distance)
                    let time = Formatting.elapsed(split.movingTime)
                    let speed = display.speed(split.averageSpeed)
                    momentRow(
                        title, id: "split.\(split.index)", detail: "\(distance) · \(time) moving · \(speed)"
                    ) {
                        select(
                            SessionReplayView.Highlight(
                                title: title, range: split.elapsedRange, ranges: split.movingRanges,
                                data: presentation.replayData))
                    }
                }
            } header: {
                Text("Moments")
            } footer: {
                Text("Splits every 1 km of moving distance.")
            }
        }
    }

    @ViewBuilder
    private var sailingSection: some View {
        let request = SailingRequest(source: source, wind: wind, prior: currentForecast?.fromDegrees)
        let analysis = sailingResult?.request == request ? sailingResult?.analysis : nil
        Section {
            Button {
                editingWind = true
            } label: {
                LabeledContent("True wind from", value: windText(analysis))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit the wind direction used for this analysis")
            .accessibilityIdentifier("moments.wind.edit")
            .sheet(isPresented: $editingWind) {
                SessionWindEditor(wind: wind) { value in
                    guard wind != value else { return }
                    wind = value
                    windChanged()
                }
            }

            if let analysis {
                if analysis.windFrom == nil {
                    Text("Add a wind direction to look for tacks and gybes.").foregroundStyle(.secondary)
                } else {
                    if analysis.maneuvers.isEmpty {
                        Text("No tacks or gybes detected.").foregroundStyle(.secondary)
                    } else {
                        maneuverRows(analysis.maneuvers, resolved: analysis.windResolved)
                    }
                    vmgRows(analysis)
                }
            } else {
                ProgressView("Analyzing maneuvers")
            }
            forecastRow
        } header: {
            Text("Moments")
        } footer: {
            Text(footer(analysis))
        }
        .task(id: request) {
            await analyzeSailing(request)
        }
    }

    private func windText(_ analysis: SailingAnalysis?) -> String {
        if let wind { return "\(wind.formatted(.number))°" }
        guard let analysis, analysis.windSource == .estimate, let estimate = analysis.estimate else {
            return "Optional"
        }
        let direction = Int(estimate.fromDegrees.rounded()) % 360
        guard analysis.windResolved else { return "\(direction)°/\((direction + 180) % 360)° (estimated axis)" }
        return "\(direction)° (estimated)"
    }

    private func footer(_ analysis: SailingAnalysis?) -> String {
        var parts: [String] = []
        if wind == nil, let estimate = analysis?.estimate {
            let confidence = Int((estimate.axisConfidence * 100).rounded())
            let spread = Int(estimate.axisUncertainty.rounded())
            let legs = Int(estimate.legAngle.rounded())
            parts.append(
                "Wind axis ±\(spread)° from the two most-sailed courses \(legs)° apart; axis confidence \(confidence) %.")
            switch estimate.side {
            case .resolvedByPrior:
                parts.append("Open-Meteo chose which side the wind came from.")
            case .unresolved:
                parts.append("Which side the wind came from is unknown, so tacks and gybes are not told apart.")
            case .priorInconclusive(let prior):
                let forecast = Int(prior.rounded()) % 360
                parts.append(
                    "Open-Meteo's \(forecast)° is too far from both ends of the axis to choose a side, "
                        + "so tacks and gybes are not told apart.")
            }
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var forecastRow: some View {
        if let forecast = currentForecast {
            LabeledContent("Open-Meteo wind") {
                Text("\(Int(forecast.fromDegrees.rounded()) % 360)° · \(display.speed(forecast.speed))")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("moments.openMeteo.result")
        } else if forecastQuery != nil {
            Button {
                Task { await fetchForecast() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(forecastState == .failed ? "Open-Meteo unavailable. Try again" : "Compare with Open-Meteo")
                        // Said before the tap: what leaves the phone.
                        Text("Sends the approximate area (~50 km) and dates")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if forecastState == .loading { ProgressView() }
                }
            }
            .disabled(forecastState == .loading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("moments.openMeteo.fetch")
        }
    }

    @ViewBuilder
    private func vmgRows(_ analysis: SailingAnalysis) -> some View {
        if analysis.windResolved {
            if analysis.upwindVMG != nil || analysis.downwindVMG != nil {
                LabeledContent("VMG upwind", value: display.speed(analysis.upwindVMG))
                    .accessibilityIdentifier("moments.vmg.upwind")
                LabeledContent("VMG downwind", value: display.speed(analysis.downwindVMG))
                    .accessibilityIdentifier("moments.vmg.downwind")
                if let pointing = analysis.pointingAngle {
                    LabeledContent("Pointing", value: "\(Int(pointing.rounded()))° off the wind")
                        .accessibilityIdentifier("moments.pointing")
                }
            }
            ForEach([("Starboard tack", analysis.starboard), ("Port tack", analysis.port)], id: \.0) { name, totals in
                if totals.time > 0 {
                    let value = "\(Formatting.elapsed(totals.time)) · \(display.distance(totals.distance))"
                    LabeledContent(name, value: value)
                        .monospacedDigit()
                }
            }
        } else if let axisVMG = analysis.axisVMG {
            // Only the axis is known: figures that do not depend on the side.
            LabeledContent("VMG along the wind axis", value: display.speed(axisVMG))
                .accessibilityIdentifier("moments.vmg.axis")
            if let angle = analysis.axisAngle {
                LabeledContent("Angle to the axis", value: "\(Int(angle.rounded()))°")
                    .accessibilityIdentifier("moments.axisAngle")
            }
        }
    }

    private func maneuverRows(_ maneuvers: [SailingManeuver], resolved: Bool) -> some View {
        ForEach(maneuvers.indices, id: \.self) { index in
            let maneuver = maneuvers[index]
            let name = Self.maneuverName(maneuver, resolved: resolved)
            let title = "\(name) · \(SessionReplayView.Highlight.time(maneuver.event.t))"
            momentRow(title, id: "maneuver.\(index)", detail: Self.maneuverDetail(maneuver)) {
                select(
                    SessionReplayView.Highlight(
                        title: title, range: maneuver.range, eventTime: maneuver.event.t,
                        data: presentation.replayData))
            }
        }
    }

    /// "Tack" or "Gybe" only when the wind's side is known.
    static func maneuverName(_ maneuver: SailingManeuver, resolved: Bool) -> String {
        guard resolved else { return "Tack or gybe" }
        return maneuver.event.type == .tack ? "Tack" : "Gybe"
    }

    /// "Turn 92° · 0:06 · speed loss 41 %".
    static func maneuverDetail(_ maneuver: SailingManeuver) -> String {
        var parts: [String] = []
        if let angle = maneuver.turnAngle { parts.append("Turn \(Int(angle.rounded()))°") }
        parts.append(Formatting.duration(maneuver.duration))
        if let loss = maneuver.speedLossPercent { parts.append("speed loss \(Int(loss.rounded())) %") }
        return parts.joined(separator: " · ")
    }

    private func analyzeSailing(_ request: SailingRequest) async {
        let selection = presentation.selection
        let analysis = await Task.detached(priority: .userInitiated) {
            selection.sailingAnalysis(windFromDegreesTrue: request.wind, windPrior: request.prior)
        }.value
        guard !Task.isCancelled else { return }
        sailingResult = (request, analysis)
    }

    private func loadCachedForecast() {
        forecastState = .idle
        guard currentForecast == nil, !DemoFeed.isEnabled, let query = forecastQuery,
            let cached = OpenMeteoCache.wind(for: query)
        else { return }
        forecast = (query, cached)
    }

    private func fetchForecast() async {
        guard let query = forecastQuery else { return }
        forecastState = .loading
        do {
            let result: OpenMeteoWind
            if DemoFeed.isEnabled {
                // UI tests never reach the network: a fixed answer, or a failure on request.
                try await Task.sleep(for: .milliseconds(300))
                if ProcessInfo.processInfo.arguments.contains("-demoOpenMeteoOffline") {
                    throw URLError(.notConnectedToInternet)
                }
                result = OpenMeteoWind(fromDegrees: 10, speed: 6, hours: 2)
            } else {
                result = try await OpenMeteo.fetch(query)
                OpenMeteoCache.store(result, for: query)
            }
            forecast = (query, result)
            forecastState = .idle
        } catch {
            forecastState = .failed
        }
    }

    private func momentRow(_ title: String, id: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint("Show this interval in replay")
        .accessibilityAddTraits(highlightedTitle == title ? .isSelected : [])
        .accessibilityIdentifier("moments.\(id)")
    }
}

private struct SessionWindEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var text = ""
    let wind: Double?
    let apply: (Double?) -> Void

    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.locale(locale).grouping(.never)
    }

    private func direction(from input: String) -> Double? {
        let scanner = Scanner(string: input)
        scanner.locale = locale
        scanner.charactersToBeSkipped = nil
        guard let value = scanner.scanDouble(), scanner.isAtEnd, (0...360).contains(value) else { return nil }
        return value
    }

    var body: some View {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = direction(from: input)
        let invalid = !input.isEmpty && value == nil
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("True wind from (degrees)")
                        TextField("Optional", text: $text)
                            .keyboardType(.decimalPad)
                            .accessibilityLabel("True wind from (degrees)")
                            .accessibilityIdentifier("moments.wind.direction")
                    }
                    if invalid {
                        Text("Enter a number from 0 to 360.")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("moments.wind.invalid")
                    }
                } footer: {
                    Text(
                        "Enter degrees clockwise from true north. This value is used only here. Leave it blank to clear."
                    )
                }
            }
            .navigationTitle("Wind direction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply(value)
                        dismiss()
                    }
                    .disabled(invalid)
                    .accessibilityIdentifier("moments.wind.apply")
                }
            }
        }
        .onAppear { text = wind.map { $0.formatted(numberFormat) } ?? "" }
    }
}
