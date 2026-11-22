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
                    .cardRow()
                    if !shown.isEmpty {
                        HistorySummaryCard(items: shown, display: display)
                            .cardRow()
                    }
                }
                if shown.isEmpty {
                    emptyState
                }
                ForEach(months(in: shown), id: \.title) { month in
                    Section {
                        ForEach(month.items) { item in
                            NavigationLink(value: item) { SessionCard(item: item) }
                                .navigationLinkIndicatorVisibility(.hidden)
                                .accessibilityIdentifier("session.row")
                                .cardRow()
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
            .listSectionSpacing(8)
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
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Menu {
                Picker("Sport", selection: $sport) {
                    Text("All Sports").tag(nil as Sport?)
                    ForEach(Sport.allCases, id: \.self) { sport in
                        Text(sport.displayName).tag(Optional(sport))
                    }
                }
            } label: {
                FilterPill(title: sport?.displayName ?? "All Sports", isActive: sport != nil)
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
                FilterPill(title: dates.title, isActive: dates != .all)
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
        // Wraps between metrics at large text sizes, never between a value and its unit.
        Text(Self.line(items: items, display: display))
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(Color.secondary)
    }

    /// "3 sessions · 24.2 km · 1 h 46 min", plus any sessions still being analyzed.
    static func line(items: [SessionLibrary.Item], display: LiveDisplay) -> String {
        let totals = SessionLibrary.totals(items)
        let pending = items.count - totals.count
        var parts = ["\(items.count) \(items.count == 1 ? "session" : "sessions")"]
        if totals.count > 0 {
            parts += [display.distance(totals.distance), Formatting.duration(totals.movingTime)]
        }
        if pending > 0 { parts.append("\(pending) awaiting metrics") }
        return Formatting.metricLine(parts)
    }
}

/// The totals for the current filters: distance, moving time, sessions and the fastest
/// 10 s. VoiceOver reads it as one line, the same as each month's totals.
private struct HistorySummaryCard: View {
    let items: [SessionLibrary.Item]
    let display: LiveDisplay
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let summaries = items.compactMap(\.summary)
        let totals = SessionLibrary.totals(items)
        let fastest = summaries.compactMap(\.metrics.maxSpeed10s).max()
        let days = Set(summaries.map { calendar.startOfDay(for: $0.startedAt) }).count
        let pending = items.count - totals.count
        VStack(alignment: .leading, spacing: 0) {
            let distance = MetricValue(
                title: "Distance", value: display.distance(totals.distance), color: Theme.Metric.distance)
            let moving = MetricValue(
                title: "Moving time", value: Formatting.duration(totals.movingTime), color: Theme.Metric.time)
            let speed = MetricValue(
                title: "Fastest 10 s", value: display.speed(fastest), color: Theme.Metric.speed, size: .medium)
            let sessions = MetricValue(title: "Sessions", value: "\(items.count)", size: .medium)
            Group {
                // One column at accessibility sizes, so no caption is cut short.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        distance
                        moving
                        speed
                        sessions
                    }
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                        GridRow {
                            distance
                            moving
                        }
                        GridRow {
                            speed
                            sessions
                        }
                    }
                }
            }
            .padding(16)
            Divider().padding(.leading, 16)
            Text(footer(days: days, pending: pending))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryTotals.line(items: items, display: display))
        .accessibilityValue(fastest.map { "fastest 10 seconds \(display.speed($0))" } ?? "")
        .accessibilityIdentifier("history.totals")
    }

    private func footer(days: Int, pending: Int) -> String {
        var parts = ["On \(days) \(days == 1 ? "day" : "days")"]
        if pending > 0 { parts.append("\(pending) awaiting metrics") }
        return Formatting.metricLine(parts)
    }
}

/// A History filter as a capsule; tinted while it narrows the list.
private struct FilterPill: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold)).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        // System background on the accent: white on petrol, black on the dark-mode bright petrol.
        .foregroundStyle(isActive ? Color(.systemBackground) : Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
            in: .capsule
        )
        .contentShape(.capsule)
    }
}

extension View {
    /// A list row that draws its own card: no row background, separator or insets.
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
