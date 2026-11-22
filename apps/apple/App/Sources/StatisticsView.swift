import Charts
import SwiftUI
import WaterKit

/// Distance, moving time and the fastest 10 s per week, month or year, from History's
/// analyzed sessions. Opened from History's toolbar.
struct StatisticsView: View {
    let library: SessionLibrary
    @State private var period = Statistics.Period.month
    @State private var sport: Sport?
    @Environment(\.calendar) private var calendar

    var body: some View {
        let items = library.items.filter { sport == nil || $0.entry.meta?.sport == sport }
        let samples = items.compactMap { item -> Statistics.Sample? in
            guard let summary = item.summary, let startedAt = item.entry.startedAt else { return nil }
            return Statistics.Sample(
                startedAt: startedAt, distance: summary.metrics.distance, movingTime: summary.metrics.movingTime,
                maxSpeed10s: summary.metrics.maxSpeed10s)
        }
        let pending = items.filter { $0.summary == nil && $0.entry.meta != nil }.count
        // Mixed sports use History's unit (the kayak preference), as History's totals do.
        let display = UserSettings.display(for: sport ?? .kayak)
        let buckets = Statistics.buckets(samples, period: period, now: .now, calendar: calendar)
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Period", selection: $period) {
                        ForEach(Statistics.Period.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("statistics.period")
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
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("statistics.sportFilter")
                    if pending > 0 {
                        // As History says: a recording that can't be analyzed also waits here.
                        Text("\(pending) awaiting metrics, not counted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .cardRow()
            }
            Section {
                StatisticsChart(
                    title: "Distance", color: Theme.Metric.distance, period: period, buckets: buckets,
                    unit: display.distance.symbol, value: { display.distance.fromSI($0.distance) },
                    text: { display.distance($0.distance) }
                )
                .cardRow()
                StatisticsChart(
                    title: "Moving time", color: Theme.Metric.time, period: period, buckets: buckets,
                    unit: "h", value: { $0.movingTime / 3600 }, text: { Formatting.duration($0.movingTime) }
                )
                .cardRow()
                StatisticsChart(
                    title: "Fastest 10 s", color: Theme.Metric.speed, period: period, buckets: buckets,
                    unit: display.speed.symbol, total: false,
                    value: { $0.fastest10s.map(display.speed.fromSI) ?? 0 },
                    text: { display.speed($0.fastest10s) }
                )
                .cardRow()
            }
        }
        .listSectionSpacing(8)
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { library.reload() }
    }
}

/// One metric as bars, one per period. The unfinished current period is dimmed; a tap or
/// drag on the chart shows a period's value in the header.
private struct StatisticsChart: View {
    let title: String
    let color: Color
    let period: Statistics.Period
    let buckets: [Statistics.Bucket]
    let unit: String
    /// Whether the header shows the total over the periods (sums do; bests don't).
    var total = true
    let value: (Statistics.Bucket) -> Double
    let text: (Statistics.Bucket) -> String
    @State private var selection: Date?

    var body: some View {
        let selected = selection.flatMap { date in buckets.first { $0.start <= date && date < $0.end } }
        VStack(alignment: .leading, spacing: 10) {
            // Beside the title while it fits on two lines; under it, in full, when it doesn't.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer()
                    headlineText(selected)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    headlineText(selected)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Period", bucket.start, unit: period.component),
                    y: .value(title, value(bucket))
                )
                .foregroundStyle(color)
                .opacity(opacity(bucket, selected: selected))
                .cornerRadius(4)
                .accessibilityLabel(label(bucket))
                .accessibilityValue(bucket.sessions == 0 ? "No sessions" : text(bucket))
            }
            .chartXSelection(value: $selection)
            .chartXAxis {
                AxisMarks(values: .stride(by: period.component, count: period == .week ? 3 : 1)) { _ in
                    AxisValueLabel(format: axisFormat, centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartYAxisLabel(unit)
            .frame(height: 160)
            .accessibilityIdentifier("statistics.chart.\(title)")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .fontDesign(.rounded)
            .foregroundStyle(color)
    }

    private func headlineText(_ selected: Statistics.Bucket?) -> some View {
        Text(headline(selected))
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// The selected bar stands out; otherwise the unfinished current period is dimmed.
    private func opacity(_ bucket: Statistics.Bucket, selected: Statistics.Bucket?) -> Double {
        if let selected { return bucket.start == selected.start ? 1 : 0.35 }
        return bucket.isCurrent ? 0.5 : 1
    }

    private var axisFormat: Date.FormatStyle {
        switch period {
        case .week: .dateTime.day().month(.abbreviated)
        case .month: .dateTime.month(.narrow)
        case .year: .dateTime.year()
        }
    }

    private func label(_ bucket: Statistics.Bucket) -> String {
        switch period {
        case .week: "Week of \(bucket.start.formatted(.dateTime.day().month(.wide)))"
        case .month: bucket.start.formatted(.dateTime.month(.wide).year())
        case .year: bucket.start.formatted(.dateTime.year())
        }
    }

    /// The selected period's value, or the total and best over the periods shown.
    private func headline(_ selected: Statistics.Bucket?) -> String {
        if let selected {
            return "\(label(selected)) · \(selected.sessions == 0 ? "no sessions" : text(selected))"
        }
        let active = buckets.filter { $0.sessions > 0 }
        guard let best = active.max(by: { value($0) < value($1) }), let first = buckets.first,
            let last = buckets.last
        else { return "No sessions" }
        let bestText = "best \(text(best))"
        guard total else { return bestText }
        var sum = Statistics.Bucket(start: first.start, end: last.end)
        sum.sessions = active.reduce(0) { $0 + $1.sessions }
        sum.distance = active.reduce(0) { $0 + $1.distance }
        sum.movingTime = active.reduce(0) { $0 + $1.movingTime }
        return "total \(text(sum)) · \(bestText)"
    }
}
