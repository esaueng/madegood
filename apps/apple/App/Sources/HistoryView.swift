import SwiftUI
import WaterKit

/// Every session on this phone, newest first, grouped by month with totals.
struct HistoryView: View {
    let library: SessionLibrary

    var body: some View {
        NavigationStack {
            List {
                if library.items.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet", systemImage: "water.waves",
                        description: Text("Sessions you record on the watch or this phone show up here."))
                }
                ForEach(months, id: \.title) { month in
                    Section {
                        ForEach(month.items) { item in
                            NavigationLink(value: item) { SessionRow(item: item) }
                                .accessibilityIdentifier("session.row")
                        }
                        .onDelete { offsets in
                            for index in offsets { library.delete(month.items[index]) }
                        }
                    } header: {
                        MonthHeader(title: month.title, items: month.items)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: SessionLibrary.Item.self) { item in
                SessionDetailView(item: item, library: library)
            }
            .refreshable { library.reload() }
        }
    }

    private var months: [(title: String, items: [SessionLibrary.Item])] {
        var groups: [(title: String, items: [SessionLibrary.Item])] = []
        for item in library.items {
            let title = item.entry.startedAt.map { $0.formatted(.dateTime.month(.wide).year()) } ?? "Receiving"
            if groups.last?.title == title {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((title, [item]))
            }
        }
        return groups
    }
}

private struct MonthHeader: View {
    let title: String
    let items: [SessionLibrary.Item]

    var body: some View {
        let totals = SessionLibrary.totals(items)
        HStack {
            Text(title)
            Spacer()
            if totals.count > 0 {
                // Totals mix sports, so they use the paddling (metric) distance unless set.
                let display = UserSettings.display(for: .kayak)
                Text(
                    "\(totals.count) \(totals.count == 1 ? "session" : "sessions") · \(display.distance(totals.distance)) · \(Formatting.duration(totals.movingTime))"
                )
                .monospacedDigit()
                .accessibilityIdentifier("month.totals")
            }
        }
    }
}

/// One session in a list: sport, when, and the headline numbers.
struct SessionRow: View {
    let item: SessionLibrary.Item

    var body: some View {
        let sport = item.summary?.sport ?? item.entry.meta?.sport
        HStack(spacing: 12) {
            Image(systemName: sport?.symbolName ?? "applewatch.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(sport?.displayName ?? "Receiving…").font(.body.weight(.semibold))
                if let startedAt = item.entry.startedAt {
                    Text(startedAt, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let summary = item.summary {
                let display = UserSettings.display(for: summary.sport)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(display.distance(summary.metrics.distance)).font(.body.weight(.semibold).monospacedDigit())
                    Text(Formatting.elapsed(summary.metrics.movingTime))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if item.entry.meta != nil {
                ProgressView()
            }
        }
        .contentShape(.rect)
    }
}
