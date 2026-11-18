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
    @State private var sailingResult: (request: SailingRequest, maneuvers: [SailingManeuver])?

    private struct SailingRequest: Equatable {
        let source: SessionLibrary.Source
        let wind: Double
    }

    var body: some View {
        let selection = presentation.selection
        let sport = selection.track.sport
        let splits = selection.replay.paddlingSplits
        if sport == .sailing {
            sailingSection
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

    private var sailingSection: some View {
        let request = wind.map { SailingRequest(source: source, wind: $0) }
        return Section {
            Button {
                editingWind = true
            } label: {
                LabeledContent("True wind from", value: wind.map { "\($0.formatted(.number))°" } ?? "Optional")
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit the wind direction used for this analysis")
            .accessibilityIdentifier("moments.wind.edit")
            .sheet(isPresented: $editingWind) {
                SessionWindEditor(wind: wind) { value in
                    guard wind != value else { return }
                    sailingResult = nil
                    wind = value
                    windChanged()
                }
            }

            if let request {
                if let sailingResult, sailingResult.request == request {
                    if sailingResult.maneuvers.isEmpty {
                        Text("No tacks or gybes detected.").foregroundStyle(.secondary)
                    } else {
                        ForEach(sailingResult.maneuvers.indices, id: \.self) { index in
                            let maneuver = sailingResult.maneuvers[index]
                            let name = maneuver.event.type == .tack ? "Tack" : "Gybe"
                            let title = "\(name) · \(SessionReplayView.Highlight.time(maneuver.event.t))"
                            let duration = maneuver.range.upperBound - maneuver.range.lowerBound
                            momentRow(
                                title, id: "maneuver.\(index)", detail: "Turn duration \(Formatting.duration(duration))"
                            ) {
                                select(
                                    SessionReplayView.Highlight(
                                        title: title, range: maneuver.range, eventTime: maneuver.event.t,
                                        data: presentation.replayData))
                            }
                        }
                    }
                } else {
                    ProgressView("Analyzing maneuvers")
                        .task(id: request) {
                            await analyzeSailing(request)
                        }
                }
            } else {
                Text("Add a wind direction to look for tacks and gybes.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Moments")
        }
    }

    private func analyzeSailing(_ request: SailingRequest) async {
        let selection = presentation.selection
        let maneuvers = await Task.detached(priority: .userInitiated) {
            selection.sailingManeuvers(windFromDegreesTrue: request.wind)
        }.value
        guard !Task.isCancelled else { return }
        sailingResult = (request, maneuvers)
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
