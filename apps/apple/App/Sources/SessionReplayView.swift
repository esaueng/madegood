import Charts
import MapKit
import SwiftUI
import UIKit
import WaterKit

struct SessionReplayView: View {
    let data: Data
    let display: LiveDisplay
    /// Seconds on the displayed timeline.
    @Binding var elapsed: Double?
    @Binding var isPlaying: Bool
    var highlight: Highlight?
    var allowsPlayback = true
    var onSeek: (Double) -> Void = { _ in }

    struct Highlight {
        let title: String
        let range: ClosedRange<Double>
        let isTrim: Bool
        let route: [[CLLocationCoordinate2D]]
        let speedCurve: [(elapsed: Double, speed: Double)]

        init(title: String, range: ClosedRange<Double>, data: Data, showsSpeedWindow: Bool) {
            self.title = title
            self.range = range
            isTrim = false
            route = data.route(in: range)
            speedCurve = showsSpeedWindow ? data.timeline.speedCurve(in: range) : []
        }

        init(keptRange: ClosedRange<Double>, preview: Data?) {
            title = "Kept"
            range = keptRange
            isTrim = true
            speedCurve = []
            route = preview.map { $0.route(in: $0.timeline.start...$0.timeline.duration) } ?? []
        }

        var label: String {
            "\(title) · \(Self.time(range.lowerBound)) to \(Self.time(range.upperBound))"
        }

        static func time(_ seconds: Double) -> String {
            let milliseconds = (abs(seconds) * 1_000).rounded() / 1_000
            let whole = milliseconds.rounded(.down)
            let fraction = Int(((milliseconds - whole) * 1_000).rounded())
            return (seconds < 0 ? "−" : "") + Formatting.elapsed(whole)
                + (fraction == 0 ? "" : String(format: ".%03d", fraction))
        }
    }

    private var selection: SessionReplayTimeline.Selection {
        let speedWindow = highlight.flatMap { $0.speedCurve.isEmpty ? nil : $0.range }
        return data.timeline.selection(
            at: elapsed ?? data.timeline.points.first?.elapsed ?? 0, speedWindow: speedWindow)
    }

