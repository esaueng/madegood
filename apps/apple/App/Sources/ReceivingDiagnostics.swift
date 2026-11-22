import Combine
import SwiftUI
import WaterKit

/// Shown under a recording the iPhone can't read yet (History's "Receiving…" row): every
/// item in its folder with its size, then the watch-transfer log for it and for all
/// recordings. For finding out why a recording from the watch does not complete.
struct ReceivingDiagnostics: View {
    let folder: URL
    @State private var items: [(name: String, size: Int64?)] = []
    @State private var sessionLog: [TransferLog.Entry] = []
    @State private var allLog: [TransferLog.Entry] = []
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var sessionId: String { folder.lastPathComponent }

    var body: some View {
        Group {
            Section {
                if items.isEmpty {
                    Text("The folder is empty.").foregroundStyle(.secondary)
                }
                ForEach(items, id: \.name) { item in
                    LabeledContent(item.name, value: item.size.map { "\($0) bytes" } ?? "unreadable")
                        .font(.footnote)
                }
            } header: {
                Text("Files received")
            } footer: {
                Text("Recording \(sessionId)").textSelection(.enabled)
            }
            Section("Transfer log for this recording") {
                logRows(sessionLog, showsSession: false)
            }
            Section("Transfer log, all recordings") {
                logRows(allLog, showsSession: true)
            }
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    @ViewBuilder
    private func logRows(_ entries: [TransferLog.Entry], showsSession: Bool) -> some View {
        if entries.isEmpty {
            Text("Nothing logged yet.").foregroundStyle(.secondary)
        }
        ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message).font(.footnote).textSelection(.enabled)
                Text(
                    [
                        entry.date.formatted(date: .abbreviated, time: .standard),
                        showsSession ? entry.sessionId.map(TransferLog.short) : nil,
                    ]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        items = names.map { name in
            let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return (name, (attributes?[.size] as? NSNumber)?.int64Value)
        }
        sessionLog = Array(TransferLog.shared.recent(sessionId: sessionId).prefix(40))
        allLog = Array(TransferLog.shared.recent().prefix(40))
    }
}
