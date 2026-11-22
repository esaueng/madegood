import SwiftUI
import WaterKit

/// One session in History: the route over a water tint, the sport and when, then the
/// headline numbers in the metric colors.
struct SessionCard: View {
    let item: SessionLibrary.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let route = item.summary?.historyRoute {
                HistoryRouteBanner(route: route)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SessionTitle(item: item)
                    Spacer(minLength: 0)
                    if item.summary == nil, item.entry.meta != nil {
                        ProgressView()
                    }
                }
                if let summary = item.summary {
                    SessionCardMetrics(summary: summary)
                }
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .contentShape(.rect(cornerRadius: 20, style: .continuous))
    }
}

/// Distance, moving time, average and the fastest 10 s, in one row while they fit.
private struct SessionCardMetrics: View {
    let summary: SessionLibrary.Summary

    var body: some View {
        let display = UserSettings.display(for: summary.sport)
        let metrics = summary.metrics
        let distance = MetricValue(
            title: "Distance", value: display.distance(metrics.distance), color: Theme.Metric.distance, size: .medium)
        let moving = MetricValue(
            title: "Moving", value: Formatting.elapsed(metrics.movingTime), color: Theme.Metric.time, size: .medium)
        let average = MetricValue(
            title: "Average", value: display.speed(metrics.averageSpeed), color: Theme.Metric.speed, size: .medium)
        let fastest = MetricValue(
            title: "Max 10 s", value: display.speed(metrics.maxSpeed10s), color: Theme.Metric.speed, size: .medium)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                distance
                moving
                average
                fastest
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    distance
                    moving
                }
                GridRow {
                    average
                    fastest
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                distance
                moving
                average
                fastest
            }
        }
    }
}

/// The sport badge, its name, any trim, and the start time. Shared by the History cards
/// and the start screen's recent sessions.
private struct SessionTitle: View {
    let item: SessionLibrary.Item

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
            .overlay(alignment: .bottomTrailing) {
                SessionSyncBadge(sessionID: item.entry.meta?.sessionId).offset(x: 6, y: 4)
            }
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
        }
    }
}

/// One session in a compact list (the start screen's Recent): sport, when, distance and
/// moving time.
struct SessionRow: View {
    let item: SessionLibrary.Item

    var body: some View {
        HStack(spacing: 12) {
            SessionTitle(item: item)
            Spacer()
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

/// The route drawn from the recording itself over a soft water tint: no map tiles, no
/// network, no place names.
private struct HistoryRouteBanner: View {
    let route: HistoryRoute
    @ScaledMetric private var height: CGFloat = 96

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 14
            let scale = min(size.width, size.height) - inset * 2
            let style = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            for span in route.spans {
                let points = span.map { point in
                    CGPoint(x: size.width / 2 + point.x * scale, y: size.height / 2 + point.y * scale)
                }
                if points.count == 1, let point = points.first {
                    let dot = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
                } else {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(.accentColor), style: style)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(height, 140))
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)],
                startPoint: .top, endPoint: .bottom)
        )
        .accessibilityHidden(true)
    }
}
