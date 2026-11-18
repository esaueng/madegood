import SwiftUI
import WaterKit

struct VoyagesView: View {
    let recorder: VoyageRecorder
    @State private var path: [UUID] = []
    @State private var namingVoyage = false
    @State private var name = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let active = recorder.activeVoyage {
                    Section("Active leg") {
                        NavigationLink(value: active.id) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(active.name)
                                    if !recorder.isCapturing {
                                        Text("Capture interrupted")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: recorder.isCapturing ? "location.fill" : "pause.circle")
                            }
                        }
                        .accessibilityValue(recorder.isCapturing ? "Recording" : "Capture interrupted")
                        .accessibilityIdentifier("voyage.activeLeg")
                    }
                }
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if !recorder.isAvailable {
                    Button("Retry Opening Voyages", action: recorder.openLibrary)
                } else if recorder.voyages.isEmpty {
                    ContentUnavailableView(
                        "No Voyages", systemImage: "sailboat",
                        description: Text("Create a voyage to start recording legs on this iPhone."))
                } else {
                    Section("Voyages") {
                        ForEach(recorder.voyages) { voyage in
                            NavigationLink(voyage.name, value: voyage.id)
                        }
                    }
                }
            }
            .navigationTitle("Voyages")
            .task { recorder.openLibrary() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Voyage", systemImage: "plus") {
                        name = ""
                        namingVoyage = true
                    }
                    .disabled(!recorder.isAvailable)
                }
            }
            .alert("New Voyage", isPresented: $namingVoyage) {
                TextField("Voyage name", text: $name)
                Button("Create") {
                    if let voyage = recorder.createVoyage(named: name) { path.append(voyage.id) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(for: UUID.self) { id in
                VoyageDetailView(id: id, recorder: recorder)
            }
        }
    }
}

private struct VoyageDetailView: View {
    let id: UUID
    let recorder: VoyageRecorder

    var body: some View {
        if let voyage = recorder.voyages.first(where: { $0.id == id }) {
            List {
                if recorder.activeVoyage?.id == id, let leg = recorder.activeLeg {
                    activeLeg(leg)
                } else if recorder.activeLeg == nil {
                    Section {
                        Button("Start Leg", systemImage: "location") { recorder.startLeg(in: id) }
                    } footer: {
                        Text("MadeGood uses location in the background until you end the leg.")
                    }
                } else {
                    Text("End the active leg before starting another.")
                        .foregroundStyle(.secondary)
                }
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                let finished = voyage.legs.filter { $0.endedAt != nil }
                if !finished.isEmpty {
                    Section("Saved Legs") {
                        ForEach(finished.reversed()) { leg in
                            NavigationLink {
                                SavedVoyageLegView(leg: leg, recorder: recorder)
                            } label: {
                                Label {
                                    Text(
                                        Date(timeIntervalSince1970: leg.startedAt),
                                        format: .dateTime.month().day().hour().minute()
                                    )
                                } icon: {
                                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                }
                            }
                            .accessibilityIdentifier("voyage.savedLeg")
                        }
                    }
                }
            }
            .navigationTitle(voyage.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private func activeLeg(_ leg: VoyageLeg) -> some View {
        Section("Active leg") {
            LabeledContent("Started") {
                Text(Date(timeIntervalSince1970: leg.startedAt), format: .dateTime.month().day().hour().minute())
            }
            LabeledContent("Positions saved", value: recorder.fixCount.formatted())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Positions saved")
                .accessibilityValue(recorder.fixCount.formatted())
                .accessibilityIdentifier("voyage.activeFixCount")
            if let fix = recorder.lastFix {
                LastVoyagePosition(position: fix)
            }
            if recorder.isCapturing {
                Label(recorder.locationStatus, systemImage: "location.fill")
            } else {
                Text("Capture interrupted. Resume to keep recording this leg.")
                    .foregroundStyle(.secondary)
                Button("Resume Leg", systemImage: "play.fill", action: recorder.resumeLeg)
            }
            Button("End Leg", role: .destructive, action: recorder.endLeg)
        }
        if let gap = recorder.latestGap {
            Section("Latest Capture Gap") {
                VoyageGapInterval(gap: gap)
            }
        }
    }
}

private struct SavedVoyageLegView: View {
    let leg: VoyageLeg
    let recorder: VoyageRecorder
    @State private var track: [VoyageTrackPoint]?
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                legTime("Started", at: leg.startedAt)
                if let end = leg.endedAt { legTime("Ended", at: end) }
                if let track {
                    LabeledContent("Positions saved", value: track.count.formatted())
                    if let last = track.last?.position {
                        LastVoyagePosition(position: last)
                    }
                }
            }
            if let track {
                let gaps = track.compactMap(\.gapBefore) + [leg.endingGap].compactMap { $0 }
                if !gaps.isEmpty {
                    Section("Capture Gaps") {
                        ForEach(gaps, id: \.self) { gap in
                            VoyageGapInterval(gap: gap)
                        }
                    }
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Saved Leg")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                track = try recorder.track(for: leg)
            } catch {
                loadError = "Couldn’t read the saved positions."
            }
        }
    }

    private func legTime(_ label: String, at timestamp: TimeInterval) -> some View {
        LabeledContent(label) {
            Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month().day().hour().minute())
        }
    }
}

private struct LastVoyagePosition: View {
    let position: VoyagePosition

    var body: some View {
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        LabeledContent {
            Text("\(position.latitude, format: precision), \(position.longitude, format: precision)")
                .monospacedDigit()
        } label: {
            Text("Last saved position")
            Text(
                Date(timeIntervalSince1970: position.timestamp),
                format: .dateTime.month().day().hour().minute().second())
        }
        .accessibilityIdentifier("voyage.lastSavedPosition")
    }
}

private struct VoyageGapInterval: View {
    let gap: VoyageGap

    var body: some View {
        Text(
            Date(timeIntervalSince1970: gap.start)..<Date(timeIntervalSince1970: gap.end),
            format: .interval.month().day().hour().minute().second()
        )
    }
}
