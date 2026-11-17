import SwiftUI
import WidgetKit

/// Watch-face complications that open MadeGood (docs/PLAN.md §6 "Complication to start a
/// session"). They show the app's mark; tapping one launches the app at the sport list.
@main
struct MadeGoodComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.madegood.launch", provider: Provider()) { _ in
            ComplicationView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("MadeGood")
        .description("Start a session.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

private struct Provider: TimelineProvider {
    struct Entry: TimelineEntry {
        var date: Date
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Nothing changes over time, so one entry is enough.
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

private struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("MadeGood", systemImage: "water.waves")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                WaveMark().frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text("MadeGood").font(.headline)
                    Text("Start a session").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .accessoryCorner:
            WaveMark()
                .padding(4)
                .widgetLabel("MadeGood")
        default:
            WaveMark().padding(6)
        }
    }
}

/// The logo's twin-swell M (assets/icon.svg), simplified for small sizes.
private struct WaveMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h * 0.8))
            path.addCurve(
                to: CGPoint(x: w * 0.3, y: h * 0.2), control1: CGPoint(x: w * 0.12, y: h * 0.8),
                control2: CGPoint(x: w * 0.18, y: h * 0.2))
            path.addCurve(
                to: CGPoint(x: w * 0.52, y: h * 0.62), control1: CGPoint(x: w * 0.4, y: h * 0.2),
                control2: CGPoint(x: w * 0.48, y: h * 0.62))
            path.addCurve(
                to: CGPoint(x: w * 0.74, y: h * 0.3), control1: CGPoint(x: w * 0.56, y: h * 0.62),
                control2: CGPoint(x: w * 0.64, y: h * 0.3))
            path.addCurve(
                to: CGPoint(x: w, y: h * 0.8), control1: CGPoint(x: w * 0.86, y: h * 0.3),
                control2: CGPoint(x: w * 0.9, y: h * 0.8))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: max(2, w * 0.12), lineCap: .round))
        }
        .widgetAccentable()
        .accessibilityLabel("MadeGood")
    }
}
