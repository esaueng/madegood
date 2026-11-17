import SwiftUI
import WaterKit

/// Phase 0 raw recorder (watch): pick a sport, record, mark, stop. Finished recordings
/// are sent to the iPhone and removed from the watch once delivered.
struct WatchContentView: View {
    @State private var recorder = SessionRecorder()
    @State private var waiting: [RecordingStore.Entry] = []

    var body: some View {
        NavigationStack {
            switch recorder.state {
            case .idle:
                SportPicker(recorder: recorder, waiting: waiting)
            case .starting, .stopping:
                ProgressView()
            case .recording(_, let startedAt, let sport):
                RecordingView(recorder: recorder, startedAt: startedAt, sport: sport)
            }
        }
        .onAppear {
            recorder.onFinish = { folder in
                RecordingTransfer.shared.send(folder: folder)
                reload()
            }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingTransfer.didDeliverRecording)) { _ in
            reload()
        }
    }

    private func reload() {
        waiting = RecordingStore.list()
    }
}

private struct SportPicker: View {
    let recorder: SessionRecorder
    let waiting: [RecordingStore.Entry]

    var body: some View {
        List {
            ForEach(Sport.allCases, id: \.self) { sport in
                Button {
                    Task { await recorder.start(sport: sport) }
                } label: {
                    Label(sport.displayName, systemImage: sport.symbolName)
                }
            }
            if let error = recorder.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !waiting.isEmpty {
                Section {
                    Label("\(waiting.count) waiting for iPhone", systemImage: "iphone.and.arrow.forward")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Send again") {
                        RecordingTransfer.shared.sendAllPending()
                    }
                }
            }
        }
        .navigationTitle("Record")
    }
}

private struct RecordingView: View {
    let recorder: SessionRecorder
    let startedAt: Date
    let sport: Sport
    @State private var confirmStop = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Label(sport.displayName, systemImage: sport.symbolName)
                    .font(.footnote)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Formatting.elapsed(context.date.timeIntervalSince(startedAt)))
                        .font(.title.monospacedDigit().bold())
                }
                CountsGrid(counts: recorder.counts)
                HStack {
                    Button {
                        recorder.mark()
                    } label: {
                        Image(systemName: "flag.fill")
                    }
                    .tint(.blue)
                    Button {
                        confirmStop = true
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .tint(.red)
                }
                if let error = recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .confirmationDialog("End recording?", isPresented: $confirmStop) {
            Button("End", role: .destructive) {
                Task { await recorder.stop() }
            }
        }
    }
}

#Preview {
    WatchContentView()
}
