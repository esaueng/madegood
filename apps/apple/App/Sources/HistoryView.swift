import SwiftUI
import WaterKit

/// Sessions on this phone, newest first, grouped by month with totals for the current filters.
struct HistoryView: View {
    let library: SessionLibrary
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sport: Sport?
    @State private var dates: HistoryDates = .all
    @State private var choosingDates = false
    @State private var deleteFailed = false

    private var isFiltered: Bool { sport != nil || dates != .all }

    var body: some View {
        let shown = filteredItems(on: .now)
        // Keep mixed-sport totals in the established History unit (the kayak preference).
        let display = UserSettings.display(for: sport ?? .kayak)
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        filters
                        if case .custom(let start, let end) = dates {
                            Text(
                                "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if !shown.isEmpty {
                        HistoryTotals(items: shown, display: display)
                            .accessibilityIdentifier("history.totals")
                    }
                }
                if shown.isEmpty {
                    emptyState
                }
                ForEach(months(in: shown), id: \.title) { month in
                    Section {
                        ForEach(month.items) { item in
                            NavigationLink(value: item) { SessionRow(item: item, showsRoute: true) }
                                .accessibilityIdentifier("session.row")
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                do {
                                    try library.delete(month.items[index])
                                } catch {
                                    deleteFailed = true
                                }
                            }
                        }
                    } header: {
                        MonthHeader(title: month.title, items: month.items, display: display)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: SessionLibrary.Item.self) { item in
                SessionDetailView(item: item, library: library)
            }
            .sheet(isPresented: $choosingDates) {
                HistoryDateRangePicker(range: dates.range(on: .now, calendar: calendar)) { start, end in
                    dates = .custom(start: start, end: end)
                }
            }
            .alert("Couldn't delete the session or its local trim.", isPresented: $deleteFailed) {
                Button("OK") {}
            }
            .refreshable { library.reload() }
            // Settings such as auto-pause change the summaries; cached ones are reused.
            .onAppear { library.reload() }
            .onReceive(NotificationCenter.default.publisher(for: UserSettings.didChangeRemotely)) { _ in
                library.reload()
            }
        }
    }

    private var filters: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            Menu {
                Picker("Sport", selection: $sport) {
                    Text("All Sports").tag(nil as Sport?)
                    ForEach(Sport.allCases, id: \.self) { sport in
                        Text(sport.displayName).tag(Optional(sport))
                    }
                }
            } label: {
                Label(sport?.displayName ?? "All Sports", systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityIdentifier("history.sportFilter")

            Menu {
                Picker("Dates", selection: $dates) {
                    ForEach(HistoryDates.presets, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                    if case .custom = dates { Text(dates.title).tag(dates) }
                }
                Button("Choose Dates…") { choosingDates = true }
            } label: {
                Label(dates.title, systemImage: "calendar")
            }
            .accessibilityIdentifier("history.dateFilter")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var emptyState: some View {
        if isFiltered {
            ContentUnavailableView {
                Label("No matching sessions", systemImage: "line.3.horizontal.decrease")
            } actions: {
                Button("Clear Filters") {
                    sport = nil
                    dates = .all
                }
            }
        } else {
            ContentUnavailableView(
                "No sessions yet", systemImage: "water.waves",
                description: Text("Sessions you record on the watch or this phone show up here."))
        }
    }

    private func filteredItems(on now: Date) -> [SessionLibrary.Item] {
        let range = dates.range(on: now, calendar: calendar)
        return library.items.filter { item in
            if let sport, item.entry.meta?.sport != sport { return false }
            if let range {
                guard let start = item.entry.startedAt else { return false }
                return range.contains(start)
            }
            return true
        }
    }

    private func months(in items: [SessionLibrary.Item]) -> [(title: String, items: [SessionLibrary.Item])] {
        var groups: [(title: String, items: [SessionLibrary.Item])] = []
        for item in items {
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
    let display: LiveDisplay

    var body: some View {
        // Title over totals, so long totals never squeeze the month onto two lines.
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.bold))
                .fontDesign(.rounded)
                // Concrete colors: section headers dim hierarchical styles.
                .foregroundStyle(Color.primary)
            if title != "Receiving" {
                HistoryTotals(items: items, display: display)
                    .accessibilityIdentifier("month.totals")
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

private struct HistoryTotals: View {
    let items: [SessionLibrary.Item]
    let display: LiveDisplay

    var body: some View {
        let totals = SessionLibrary.totals(items)
        let pending = items.count - totals.count
        var parts = ["\(items.count) \(items.count == 1 ? "session" : "sessions")"]
        if totals.count > 0 {
            parts += [display.distance(totals.distance), Formatting.duration(totals.movingTime)]
        }
        if pending > 0 { parts.append("\(pending) awaiting metrics") }
        return Text(parts.joined(separator: " · "))
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(Color.secondary)
    }
}

/// One session in a list: sport, when, and the headline numbers.
struct SessionRow: View {
    let item: SessionLibrary.Item
    var showsRoute = false

    var body: some View {
        let sport = item.summary?.sport ?? item.entry.meta?.sport
        HStack(spacing: 12) {
            Group {
                if let sport {
                    SportIcon(sport: sport, size: 26)
                } else {
                    Image(systemName: "applewatch.radiowaves.left.and.right").font(.title3)
                }
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(sport?.displayName ?? "Receiving…").font(.body.weight(.semibold)).fontDesign(.rounded)
                if item.summary?.isTrimmed == true {
                    Text("Trimmed").font(.caption).foregroundStyle(.secondary)
                } else if item.summary?.trimUnavailable == true {
                    Text("Trim unavailable").font(.caption).foregroundStyle(.secondary)
                }
                if let startedAt = item.entry.startedAt {
                    Text(startedAt, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsRoute, let route = item.summary?.historyRoute {
                HistoryRouteThumbnail(route: route)
            }
            if let summary = item.summary {
                let display = UserSettings.display(for: summary.sport)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(display.distance(summary.metrics.distance))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .fontDesign(.rounded)
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

private struct HistoryRouteThumbnail: View {
    let route: HistoryRoute

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) - 10
            for span in route.spans {
                let points = span.map { point in
                    CGPoint(x: size.width / 2 + point.x * scale, y: size.height / 2 + point.y * scale)
                }
                if points.count == 1, let point = points.first {
                    let dot = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
                } else {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(
                        path, with: .color(.accentColor),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: 42, height: 36)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