    var body: some View {
        let selected = selection
        let time =
            (highlight != nil && !isPlaying) || selected.elapsed < 0
            ? Highlight.time(selected.elapsed) : Formatting.elapsed(selected.elapsed)
        Section {
            SessionReplayMap(data: data, selection: selected, time: time, highlight: highlight, select: seek)
                .frame(height: 220)
                .listRowInsets(EdgeInsets())

            if let highlight {
                Text(highlight.label)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .accessibilityIdentifier("replay.range")
            }

            if let range = data.speedRange, highlight?.isTrim != true, range.upperBound > range.lowerBound {
                HStack(spacing: 8) {
                    Text(display.speed(range.lowerBound))
                    Capsule()
                        .fill(LinearGradient(colors: Theme.speedScale, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Text(display.speed(range.upperBound))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("map.legend")
            }

            let speed = display.speed(selected.speed)
            let distance = display.distance(selected.routeDistance)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    StatTile(title: "Elapsed", value: time)
                    StatTile(title: "GPS speed", value: speed)
                    StatTile(title: "Route distance", value: distance)
                }
                VStack(alignment: .leading, spacing: 8) {
                    StatTile(title: "Elapsed", value: time)
                    StatTile(title: "GPS speed", value: speed)
                    StatTile(title: "Route distance", value: distance)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if data.timeline.duration > data.timeline.start {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speed (\(display.speed.symbol))")
                        .font(.subheadline.weight(.medium))
                    if data.speeds.isEmpty {
                        Text("No GPS speed recorded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if allowsPlayback {
                        Button {
                            if !isPlaying, selected.elapsed >= data.timeline.duration { elapsed = data.timeline.start }
                            isPlaying.toggle()
                        } label: {
                            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("replay.playPause")
                    }
                    chart(selected)
                        .frame(height: 140)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Session replay")
                        .accessibilityValue(
                            "\(time) elapsed, GPS speed \(selected.speed == nil ? "unavailable" : speed), route distance \(distance)"
                        )
                        .accessibilityAdjustableAction { direction in
                            let step = max(1, ((data.timeline.duration - data.timeline.start) / 100).rounded())
                            switch direction {
                            case .increment:
                                seek(selected.elapsed + step)
                            case .decrement:
                                seek(selected.elapsed - step)
                            @unknown default: break
                            }
                        }
                        .accessibilityIdentifier("chart.speed")
                }
            }
        } footer: {
            Text("Routes and charts are not for navigation.")
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            let clock = ContinuousClock()
            let startedAt = clock.now
            let start = selection.elapsed
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard !Task.isCancelled, isPlaying else { return }
                let delta = startedAt.duration(to: clock.now).components
                let next = min(data.timeline.duration, start + Double(delta.seconds) + Double(delta.attoseconds) / 1e18)
                elapsed = next
                if next >= data.timeline.duration {
                    isPlaying = false
                    return
                }
            }
        }
        .onDisappear { isPlaying = false }
    }

    private func seek(_ time: Double) {
        isPlaying = false
        let time = data.timeline.selection(at: time).elapsed
        elapsed = time
        onSeek(time)
    }

    private func chart(_ selected: SessionReplayTimeline.Selection) -> some View {
        Chart {
            if let highlight {
                RectangleMark(
                    xStart: .value("Start", highlight.range.lowerBound / 60),
                    xEnd: .value("End", highlight.range.upperBound / 60)
                )
                .foregroundStyle(Color.accentColor.opacity(0.2))
                let boundaries =
                    highlight.range.lowerBound == highlight.range.upperBound
                    ? [highlight.range.lowerBound] : [highlight.range.lowerBound, highlight.range.upperBound]
                ForEach(boundaries, id: \.self) { boundary in
                    RuleMark(x: .value("Boundary", boundary / 60))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            LinePlot(
                data.speeds, x: .value("Minutes", \.minutes), y: .value("Speed", \.value),
                series: .value("Segment", \.segment)
            )
            .foregroundStyle(Color.accentColor.opacity(highlight?.isTrim == true ? 0.65 : 1))
            ForEach(data.isolatedSpeeds, id: \.segment) { point in
                PointMark(x: .value("Minutes", point.minutes), y: .value("Speed", point.value))
                    .foregroundStyle(Color.accentColor)
            }
            if let highlight {
                ForEach(highlight.speedCurve.indices, id: \.self) { index in
                    let sample = highlight.speedCurve[index]
                    LineMark(
                        x: .value("Minutes", sample.elapsed / 60),
                        y: .value("Speed", display.speed.fromSI(sample.speed)),
                        series: .value("Series", "Selected speed window")
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            RuleMark(x: .value("Selected time", selected.elapsed / 60))
                .foregroundStyle(Color.primary.opacity(0.65))
            if let speed = selected.speed {
                PointMark(
                    x: .value("Minutes", selected.elapsed / 60),
                    y: .value("Speed", display.speed.fromSI(speed))
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(55)
            }
        }
        .chartXScale(domain: (data.timeline.start / 60)...(data.timeline.duration / 60))
        .chartXAxisLabel("min")
        .chartYAxis(data.speeds.isEmpty ? .hidden : .automatic)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { point in
                            scrub(at: point.x, width: plot.width, proxy: proxy)
                        }
                        .gesture(ReplayScrubGesture { x in scrub(at: x, width: plot.width, proxy: proxy) })
                        .frame(width: plot.width, height: plot.height)
                        .position(x: plot.midX, y: plot.midY)
                }
            }
        }
    }

    private func scrub(at x: Double, width: Double, proxy: ChartProxy) {
        if let minutes = proxy.value(atX: min(max(0, x), width), as: Double.self) {
            seek(minutes * 60)
        }
    }
}

/// Decline vertical pans before recognition so the detail list can scroll from the plot.
private struct ReplayScrubGesture: UIGestureRecognizerRepresentable {
    let scrub: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
            scrub(context.converter.localLocation.x)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let movement = pan.translation(in: pan.view)
            return abs(movement.x) > abs(movement.y)
        }
    }
}

extension SessionReplayView {
    /// Build static chart and map geometry once for each recording load.
    struct Data: Sendable {
        struct SpeedPoint: Sendable {
            var minutes: Double
            var value: Double
            var segment: Int
        }

        struct RouteLine: Sendable {
            var level: Int?
            var coordinates: [CLLocationCoordinate2D]
        }

        let timeline: SessionReplayTimeline
        let speeds: [SpeedPoint]
        let isolatedSpeeds: [SpeedPoint]
        let speedRange: ClosedRange<Double>?
        let coordinates: [CLLocationCoordinate2D]
        let lines: [RouteLine]
        let isolatedFixes: [Int]
        let mapRect: MKMapRect?

        init(timeline: SessionReplayTimeline, speedUnit: SpeedUnit) {
            self.timeline = timeline
            let points = timeline.points
            let coordinates = points.map { CLLocationCoordinate2D($0.position) }
            self.coordinates = coordinates
            let speedRange = Self.range(points)
            self.speedRange = speedRange

            var speeds: [SpeedPoint] = []
            var isolatedSpeeds: [SpeedPoint] = []
            var lines: [RouteLine] = []
            var isolatedFixes: [Int] = []
            var speedSegment = 0
            var speedRunCount = 0

            for (index, point) in points.enumerated() {
                let joinsPrevious = index > 0 && points[index - 1].routeSegment == point.routeSegment
                let joinsNext = index + 1 < points.count && points[index + 1].routeSegment == point.routeSegment

                if !joinsPrevious && !joinsNext { isolatedFixes.append(index) }
                if joinsPrevious {
                    let level = Self.level(point.speed, range: speedRange)
                    if index > 1, points[index - 2].routeSegment == point.routeSegment, lines.last?.level == level {
                        lines[lines.count - 1].coordinates.append(coordinates[index])
                    } else {
                        lines.append(
                            RouteLine(level: level, coordinates: [coordinates[index - 1], coordinates[index]]))
                    }
                }

                if !joinsPrevious || point.speed == nil {
                    if speedRunCount == 1, let last = speeds.last { isolatedSpeeds.append(last) }
                    speedRunCount = 0
                    speedSegment += 1
                }
                if let speed = point.speed {
                    speeds.append(
                        SpeedPoint(minutes: point.elapsed / 60, value: speedUnit.fromSI(speed), segment: speedSegment))
                    speedRunCount += 1
                }
            }

            if speedRunCount == 1, let last = speeds.last { isolatedSpeeds.append(last) }
            self.speeds = speeds
            self.isolatedSpeeds = isolatedSpeeds
            self.lines = lines
            self.isolatedFixes = isolatedFixes
            mapRect = Self.fittedRect(coordinates)
        }

        /// Clip each continuous route segment at the precise time bounds.
        func route(in range: ClosedRange<Double>) -> [[CLLocationCoordinate2D]] {
            let points = timeline.points
            var fragments: [[CLLocationCoordinate2D]] = []
            var start = 0
            while start < points.count, points[start].elapsed <= range.upperBound {
                var end = start
                while end + 1 < points.count, points[end + 1].routeSegment == points[start].routeSegment {
                    end += 1
                }
                let lower = max(range.lowerBound, points[start].elapsed)
                let upper = min(range.upperBound, points[end].elapsed)
                if lower <= upper, let first = timeline.selection(at: lower).position {
                    var fragment = [CLLocationCoordinate2D(first)]
                    for point in points[start...end] where point.elapsed > lower && point.elapsed < upper {
                        fragment.append(CLLocationCoordinate2D(point.position))
                    }
                    if upper > lower, let last = timeline.selection(at: upper).position {
                        fragment.append(CLLocationCoordinate2D(last))
                    }
                    fragments.append(fragment)
                }
                start = end + 1
            }
            return fragments
        }

        /// The 5th and 95th percentiles keep one extreme speed from washing out the colors.
        private static func range(_ points: [SessionReplayTimeline.Point]) -> ClosedRange<Double>? {
            let speeds = points.compactMap(\.speed).sorted()
            guard speeds.count > 1 else { return nil }
            let span = Double(speeds.count - 1)
            return speeds[Int(span * 0.05)]...speeds[Int(span * 0.95)]
        }

        private static func level(_ speed: Double?, range: ClosedRange<Double>?) -> Int? {
            guard let speed else { return nil }
            let levels = Theme.speedScale.count
            guard let range, range.upperBound > range.lowerBound else { return levels / 2 }
            let fraction = (speed - range.lowerBound) / (range.upperBound - range.lowerBound)
            return Int(min(max(0, fraction * Double(levels)), Double(levels - 1)))
        }

        private static func fittedRect(_ coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
            guard let first = coordinates.first else { return nil }
            var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize())
            for coordinate in coordinates.dropFirst() {
                rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize()))
            }
            let margin = max(rect.size.width, rect.size.height) * 0.25 + 200
            return rect.insetBy(dx: -margin, dy: -margin)
        }
    }
}

private struct SessionReplayMap: View {
    let data: SessionReplayView.Data
    let selection: SessionReplayTimeline.Selection
    let time: String
    let highlight: SessionReplayView.Highlight?
    let select: (Double) -> Void

