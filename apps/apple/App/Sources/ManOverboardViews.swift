import MapKit
import SwiftUI
import UIKit
import WaterKit

/// The way back to the man-overboard mark (docs/PLAN.md §5) on the iPhone: distance and
/// bearing, an arrow, and the mark on a map. Guidance uses the same rules as the watch
/// (`ManOverboard`): it needs a position from the last 10 s, and the arrow is relative to
/// the course while moving at 0.5 m/s or more, and points from true north otherwise.
struct ManOverboardScreen: View {
    let manOverboard: ManOverboard
    let sport: Sport
    /// The session's track, when there is one, drawn under the mark.
    var points: [SessionRecorder.TrackPoint] = []
    @State private var confirmClear = false
    @ScaledMetric(relativeTo: .largeTitle) private var arrowSize = 120.0

    var body: some View {
        let display = UserSettings.display(for: sport)
        ScrollView {
            VStack(spacing: 20) {
                Label("Man overboard", systemImage: "figure.wave")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let issue = manOverboard.locationIssue {
                    LocationIssueBanner(issue: issue)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let _ = context.date  // re-evaluate freshness every second
                    guidanceView(display: display)
                }
                if let mark = manOverboard.mark {
                    ManOverboardMap(mark: mark, others: manOverboard.otherMarks, points: points)
                        .frame(height: 260)
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityIdentifier("mob.map")
                }
                if !manOverboard.otherMarks.isEmpty {
                    otherMarks(display: display)
                }
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    // With only a press waiting, clearing cancels it.
                    Label(manOverboard.mark == nil ? "Cancel press" : "Clear mark", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("mob.clear")
                .confirmationDialog(
                    "Clear the man-overboard mark?", isPresented: $confirmClear, titleVisibility: .visible
                ) {
                    Button("Clear mark", role: .destructive) { manOverboard.clear() }
                        .accessibilityIdentifier("mob.confirmClear")
                } message: {
                    Text(
                        manOverboard.otherMarks.isEmpty
                            ? "The way back to it will no longer be shown."
                            : "The way back to it will no longer be shown. The next mark becomes the target.")
                }
            }
            .padding()
        }
        .accessibilityIdentifier("mob.screen")
    }

    @ViewBuilder
    private func guidanceView(display: LiveDisplay) -> some View {
        VStack(spacing: 8) {
            // How far to trust the mark comes first: an old or late fix is not where
            // MOB was pressed.
            if let mark = manOverboard.mark, let note = ManOverboardNotes.markQuality(mark) {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("mob.markQuality")
            }
            if let guidance = manOverboard.guidance() {
                Image(systemName: "location.north.fill")
                    .font(.system(size: min(arrowSize, 180)))
                    .foregroundStyle(.red)
                    .rotationEffect(.degrees(guidance.arrow))
                    .frame(height: min(arrowSize, 180) * 1.2)
                    .accessibilityLabel(arrowLabel(guidance))
                    .accessibilityIdentifier("mob.arrow")
                Text(display.distance(guidance.distance))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                    .accessibilityLabel("Distance \(display.distance(guidance.distance))")
                    .accessibilityIdentifier("mob.distance")
                Text("Bearing \(LiveDisplay.course(guidance.bearing)) true")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .accessibilityIdentifier("mob.bearing")
                Text(guidance.isCourseRelative ? "Arrow relative to your course" : "Arrow points from north")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mob.arrowMode")
            } else {
                Image(systemName: "location.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(
                    ManOverboardNotes.waiting(
                        positionAge: manOverboard.positionAge(), hasMark: manOverboard.mark != nil)
                )
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("mob.waiting")
                Text("The way back shows once there is a position from the last 10 seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let mark = manOverboard.mark {
                // Which device's mark the arrow points to.
                Text("\(ManOverboardNotes.origin(mark)) \(mark.markedAt, style: .relative) ago")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("mob.origin")
            }
            if let pressed = manOverboard.awaitingFixSince {
                // A press on this device waiting for a position is never dropped, even when
                // a watch mark arrives meanwhile: it becomes its own mark at its first fix.
                Text("Pressed here \(pressed, style: .relative) ago; marks the first position")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("mob.pending")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Marks other than the target, with distance and a way to steer to each.
    private func otherMarks(display: LiveDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Other marks")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(manOverboard.otherMarks, id: \.identity) { other in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ManOverboardNotes.origin(other)).font(.subheadline.weight(.semibold))
                        if let guidance = manOverboard.guidance(to: other) {
                            Text("\(display.distance(guidance.distance)) · \(LiveDisplay.course(guidance.bearing)) true")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Steer to this") { manOverboard.target(other.identity) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Steer to this mark")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mob.other")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    private func arrowLabel(_ guidance: ManOverboard.Guidance) -> String {
        guard guidance.isCourseRelative else {
            return "Mark bears \(Int(guidance.bearing.rounded()) % 360) degrees true"
        }
        let relative =
            (guidance.arrow.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360)
            - 180
        let degrees = Int(abs(relative).rounded())
        if degrees == 0 { return "Mark dead ahead" }
        return "Mark \(degrees) degrees to \(relative < 0 ? "port" : "starboard")"
    }
}

/// The mark on top of a live session: distance and bearing at a glance. Tapping it opens
/// the full screen.
struct ManOverboardCard: View {
    let manOverboard: ManOverboard
    let sport: Sport
    let open: () -> Void

    var body: some View {
        let display = UserSettings.display(for: sport)
        Button(action: open) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let _ = context.date
                let guidance = manOverboard.guidance()
                HStack(spacing: 12) {
                    Image(systemName: guidance == nil ? "location.slash" : "location.north.fill")
                        .font(.title)
                        .rotationEffect(.degrees(guidance?.arrow ?? 0))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Man overboard").font(.headline)
                        if let guidance {
                            Text(
                                "\(display.distance(guidance.distance)) · \(LiveDisplay.course(guidance.bearing)) true"
                            )
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        } else {
                            Text(
                                ManOverboardNotes.waiting(
                                    positionAge: manOverboard.positionAge(), hasMark: manOverboard.mark != nil)
                            )
                            .font(.subheadline)
                        }
                        if let issue = manOverboard.locationIssue, guidance == nil {
                            Text(ManOverboardNotes.locationIssue(issue)).font(.footnote.weight(.semibold))
                        }
                        if let mark = manOverboard.mark, let note = ManOverboardNotes.markQuality(mark) {
                            Text(note).font(.footnote.weight(.semibold))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.white)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red, in: .rect(cornerRadius: 12))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the way back to the mark")
        .accessibilityIdentifier("mob.card")
    }
}

/// The man-overboard control: touch and hold to mark, so a stray tap cannot set it, but
/// it takes well under a second in an emergency. VoiceOver's activate marks at once.
/// With a mark set, a tap shows the way back instead of moving the mark.
struct ManOverboardButton: View {
    let hasMark: Bool
    let mark: () -> Void
    let show: () -> Void
    static let holdDuration = 0.6
    @State private var holding = false
    @State private var hint = false

    var body: some View {
        if hasMark {
            Button(action: show) {
                label(title: "MOB", systemImage: "figure.wave")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Man overboard")
            .accessibilityHint("Shows the way back to the mark")
            .accessibilityIdentifier("control.mob")
        } else {
            label(title: hint ? "Hold" : "MOB", systemImage: "figure.wave")
                .overlay(alignment: .leading) {
                    // Fills while held, so the press visibly counts toward marking.
                    GeometryReader { proxy in
                        Color.white.opacity(0.3)
                            .frame(width: holding ? proxy.size.width : 0)
                    }
                    .clipShape(.capsule)
                    .allowsHitTesting(false)
                }
                .contentShape(.capsule)
                .onLongPressGesture(minimumDuration: Self.holdDuration) {
                    holding = false
                    mark()
                } onPressingChanged: { pressing in
                    withAnimation(pressing ? .linear(duration: Self.holdDuration) : .snappy) { holding = pressing }
                    if !pressing { hint = true }
                }
                .task(id: hint) {
                    guard hint else { return }
                    try? await Task.sleep(for: .seconds(2))
                    hint = false
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Man overboard")
                .accessibilityHint("Touch and hold to mark this position")
                .accessibilityAction { mark() }
                .accessibilityIdentifier("control.mob")
        }
    }

    private func label(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            // A List (the start screen) would otherwise show the icon alone.
            .labelStyle(.titleAndIcon)
            .font(.title3.weight(.heavy))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .background(.red, in: .capsule)
    }
}

/// The mark, the session's track and the current position. Display only, like the live
/// map: an interactive map in the scrolling screen caught the swipes meant to scroll it.
struct ManOverboardMap: View {
    let mark: ManOverboard.Mark
    /// Marks other than the target, shown in orange.
    var others: [ManOverboard.Mark] = []
    var points: [SessionRecorder.TrackPoint] = []

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let markCoordinate = CLLocationCoordinate2D(latitude: mark.latitude, longitude: mark.longitude)
        Map(initialPosition: .automatic, interactionModes: []) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates).stroke(Color.accentColor, lineWidth: 4)
            }
            ForEach(others, id: \.identity) { other in
                Marker(
                    "MOB", systemImage: "figure.wave",
                    coordinate: CLLocationCoordinate2D(latitude: other.latitude, longitude: other.longitude)
                )
                .tint(.orange)
            }
            Marker("MOB", systemImage: "figure.wave", coordinate: markCoordinate).tint(.red)
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottomLeading) { NotForNavigationLabel() }
    }
}

/// Required on every map that shows a mark or a route (AGENTS.md, "Labels").
struct NotForNavigationLabel: View {
    var body: some View {
        Text("Not for navigation")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: .capsule)
            .padding(8)
            .accessibilityIdentifier("label.notForNavigation")
    }
}

/// The MOB control wired to the session controller, for every screen that shows a
/// session, a countdown or the start of one. Marking works with or without a local
/// recording (`SessionController.markManOverboard`).
struct PhoneManOverboardControl: View {
    let show: () -> Void
    @State private var manOverboard = ManOverboard.shared

    var body: some View {
        ManOverboardButton(
            hasMark: manOverboard.isActive,
            mark: {
                SessionController.shared.markManOverboard()
                show()
            },
            show: show)
    }
}

/// Location is denied, restricted, approximate or unavailable: said at once, with a way
/// to fix it in Settings where the user can.
struct LocationIssueBanner: View {
    let issue: ManOverboard.LocationIssue
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ManOverboardNotes.locationIssue(issue), systemImage: "location.slash.fill")
                .font(.headline)
                .foregroundStyle(.black)
                .accessibilityIdentifier("mob.locationIssue")
            if issue == .denied || issue == .reducedAccuracy, let url = URL(string: UIApplication.openSettingsURLString) {
                Button {
                    openURL(url)
                } label: {
                    Text("Open Settings").font(.headline).foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .accessibilityIdentifier("mob.openSettings")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange, in: .rect(cornerRadius: 12))
    }
}
