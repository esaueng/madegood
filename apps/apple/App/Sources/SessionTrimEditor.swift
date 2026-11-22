import Foundation
import SwiftUI
import WaterKit

/// Both handles and the route here use the original recording clock.
struct SessionTrimEditor: View {
    let analysis: SessionDetailView.Analysis
    private let boundaryPack: Data?
    let save: (SessionTrim?, SessionDetailView.Presentation) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var elapsed: Double?
    @State private var preview: Preview
    @State private var suggestionResult: (input: SuggestionInput, suggestions: [OffWaterSuggestion])?
    @State private var reviewing: OffWaterSuggestion?
    @State private var proposalResult: (request: PreviewRequest, preview: Preview)?
    @State private var recordingChanged = false
    @State private var error: String?

    private struct Draft: Equatable {
        var bounds: ClosedRange<Double>
        var cuts: [ClosedRange<Double>]

        var spans: [ClosedRange<Double>] {
            zip([bounds.lowerBound] + cuts.map(\.upperBound), cuts.map(\.lowerBound) + [bounds.upperBound])
                .map { $0...$1 }
        }

        func addingSuggestion(_ range: ClosedRange<Double>) -> Draft? {
            // A suggestion in this editor must produce an individually restorable middle cut.
            guard bounds.lowerBound < range.lowerBound, range.upperBound < bounds.upperBound else { return nil }
            var merged: [ClosedRange<Double>] = []
            for cut in (cuts + [range]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, last.overlaps(cut) {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, cut.upperBound)
                } else {
                    merged.append(cut)
                }
            }
            return merged == cuts ? nil : Draft(bounds: bounds, cuts: merged)
        }
    }

    private struct Preview {
        let draft: Draft
        let trim: SessionTrim?
        let presentation: SessionDetailView.Presentation
    }

    private struct PreviewRequest: Equatable {
        let source: SessionLibrary.Source
        let draft: Draft
        let suggestion: OffWaterSuggestion?
        let proposed: Draft?
    }

    private struct SuggestionInput: Equatable {
        let source: SessionLibrary.Source
        let pack: Data
    }

    private var suggestionInput: SuggestionInput? {
        boundaryPack.map { SuggestionInput(source: analysis.source, pack: $0) }
    }

    private var suggestions: [OffWaterSuggestion] {
        guard let suggestionResult, suggestionResult.input == suggestionInput else { return [] }
        return suggestionResult.suggestions
    }

    private var previewRequest: PreviewRequest {
        let suggestion = reviewing.flatMap { suggestions.contains($0) ? $0 : nil }
        return PreviewRequest(
            source: analysis.source, draft: draft, suggestion: suggestion,
            proposed: suggestion.flatMap { draft.addingSuggestion($0.originalClockRange) })
    }

    private var readyProposal: Preview? {
        guard !recordingChanged, let proposalResult, proposalResult.request == previewRequest,
            preview.draft == draft
        else { return nil }
        return proposalResult.preview
    }

    private var availableEnd: Double { SessionTrim.availableEnd(in: analysis.session) }
    private var minSpan: Double {
        min(0.001, availableEnd / 2, analysis.trim.map { $0.range.upperBound - $0.range.lowerBound } ?? 1)
    }

    private var newCut: ClosedRange<Double>? {
        guard let span = draft.spans.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound })
        else { return nil }
        let third = (span.upperBound - span.lowerBound) / 3
        let lower = span.lowerBound + third
        let upper = span.upperBound - third
        guard span.lowerBound < lower, lower < upper, upper < span.upperBound else { return nil }
        return lower...upper
    }

    init(
        analysis: SessionDetailView.Analysis,
        boundaryPack: Data?,
        save: @escaping (SessionTrim?, SessionDetailView.Presentation) throws -> Void
    ) {
        self.analysis = analysis
        self.boundaryPack = boundaryPack
        self.save = save
        let initial = Draft(
            bounds: analysis.trim?.range ?? 0...SessionTrim.availableEnd(in: analysis.session),
            cuts: analysis.trim?.removedRanges ?? [])
        _draft = State(initialValue: initial)
        _elapsed = State(initialValue: initial.bounds.lowerBound)
        _preview = State(initialValue: Preview(draft: initial, trim: analysis.trim, presentation: analysis.current))
    }

    var body: some View {
        let replayData = analysis.original.replayData
        let request = previewRequest
        let input = suggestionInput
        let visiblePreview = readyProposal ?? (preview.draft == draft ? preview : nil)
        let highlight = SessionReplayView.Highlight(
            keptRange: draft.bounds, removedIntervals: visiblePreview?.draft.cuts ?? draft.cuts,
            preview: visiblePreview?.presentation.replayData)
        NavigationStack {
            // The route on top, showing what is kept and what is removed, and the controls
            // below it, so the effect of every handle is in view while it moves.
            VStack(spacing: 0) {
                if !replayData.timeline.points.isEmpty {
                    trimMap(replayData, highlight: highlight)
                        .containerRelativeFrame(.vertical) { height, _ in height * 0.38 }
                }
                controls(replayData: replayData, highlight: highlight)
            }
            .navigationTitle("Trim Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { apply(preview.trim, presentation: preview.presentation) }
                        .disabled(recordingChanged || preview.draft != draft || request.proposed != nil)
                        .accessibilityIdentifier("trim.save")
                }
            }
            .task(id: input) { if let input { await loadSuggestions(for: input) } }
            .task(id: request) { await updatePreview(for: request) }
            .onChange(of: draft) {
                reviewing = nil
                proposalResult = nil
            }
            .alert(
                "Trim Session", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func trimMap(_ data: SessionReplayView.Data, highlight: SessionReplayView.Highlight) -> some View {
        let cursor = SessionReplayView.cursor(data: data, elapsed: elapsed, isPlaying: false, highlight: highlight)
        return SessionReplayMap(
            data: data, selection: cursor.selection, time: cursor.time, highlight: highlight, insideCut: false,
            select: { elapsed = data.timeline.selection(at: $0).elapsed }
        )
        .overlay(alignment: .bottomTrailing) {
            Text("Not for navigation")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: .capsule)
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    private func controls(replayData: SessionReplayView.Data, highlight: SessionReplayView.Highlight) -> some View {
        List {
            Section {
                if preview.draft == draft {
                    comparison(original: analysis.original.selection, kept: preview.presentation.selection)
                    if preview.presentation.replayData.timeline.points.isEmpty {
                        Text("No usable GPS fixes in this interval.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Updating preview")
                }
            } header: {
                Text("Original → kept")
            }

            suggestionControls

            Section {
                let bounds = draft.bounds
                let startLimit = draft.cuts.first?.lowerBound.nextDown ?? bounds.upperBound - minSpan
                let endLimit = draft.cuts.last?.upperBound.nextUp ?? bounds.lowerBound + minSpan
                boundary(
                    "Keep from", id: "trim.start", value: bounds.lowerBound,
                    limits: 0...max(bounds.lowerBound, startLimit)
                ) { draft.bounds = $0...draft.bounds.upperBound }
                boundary(
                    "Keep through", id: "trim.end", value: bounds.upperBound,
                    limits: min(bounds.upperBound, endLimit)...availableEnd
                ) { draft.bounds = draft.bounds.lowerBound...$0 }
            } footer: {
                Text("Times are measured from the start of the original recording.")
            }

            ForEach(draft.cuts.indices, id: \.self) { index in
                cutControls(index)
            }
            if let newCut {
                Button("Remove Middle Segment", systemImage: "scissors") {
                    draft.cuts.append(newCut)
                    draft.cuts.sort { $0.lowerBound < $1.lowerBound }
                    elapsed = newCut.lowerBound
                }
                .accessibilityIdentifier("trim.addCut")
            }

            if !replayData.timeline.points.isEmpty {
                SessionReplayView(
                    data: replayData, display: analysis.display, elapsed: $elapsed, isPlaying: .constant(false),
                    highlight: highlight, allowsPlayback: false, showsMap: false)
            }

            if analysis.trim != nil {
                Button("Restore Original") { apply(nil, presentation: analysis.original) }
                    .accessibilityIdentifier("trim.restore")
            }
        }
    }

    @ViewBuilder
    private var suggestionControls: some View {
        let available = suggestions.filter { draft.addingSuggestion($0.originalClockRange) != nil }
        if !recordingChanged, !available.isEmpty {
            Section("Suggested off-water cuts") {
                ForEach(available, id: \.self) { suggestion in
                    let range = suggestion.originalClockRange
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recording \(interval(range))")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .accessibilityIdentifier("trim.suggestion.range")
                        if draft.bounds.lowerBound != 0, preview.draft == draft {
                            let selection = preview.presentation.selection
                            let start = selection.replayTime(forSourceTime: range.lowerBound)
                            let end = selection.replayTime(forSourceTime: range.upperBound)
                            let replayRange = start...end
                            Text("Replay \(interval(replayRange))")
                                .font(.subheadline.monospacedDigit())
                                .accessibilityIdentifier("trim.suggestion.replayRange")
                        }
                        Text(reason(for: suggestion))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("trim.suggestion.reason")
                    }
                    if reviewing != suggestion {
                        Button("Preview Cut") {
                            proposalResult = nil
                            reviewing = suggestion
                            elapsed = range.lowerBound
                        }
                        .accessibilityIdentifier("trim.suggestion.preview")
                    } else {
                        if let candidate = readyProposal {
                            if let combined = candidate.draft.cuts.first(where: { $0.overlaps(range) }),
                                combined != range
                            {
                                Text("Combined cut \(interval(combined))")
                                    .font(.subheadline.monospacedDigit())
                            }
                            metrics("Before cut", selection: preview.presentation.selection)
                            metrics("After cut", selection: candidate.presentation.selection)
                            Button("Accept Cut") {
                                guard let result = readyProposal, sourceIsCurrent() else { return }
                                preview = result
                                draft = result.draft
                                reviewing = nil
                                proposalResult = nil
                            }
                            .accessibilityIdentifier("trim.suggestion.accept")
                        } else {
                            ProgressView("Calculating cut preview")
                        }
                        Button("Close Preview") {
                            reviewing = nil
                            proposalResult = nil
                        }
                        .accessibilityIdentifier("trim.suggestion.close")
                    }
                }
            }
        }
    }

    private func interval(_ range: ClosedRange<Double>) -> String {
        "\(SessionReplayView.Highlight.time(range.lowerBound)) to \(SessionReplayView.Highlight.time(range.upperBound))"
    }

    private func reason(for suggestion: OffWaterSuggestion) -> String {
        let context =
            switch suggestion.reason.waterContext {
            case .before: "water fixes before it"
            case .after: "water fixes after it"
            case .beforeAndAfter: "water fixes on both sides"
            }
        return "\(suggestion.reason.landFixCount) consecutive GPS fixes supported by land evidence, with \(context)."
    }

    private func cutControls(_ index: Int) -> some View {
        let cut = draft.cuts[index]
        let previousEnd = index == 0 ? draft.bounds.lowerBound : draft.cuts[index - 1].upperBound
        let nextStart = index + 1 == draft.cuts.count ? draft.bounds.upperBound : draft.cuts[index + 1].lowerBound
        return Section("Removed segment \(index + 1)") {
            boundary(
                "Remove after", id: "trim.cut.\(index).start", value: cut.lowerBound,
                limits: previousEnd.nextUp...cut.upperBound.nextDown
            ) { draft.cuts[index] = $0...draft.cuts[index].upperBound }
            boundary(
                "Remove until", id: "trim.cut.\(index).end", value: cut.upperBound,
                limits: cut.lowerBound.nextUp...nextStart.nextDown
            ) { draft.cuts[index] = draft.cuts[index].lowerBound...$0 }
            Button("Keep This Segment") { draft.cuts.remove(at: index) }
                .accessibilityIdentifier("trim.cut.\(index).undo")
        }
    }

    private func boundary(
        _ title: String, id: String, value: Double, limits: ClosedRange<Double>,
        update: @escaping (Double) -> Void
    ) -> some View {
        let time = SessionReplayView.Highlight.time(value)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                elapsed = value
            } label: {
                LabeledContent(title, value: time)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Seek to this boundary")
            if limits.lowerBound < limits.upperBound {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { time in
                            let clamped = min(max(limits.lowerBound, time), limits.upperBound)
                            update(clamped)
                            elapsed = clamped
                        }),
                    in: limits
                ) {
                    Text(title)
                }
                .accessibilityValue(time)
                .accessibilityIdentifier(id)
            }
        }
    }

    /// Original and kept side by side: the original struck through where the trim changes
    /// it, so a dropped spike or a shorter session is plain at a glance.
    private func comparison(original: SessionSelection, kept: SessionSelection) -> some View {
        let display = analysis.display
        let before = original.replay.metrics
        let after = kept.replay.metrics
        let rows: [(title: String, original: String, kept: String)] = [
            ("Distance", display.distance(before.distance), display.distance(after.distance)),
            (
                "Total time", SessionReplayView.Highlight.time(original.retainedDuration),
                SessionReplayView.Highlight.time(kept.retainedDuration)
            ),
            ("Average speed", display.speed(before.averageSpeed), display.speed(after.averageSpeed)),
            ("Max 2 s", display.speed(before.maxSpeed2s), display.speed(after.maxSpeed2s)),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows, id: \.title) { row in
                GridRow {
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    Text(row.original)
                        .strikethrough(row.original != row.kept)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.kept)
                        .fontWeight(.semibold)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.subheadline.monospacedDigit())
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            rows.map { "\($0.title): original \($0.original), kept \($0.kept)" }.joined(separator: ". ")
        )
        .accessibilityIdentifier("trim.preview")
    }

    private func metrics(_ title: String, selection: SessionSelection) -> some View {
        let metrics = selection.replay.metrics
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            LabeledContent("Distance", value: analysis.display.distance(metrics.distance))
            LabeledContent("Total time", value: SessionReplayView.Highlight.time(selection.retainedDuration))
            LabeledContent("Average speed", value: analysis.display.speed(metrics.averageSpeed))
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trim.preview.\(title)")
    }

    private func loadSuggestions(for input: SuggestionInput) async {
        let session = analysis.session
        let result = await Task.detached(priority: .userInitiated) { () -> [OffWaterSuggestion] in
            let boundaries = PackedWaterBoundarySource(data: input.pack)
            guard case .success = boundaries.validation else { return [] }
            return OffWaterSuggestions.suggest(in: session, using: boundaries)
        }.value
        guard !Task.isCancelled, input == suggestionInput, sourceIsCurrent() else { return }
        suggestionResult = (input, result)
    }

    private func updatePreview(for request: PreviewRequest) async {
        guard !Task.isCancelled, previewRequest == request, !recordingChanged else { return }
        let updateDraft = preview.draft != request.draft
        let updateProposal = request.proposed != nil && proposalResult?.request != request
        guard updateDraft || updateProposal else { return }
        do {
            if updateDraft { try await Task.sleep(for: .milliseconds(120)) }
            let input = analysis
            let results = try await Task.detached(priority: .userInitiated) {
                let base = try (updateDraft ? Self.calculatePreview(for: request.draft, using: input) : nil)
                let proposed = try request.proposed.map { try Self.calculatePreview(for: $0, using: input) }
                return (base, proposed)
            }.value
            guard !Task.isCancelled, previewRequest == request, sourceIsCurrent() else { return }
            if let base = results.0 { preview = base }
            proposalResult = results.1.map { (request, $0) }
        } catch {
            guard !Task.isCancelled, previewRequest == request, sourceIsCurrent() else { return }
            reviewing = nil
            self.error = "Couldn't calculate the selected trim."
        }
    }

    private nonisolated static func calculatePreview(
        for draft: Draft, using analysis: SessionDetailView.Analysis
    ) throws -> Preview {
        if draft.cuts.isEmpty, draft.bounds == 0...SessionTrim.availableEnd(in: analysis.session) {
            return Preview(draft: draft, trim: nil, presentation: analysis.original)
        }
        let trim = try SessionTrim(retaining: draft.spans)
        let selection = try SessionSelection(session: analysis.session, trim: trim, profile: analysis.profile)
        return Preview(
            draft: draft, trim: trim,
            presentation: .init(selection: selection, display: analysis.display, isTrimmed: true))
    }

    private func sourceIsCurrent() -> Bool {
        guard !recordingChanged else { return false }
        guard SessionLibrary.source(for: analysis.source.entry.folder) == analysis.source else {
            invalidateRecording()
            return false
        }
        return true
    }

    private func invalidateRecording() {
        recordingChanged = true
        error = "The recording changed while you were editing. Close the editor and try again."
    }

    private func apply(_ trim: SessionTrim?, presentation: SessionDetailView.Presentation) {
        do {
            try save(trim, presentation)
            dismiss()
        } catch SessionLibrary.EditError.recordingChanged {
            invalidateRecording()
        } catch {
            self.error = "Couldn't update the local trim."
        }
    }
}
