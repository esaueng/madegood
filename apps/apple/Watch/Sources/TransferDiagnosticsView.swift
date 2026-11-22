import Combine
import SwiftUI
import WatchConnectivity
import WaterKit

/// About → iPhone → Waiting to send: for each recording still on the watch, its files, what
/// is being sent, and what the iPhone last said it holds; then the transfer log. For finding
/// out why a recording does not reach the iPhone.
struct TransferDiagnosticsView: View {
    @State private var recordings: [RecordingStore.Entry] = []
    @State private var log: [TransferLog.Entry] = []
    @State private var connection = Connection()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    struct Connection: Equatable {
        var status = ""
        var companionInstalled = false
        var reachable = false
        var phoneReads = ""

        static func current() -> Connection {
            let session = WCSession.default
            let status =
                switch session.activationState {
                case .activated: "Active"
                case .inactive: "Inactive"
                case .notActivated: "Not active"
                @unknown default: "Unknown"
                }
            let versions = RecordingTransfer.phoneRawVersions(fromContext: session.receivedApplicationContext)
            return Connection(
                status: status, companionInstalled: session.isCompanionAppInstalled, reachable: session.isReachable,
                phoneReads: versions.sorted().map(String.init).joined(separator: ", "))
        }
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: connection.status)
                LabeledContent("iPhone app", value: connection.companionInstalled ? "Installed" : "Missing")
                LabeledContent("Reachable", value: connection.reachable ? "Yes" : "No")
                LabeledContent("Reads raw", value: connection.phoneReads)
            }
            if recordings.isEmpty {
                Text("Every recording has reached the iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(recordings) { entry in
                RecordingSection(entry: entry)
            }
            if !recordings.isEmpty {
                Button("Send again") {
                    RecordingTransfer.shared.sendAllPending(requeue: .all)
                    reload()
                }
            }
            Section("Log") {
                if log.isEmpty {
                    Text("Nothing yet.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(log.prefix(60)) { entry in
                    LogRow(entry: entry, showsSession: true)
                }
            }
        }
        .navigationTitle("Waiting to send")
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
        .accessibilityIdentifier("transfer.diagnostics")
    }

    private func reload() {
        recordings = RecordingStore.list()
        log = TransferLog.shared.recent()
        connection = .current()
    }
}

private struct RecordingSection: View {
    let entry: RecordingStore.Entry

    private var sessionId: String { entry.folder.lastPathComponent }

    var body: some View {
        let phone = RecordingTransfer.shared.phoneFiles(sessionId: sessionId)
        let local = RecordingTransfer.recordingFiles(in: entry.folder) ?? [:]
        let others = otherItems()
        Section {
            if !RecordingTransfer.shared.phoneReads(folder: entry.folder) {
                Text("The iPhone app can't read this recording's format.").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(local.sorted { $0.key < $1.key }, id: \.key) { name, size in
                VStack(alignment: .leading) {
                    Text(name).font(.footnote)
                    Text("\(size) bytes · \(status(name: name, size: size, phone: phone))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(others, id: \.self) { name in
                Text("\(name) (not sent)").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(RecordingTransfer.shared.outstanding(sessionId: sessionId), id: \.self) { transfer in
                Text(describe(transfer)).font(.caption2)
            }
            if phone == nil {
                Text("The iPhone hasn't reported this recording since this launch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(TransferLog.shared.recent(sessionId: sessionId).prefix(8)) { entry in
                LogRow(entry: entry, showsSession: false)
            }
        } header: {
            VStack(alignment: .leading) {
                Text(entry.meta?.sport.displayName ?? "Unreadable recording")
                if let startedAt = entry.startedAt {
                    Text(startedAt.formatted(date: .abbreviated, time: .shortened)).textCase(nil)
                }
                Text(TransferLog.short(sessionId)).textCase(nil).monospaced()
            }
        }
    }

    private func status(name: String, size: Int64, phone: [String: Int64]?) -> String {
        guard let phone else { return "iPhone: unknown" }
        guard let held = phone[name] else { return "missing on iPhone" }
        return held == size ? "on iPhone" : "iPhone has \(held) bytes"
    }

    private func describe(_ transfer: RecordingTransfer.Outstanding) -> String {
        let percent = Int(transfer.fractionCompleted * 100)
        let state = transfer.isTransferring ? "sending" : "queued"
        let age = transfer.queuedAt.map { " · \(Int(Date().timeIntervalSince($0) / 60)) min" } ?? ""
        return "\(state) \(transfer.file) \(percent)%\(age)"
    }

    /// Anything in the folder that is not a recording file (never sent).
    private func otherItems() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: entry.folder.path)) ?? []
        return names.filter { !RecordingStore.isRecordingFileName($0) }.sorted()
    }
}

private struct LogRow: View {
    let entry: TransferLog.Entry
    let showsSession: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text(entry.message).font(.caption2)
            Text(
                [
                    entry.date.formatted(date: .omitted, time: .standard),
                    showsSession ? entry.sessionId.map(TransferLog.short) : nil,
                ]
                .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
