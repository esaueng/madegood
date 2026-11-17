import SwiftUI
import WaterKit

/// Phase 0 raw recorder (iPhone): record a session on the phone, and collect, share, or
/// delete recordings made here or on the watch.
struct ContentView: View {
    @State private var recorder = SessionRecorder()
    @State private var recordings: [RecordingStore.Entry] = []
    @AppStorage("recorder.sport") private var sportRaw = Sport.kayak.rawValue

    private var sport: Sport { Sport(rawValue: sportRaw) ?? .kayak }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RecordControls(recorder: recorder, sportRaw: $sportRaw)
                } header: {
                    Text("Record on iPhone")
                } footer: {
                    Text("Raw recorder for algorithm work. Recordings stay on this device until you share them.")
                }

                Section("Recordings") {
                    if recordings.isEmpty {
                        Text("No recordings yet. Recordings made on the watch appear here after it sends them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recordings) { entry in
                        NavigationLink(value: entry) { RecordingRow(entry: entry) }
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle(AppInfo.name)
            .navigationDestination(for: RecordingStore.Entry.self) { entry in
                RecordingDetail(entry: entry)
            }
            .refreshable { reload() }
        }
        .onAppear {
            recorder.onFinish = { _ in reload() }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didReceiveFile)) { _ in reload() }
    }

    private func reload() {
        recordings = RecordingStore.list()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? RecordingStore.delete(recordings[index])
        }
        reload()
    }
}

private struct RecordControls: View {
    let recorder: SessionRecorder
    @Binding var sportRaw: String

    var body: some View {
        switch recorder.state {
        case .idle:
            Picker("Sport", selection: $sportRaw) {
                ForEach(Sport.allCases, id: \.rawValue) { sport in
                    Label(sport.displayName, systemImage: sport.symbolName).tag(sport.rawValue)
                }
            }
            Button {
                Task { await recorder.start(sport: Sport(rawValue: sportRaw) ?? .kayak) }
            } label: {
                Label("Start recording", systemImage: "record.circle")
            }
            if let error = recorder.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        case .starting, .stopping:
            ProgressView()
        case .recording(_, let startedAt, let sport):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(sport.displayName, systemImage: sport.symbolName)
                    Spacer()
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Formatting.elapsed(context.date.timeIntervalSince(startedAt)))
                            .font(.title2.monospacedDigit().bold())
                    }
                }
                CountsGrid(counts: recorder.counts)
                if let error = recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
            Button {
                recorder.mark()
            } label: {
                Label("Mark", systemImage: "flag")
            }
            Button(role: .destructive) {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
        }
    }
}

private struct RecordingRow: View {
    let entry: RecordingStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let sport = entry.meta?.sport {
                    Label(sport.displayName, systemImage: sport.symbolName)
                } else {
                    Label("Receiving…", systemImage: "applewatch.radiowaves.left.and.right")
                }
                Spacer()
                Text(Formatting.bytes(entry.bytes)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let startedAt = entry.startedAt {
                    Text(startedAt, format: .dateTime.day().month().hour().minute())
                }
                if let duration = entry.duration {
                    Text("· \(Formatting.elapsed(duration))")
                }
                if let device = entry.meta?.device.kind {
                    Text("· \(device)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RecordingDetail: View {
    let entry: RecordingStore.Entry
    @State private var zipURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Files") {
                ForEach(entry.files, id: \.self) { name in
                    Text(name).font(.footnote.monospaced())
                }
            }
            if let meta = entry.meta {
                Section("Recording") {
                    LabeledContent("Sport", value: meta.sport.displayName)
                    LabeledContent("Device", value: "\(meta.device.model), \(meta.device.os)")
                    LabeledContent("Session", value: meta.sessionId.uuidString.lowercased())
                        .font(.footnote)
                    if meta.endedAt == nil {
                        Text("No clean stop recorded; the files hold everything flushed before it ended.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if let zipURL {
                    ShareLink(item: zipURL) {
                        Label("Share zip", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        prepareZip()
                    } label: {
                        Label("Prepare zip for sharing", systemImage: "doc.zipper")
                    }
                }
                if let exportError {
                    Text(exportError).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Recordings contain precise locations and times. Anonymize them before posting publicly (scripts/anonymize-track).")
            }
        }
        .navigationTitle(entry.meta?.sport.displayName ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func prepareZip() {
        do {
            zipURL = try ZipExport.zip(folder: entry.folder)
        } catch {
            exportError = "Could not create the zip: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
