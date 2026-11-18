import SwiftUI
import WaterKit

/// Both handles and the route here use the original recording clock.
struct SessionTrimEditor: View {
    let analysis: SessionDetailView.Analysis
    let save: (SessionTrim?, SessionDetailView.Presentation) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bounds: ClosedRange<Double>
    @State private var elapsed: Double?
    @State private var preview: Preview
    @State private var error: String?

    private struct Preview {
        let bounds: ClosedRange<Double>
        let trim: SessionTrim?
        let presentation: SessionDetailView.Presentation
    }

    private var availableEnd: Double { SessionTrim.availableEnd(in: analysis.session) }
    private var minSpan: Double {
        min(0.001, availableEnd / 2, analysis.trim.map { $0.range.upperBound - $0.range.lowerBound } ?? 1)
    }

    init(
        analysis: SessionDetailView.Analysis,
        save: @escaping (SessionTrim?, SessionDetailView.Presentation) throws -> Void
    ) {
        self.analysis = analysis
        self.save = save
        let initial = analysis.trim?.range ?? 0...SessionTrim.availableEnd(in: analysis.session)
        _bounds = State(initialValue: initial)
        _elapsed = State(initialValue: initial.lowerBound)
        _preview = State(initialValue: Preview(bounds: initial, trim: analysis.trim, presentation: analysis.current))
    }

    var body: some View {
        let replayData = analysis.original.replayData
        NavigationStack {
            List {
                Section {
                    boundary("Keep from", value: bounds.lowerBound, limits: 0...max(0, bounds.upperBound - minSpan))
                    boundary(
                        "Keep through", value: bounds.upperBound,
                        limits: min(availableEnd, bounds.lowerBound + minSpan)...availableEnd)
                } footer: {
                    Text("Times are measured from the start of the original recording.")
                }

                if !replayData.timeline.points.isEmpty {
                    SessionReplayView(
                        data: replayData, display: analysis.display, elapsed: $elapsed, isPlaying: .constant(false),
                        highlight: .init(
                            keptRange: bounds,
                            preview: preview.bounds == bounds ? preview.presentation.replayData : nil),
                        allowsPlayback: false)
                }

                Section("Preview") {
                    metrics("Original", selection: analysis.original.selection)
                    if preview.bounds == bounds {
                        metrics("Kept", selection: preview.presentation.selection)
                        if preview.presentation.replayData.timeline.points.isEmpty {
                            Text("No usable GPS fixes in this interval.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView("Updating preview")
                    }
                }
                if analysis.trim != nil {
                    Button("Restore Original") { apply(nil, presentation: analysis.original) }
                        .accessibilityIdentifier("trim.restore")
                }
            }
            .navigationTitle("Trim Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { apply(preview.trim, presentation: preview.presentation) }
                        .disabled(preview.bounds != bounds)
                        .accessibilityIdentifier("trim.save")
                }
            }
            .task(id: bounds) { await updatePreview(for: bounds) }
            .alert(
                "Trim Session", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func boundary(_ title: String, value: Double, limits: ClosedRange<Double>) -> some View {
        let isStart = title == "Keep from"
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
                        get: { isStart ? bounds.lowerBound : bounds.upperBound },
                        set: { time in
                            if isStart {
                                let start = min(time, max(0, bounds.upperBound - minSpan))
                                bounds = start...bounds.upperBound
                                elapsed = start
                            } else {
                                let end = max(time, min(availableEnd, bounds.lowerBound + minSpan))
                                bounds = bounds.lowerBound...end
                                elapsed = end
                            }
                        }),
                    in: limits
                ) {
                    Text(title)
                }
                .accessibilityValue(time)
                .accessibilityIdentifier(isStart ? "trim.start" : "trim.end")
            }
        }
    }

    private func metrics(_ title: String, selection: SessionSelection) -> some View {
        let metrics = selection.replay.metrics
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            LabeledContent("Distance", value: analysis.display.distance(metrics.distance))
            LabeledContent("Total time", value: SessionReplayView.Highlight.time(selection.duration))
            LabeledContent("Average speed", value: analysis.display.speed(metrics.averageSpeed))
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trim.preview.\(title)")
    }

    private func updatePreview(for range: ClosedRange<Double>) async {
        guard !Task.isCancelled, bounds == range, preview.bounds != range else { return }
        if range == 0...availableEnd {
            preview = Preview(bounds: range, trim: nil, presentation: analysis.original)
            return
        }

        do {
            // Coalesce slider changes before running the analysis.
            try await Task.sleep(for: .milliseconds(120))
            let session = analysis.session
            let profile = analysis.profile
            let display = analysis.display
            let result = try await Task.detached(priority: .userInitiated) {
                let trim = try SessionTrim(start: range.lowerBound, end: range.upperBound)
                let selection = try SessionSelection(session: session, trim: trim, profile: profile)
                return Preview(
                    bounds: range, trim: trim,
                    presentation: SessionDetailView.Presentation(
                        selection: selection, display: display, isTrimmed: true))
            }.value
            guard !Task.isCancelled, range == bounds else { return }
            preview = result
        } catch {
            guard !Task.isCancelled, range == bounds else { return }
            self.error = "Couldn't calculate the selected trim."
        }
    }

    private func apply(_ trim: SessionTrim?, presentation: SessionDetailView.Presentation) {
        do {
            try save(trim, presentation)
            dismiss()
        } catch SessionLibrary.EditError.recordingChanged {
            error = "The recording changed while you were editing. Close the editor and try again."
        } catch {
            self.error = "Couldn't update the local trim."
        }
    }
}
