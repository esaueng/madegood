import MapKit
import SwiftUI
import WaterKit

/// The anchor alarm screen: drop the anchor at the current position, pick a radius, then
/// watch the distance and bearing back to it. A map shows the circle; it is a picture of
/// the alarm, not for navigation.
struct AnchorAlarmView: View {
    @State private var watch = AnchorWatch.shared
    @State private var confirmRaise = false

    var body: some View {
        let alarm = watch.alarm
        List {
            Section {
                AnchorStatusHeader(alarm: alarm)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                if alarm.state.isAlarming {
                    Button {
                        watch.silence()
                    } label: {
                        Label("Silence for 1 min", systemImage: "bell.slash.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("anchor.silence")
                }
            }

            Section {
                AnchorMap(alarm: alarm, position: watch.position)
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Not for navigation.")
            }

            if alarm.isArmed {
                Section {
                    Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                        GridRow {
                            StatTile(
                                title: "To anchor", value: AnchorText.metres(alarm.distance),
                                identifier: "anchor.distance")
                            StatTile(
                                title: "Bearing to anchor", value: AnchorText.bearing(alarm.bearing),
                                identifier: "anchor.bearing")
                        }
                        GridRow {
                            StatTile(
                                title: "Max swing", value: AnchorText.metres(alarm.maxDistance),
                                identifier: "anchor.maxSwing")
                            StatTile(
                                title: "GPS accuracy", value: AnchorText.accuracy(alarm.accuracy),
                                identifier: "anchor.accuracy")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                radiusPicker
                if alarm.isArmed {
                    Button(role: .destructive) {
                        confirmRaise = true
                    } label: {
                        Label("Raise anchor", systemImage: "arrow.up.circle")
                    }
                    .accessibilityHint("Stops the anchor alarm")
                    .accessibilityIdentifier("anchor.raise")
                } else {
                    Button {
                        watch.setAnchorHere()
                    } label: {
                        Label("Drop anchor here", systemImage: "arrow.down.to.line")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!watch.canSetAnchor)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .accessibilityHint("Sets the anchor at your current position")
                    .accessibilityIdentifier("anchor.set")
                }
            } header: {
                Text("Alarm")
            } footer: {
                Text(
                    "Choose a radius that covers your rode plus the boat's length. The alarm sounds when the boat stays outside the circle for 10 s, and if GPS is lost for 2 minutes. It keeps watching in the background until you raise the anchor."
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Anchor Alarm")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { watch.screenAppeared() }
        .onDisappear { watch.screenDisappeared() }
        .confirmationDialog("Raise the anchor?", isPresented: $confirmRaise, titleVisibility: .visible) {
            Button("Raise anchor", role: .destructive) { watch.raise() }
                .accessibilityIdentifier("anchor.raise.confirm")
        } message: {
            Text("The alarm stops watching your position.")
        }
    }

    private var radiusPicker: some View {
        Picker(
            "Radius",
            selection: Binding(get: { watch.radius }, set: { watch.changeRadius($0) })
        ) {
            ForEach(radiusChoices, id: \.self) { radius in
                Text("\(Int(radius)) m").tag(radius)
            }
        }
        .accessibilityIdentifier("anchor.radius")
    }

    private var radiusChoices: [Double] {
        let choices = AnchorAlarm.radiusChoices
        return choices.contains(watch.radius) ? choices : (choices + [watch.radius]).sorted()
    }
}

/// The alarm state in words, large, colored by state.
private struct AnchorStatusHeader: View {
    let alarm: AnchorAlarm

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44)
                .symbolEffect(.pulse, isActive: alarm.state.isAlarming)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(alarm.state.isAlarming ? Theme.coral : .primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("anchor.status")
    }

    private var title: String {
        switch alarm.state {
        case .clear: "No anchor set"
        case .armed: "Anchor watch on"
        case .alarming(.dragging): "Anchor dragging"
        case .alarming(.gpsLost): "No GPS"
        }
    }

    private var detail: String {
        let radius = alarm.anchor.map { "\(Int($0.radius)) m circle" } ?? ""
        switch alarm.state {
        case .clear: return "Drop the anchor, then set it here."
        case .armed:
            if let distance = alarm.distance { return "\(AnchorText.metres(distance)) from anchor · \(radius)" }
            return "Waiting for GPS · \(radius)"
        case .alarming(.dragging): return "\(AnchorText.metres(alarm.distance)) from anchor, outside the \(radius)"
        case .alarming(.gpsLost): return "The position stopped updating. Check the boat."
        }
    }

    private var symbol: String {
        switch alarm.state {
        case .clear: "scope"
        case .armed: "checkmark.shield.fill"
        case .alarming(.dragging): "exclamationmark.triangle.fill"
        case .alarming(.gpsLost): "location.slash.fill"
        }
    }

    private var tint: Color {
        switch alarm.state {
        case .clear: .secondary
        case .armed: .accentColor
        case .alarming: Theme.coral
        }
    }
}

/// The anchor, its circle and the boat. Display only.
private struct AnchorMap: View {
    let alarm: AnchorAlarm
    let position: AnchorWatch.Position?

    var body: some View {
        let anchor = alarm.anchor.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let boat = position.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let center = anchor ?? boat ?? CLLocationCoordinate2D(latitude: DemoFeed.origin.lat, longitude: DemoFeed.origin.lon)
        let span = max(alarm.anchor?.radius ?? 40, alarm.distance ?? 0) * 3
        Map(
            position: .constant(.region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))),
            interactionModes: []
        ) {
            if let anchor, let radius = alarm.anchor?.radius {
                MapCircle(center: anchor, radius: radius)
                    .foregroundStyle((alarm.state.isAlarming ? Theme.coral : Color.accentColor).opacity(0.18))
                    .stroke(alarm.state.isAlarming ? Theme.coral : Color.accentColor, lineWidth: 2)
                Annotation("Anchor", coordinate: anchor) {
                    Image(systemName: "mappin")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Theme.teal, in: .circle)
                }
            }
            if let boat {
                Annotation("Boat", coordinate: boat) {
                    Circle()
                        .fill(alarm.state.isAlarming ? Theme.coral : Color.blue)
                        .stroke(.white, lineWidth: 2)
                        .frame(width: 14, height: 14)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .accessibilityHidden(true)
    }
}

/// A row that opens the anchor alarm, with its state: on the start screen and the
/// motorboat live page.
struct AnchorAlarmRow: View {
    @State private var watch = AnchorWatch.shared

    var body: some View {
        let alarm = watch.alarm
        NavigationLink {
            AnchorAlarmView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: alarm.state.isAlarming ? "exclamationmark.triangle.fill" : "scope")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(alarm.state.isAlarming ? Theme.coral : Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anchor alarm")
                        .font(.headline)
                        .fontDesign(.rounded)
                    Text(subtitle(alarm))
                        .font(.subheadline)
                        .foregroundStyle(alarm.state.isAlarming ? Theme.coral : .secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("anchor.open")
    }

    private func subtitle(_ alarm: AnchorAlarm) -> String {
        switch alarm.state {
        case .clear: "Off"
        case .armed: alarm.distance.map { "On · \(AnchorText.metres($0)) from anchor" } ?? "On · waiting for GPS"
        case .alarming(.dragging): "Dragging · \(AnchorText.metres(alarm.distance))"
        case .alarming(.gpsLost): "No GPS"
        }
    }
}

/// A solid banner over every tab while the anchor alarm sounds, with Silence.
struct AnchorAlarmBanner: View {
    @State private var watch = AnchorWatch.shared

    var body: some View {
        if case .alarming(let reason) = watch.alarm.state {
            HStack(spacing: 12) {
                Image(systemName: reason == .dragging ? "exclamationmark.triangle.fill" : "location.slash.fill")
                VStack(alignment: .leading, spacing: 0) {
                    Text(reason == .dragging ? "Anchor dragging" : "Anchor alarm: no GPS")
                        .font(.headline)
                    if reason == .dragging {
                        Text("\(AnchorText.metres(watch.alarm.distance)) from anchor")
                            .font(.subheadline.monospacedDigit())
                    }
                }
                Spacer(minLength: 8)
                Button("Silence") { watch.silence() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("anchor.banner.silence")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.coral, in: .rect(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("anchor.banner")
        }
    }
}

/// Anchor distances are short, so they are always whole metres, whatever the distance unit.
enum AnchorText {
    static func metres(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return "\(Int(value.rounded())) m"
    }

    static func accuracy(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return "±\(Int(value.rounded())) m"
    }

    static func bearing(_ degrees: Double?) -> String {
        guard let degrees, degrees.isFinite else { return "–" }
        return "\(Int(degrees.rounded()) % 360)° T"
    }
}
