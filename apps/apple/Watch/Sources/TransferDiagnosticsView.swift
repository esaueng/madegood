import Combine
import SwiftUI
import WatchConnectivity
import WaterKit

/// About → iPhone → Waiting to send: for each recording still on the watch, its files, what
/// is being sent, and what the iPhone last said it holds; then the transfer log. For finding
/// out why a recording does not reach the iPhone.
struct TransferDiagnosticsView: View {
    @State private var recordings: [Pending] = []
    @State private var log: [TransferLog.Entry] = []
    @State private var connection = Connection()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    struct Connection: Equatable {
        var status = ""
        var reachable = false
        var phoneReads = ""
        var nextWake = ""

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
            let wake = RecordingTransfer.shared.nextBackgroundWake()
            return Connection(
                status: status, reachable: session.isReachable,
                phoneReads: versions.sorted().map(String.init).joined(separator: ", "),
                nextWake: wake.map { $0.formatted(date: .omitted, time: .shortened) } ?? "None")
        }
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: connection.status)
                LabeledContent("Reachable", value: connection.reachable ? "Yes" : "No")
                LabeledContent("Reads raw", value: connection.phoneReads)
                LabeledContent("Next wake", value: connection.nextWake)
            }
            if recordings.isEmpty {
                Text("Every recording has reached the iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(recordings) { pending in
                RecordingSection(pending: pending)
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
        recordings = RecordingStore.list().map(Pending.init)
        log = TransferLog.shared.recent()
        connection = .current()
    }
}

/// One waiting recording as polled, so a refresh redraws its rows.
private struct Pending: Identifiable, Equatable {
    var id: URL { entry.folder }
    var entry: RecordingStore.Entry
    var local: [String: Int64]
    var others: [String]
    var outstanding: [RecordingTransfer.Outstanding]
    var phone: RecordingTransfer.PhoneHolds?
    var retry: RecordingTransfer.Retry?
    var metaReadable: Bool
    var phoneReads: Bool
    var log: [TransferLog.Entry]

    init(entry: RecordingStore.Entry) {
        let sessionId = entry.folder.lastPathComponent
        self.entry = entry
        local = RecordingTransfer.recordingFiles(in: entry.folder) ?? [:]
        others = ((try? FileManager.default.contentsOfDirectory(atPath: entry.folder.path)) ?? [])
            .filter { !RecordingStore.isRecordingFileName($0) }.sorted()
        outstanding = RecordingTransfer.shared.outstanding(sessionId: sessionId)
        phone = RecordingTransfer.shared.phoneFiles(sessionId: sessionId)
        retry = RecordingTransfer.shared.retry(sessionId: sessionId)
        let meta = try? Data(contentsOf: entry.folder.appendingPathComponent(RawFormat.metaFileName))
        metaReadable = meta.flatMap(RecordingTransfer.metaVersion) != nil
        phoneReads = RecordingTransfer.shared.phoneReads(folder: entry.folder)
        log = Array(TransferLog.shared.recent(sessionId: sessionId).prefix(8))
    }
}

private struct RecordingSection: View {
    let pending: Pending

    private var entry: RecordingStore.Entry { pending.entry }
    private var sessionId: String { entry.folder.lastPathComponent }

    var body: some View {
        let phone = pending.phone
        let local = pending.local
        let others = pending.others
        Section {
            if !pending.metaReadable {
                Text("This recording's meta.json is missing or unreadable.").font(.footnote).foregroundStyle(.orange)
            } else if !pending.phoneReads {
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
            ForEach(pending.outstanding.prefix(6), id: \.self) { transfer in
                Text(describe(transfer)).font(.caption2)
            }
            if pending.outstanding.count > 6 {
                Text("and \(pending.outstanding.count - 6) more queued").font(.caption2).foregroundStyle(.secondary)
            }
            if let retry = pending.retry, retry.failures > 0 {
                let when = retry.at.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
                Text("Failed \(retry.failures)× in a row; sending again\(when)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if phone == nil {
                Text("The iPhone hasn't reported on this recording yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(pending.log) { entry in
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

    private func status(name: String, size: Int64, phone: RecordingTransfer.PhoneHolds?) -> String {
        guard let phone else { return "iPhone: unknown" }
        if let held = phone.files[name] {
            return held == size ? "on iPhone" : "iPhone has \(held) bytes"
        }
        let parts = TransferParts.plan(file: name, size: size)
        if let first = parts.first, let held = phone.parts[TransferParts.layoutKey(first)] {
            return "\(held.count) of \(parts.count) parts on iPhone"
        }
        return "missing on iPhone"
    }

    private func describe(_ transfer: RecordingTransfer.Outstanding) -> String {
        let percent = Int(transfer.fractionCompleted * 100)
        let state = transfer.isTransferring ? "sending" : "queued"
        let age = transfer.queuedAt.map { " · \(Int(Date().timeIntervalSince($0) / 60)) min" } ?? ""
        return "\(state) \(transfer.name) \(percent)%\(age)"
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