    var body: some View {
        MapReader { proxy in
            Map(initialPosition: data.mapRect.map { .rect($0) } ?? .automatic) {
                ForEach(data.lines.indices, id: \.self) { index in
                    let line = data.lines[index]
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(
                            highlight?.isTrim == true
                                ? Color.gray.opacity(0.65) : line.level.map { Theme.speedScale[$0] } ?? .gray,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                }
                ForEach(data.isolatedFixes, id: \.self) { index in
                    Annotation("", coordinate: data.coordinates[index]) {
                        Circle().fill(.gray).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                if let highlight {
                    ForEach(highlight.route.indices, id: \.self) { index in
                        let route = highlight.route[index]
                        if route.count > 1 {
                            MapPolyline(coordinates: route)
                                .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            MapPolyline(coordinates: route)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        } else if let coordinate = route.first {
                            Annotation("", coordinate: coordinate, anchor: .center) {
                                Circle().fill(Color.accentColor).strokeBorder(.white, lineWidth: 2)
                                    .frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                if let position = selection.position {
                    Annotation("", coordinate: CLLocationCoordinate2D(position), anchor: .center) {
                        Circle()
                            .fill(Color.accentColor)
                            .strokeBorder(.white, lineWidth: 2)
                            .frame(width: 18, height: 18)
                            .shadow(radius: 2)
                            .accessibilityLabel("Replay position")
                            .accessibilityValue(time)
                            .accessibilityIdentifier("replay.position")
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    if let time = time(at: tap.location, on: proxy) { select(time) }
                })
        }
        .accessibilityIdentifier("replay.map")
        .overlay(alignment: .top) {
            if selection.position == nil {
                Text("No GPS fix at this time")
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Project the visible route into screen space. At crossings, prefer the pass
    /// nearest the current cursor among hits that are equally close to the tap.
    private func time(at location: CGPoint, on proxy: MapProxy) -> Double? {
        let points = data.timeline.points
        var hits: [(distance: Double, elapsed: Double)] = []
        var previous: CGPoint?
        for (index, coordinate) in data.coordinates.enumerated() {
            let projected = proxy.convert(coordinate, to: .local)
            defer { previous = projected }
            guard let projected else { continue }
            let point = points[index]
            var hit = projected
            var elapsed = point.elapsed
            if let previous, index > 0, points[index - 1].routeSegment == point.routeSegment {
                let startTime = points[index - 1].elapsed
                let vector = CGPoint(x: projected.x - previous.x, y: projected.y - previous.y)
                let lengthSquared = vector.x * vector.x + vector.y * vector.y
                let along: Double
                if lengthSquared > 0 {
                    along =
                        ((location.x - previous.x) * vector.x + (location.y - previous.y) * vector.y) / lengthSquared
                } else {
                    along = (selection.elapsed - startTime) / (point.elapsed - startTime)
                }
                let fraction = min(1, max(0, along))
                hit = CGPoint(x: previous.x + fraction * vector.x, y: previous.y + fraction * vector.y)
                elapsed = startTime + fraction * (point.elapsed - startTime)
            }
            let distance = hypot(hit.x - location.x, hit.y - location.y)
            if distance <= 22 { hits.append((distance, elapsed)) }
        }
        guard let closest = hits.map(\.distance).min() else { return nil }
        return hits.lazy.filter { $0.distance <= closest + 2 }.min {
            abs($0.elapsed - selection.elapsed) < abs($1.elapsed - selection.elapsed)
        }?.elapsed
    }
}

private extension CLLocationCoordinate2D {
    init(_ position: SessionReplayTimeline.Position) {
        self.init(latitude: position.latitude, longitude: position.longitude)
    }
}
