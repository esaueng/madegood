import MapKit
import SwiftUI
import WaterKit

struct AnchorAlarmView: View {
    @State private var anchorWatch = AnchorWatch.shared
    @State private var selectedPoint: AnchorAlarm.Point?
    @State private var mapReset = 0
    @State private var radius = 40.0
    @State private var choosingRadius = false
    @State private var confirmDisarm = false
    @State private var confirmOutside = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let unit = UserSettings.display(for: .motorboating).distance
            let position = anchorWatch.position.flatMap { $0.isFresh ? $0 : nil }
            List {
                Section {
                    status(position: position)
                    if anchorWatch.gpsLossSounding {
                        Button("Stop GPS backup alarm", systemImage: "bell.slash", action: anchorWatch.stopGPSLossAlarm)
                    }
                    if anchorWatch.canStopDrift {
                        Button("Stop drift alarm", systemImage: "bell.slash", action: anchorWatch.stopDriftAlarm)
                            .accessibilityIdentifier("anchor.stopDrift")
                    }
                    if anchorWatch.locationBlocked || anchorWatch.alarmPermissionDenied || anchorWatch.alarmError {
                        Button("Open Settings", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }

                if let watch = anchorWatch.watch {
                    let reading = position.map { watch.reading(at: $0.point) }
                    Section {
                        AnchorSwingGauge(
                            distance: reading?.distance, accuracy: position?.accuracy,
                            isUsable: position?.isUsable == true, isDragging: anchorWatch.isAlarming,
                            radius: watch.radius, distanceText: length(reading?.distance, unit: unit),
                            radiusText: length(watch.radius, unit: unit))
                        LabeledContent("Bearing to anchor", value: bearing(reading?.bearing))
                            .accessibilityIdentifier("anchor.bearing")
                        LabeledContent("Swing radius", value: length(watch.radius, unit: unit))
                            .accessibilityIdentifier("anchor.armedRadius")
                        accuracyRow(position?.accuracy, unit: unit)
                    }
                } else {
                    Section {
                        Button {
                            choosingRadius = true
                        } label: {
                            LabeledContent("Swing radius") {
                                HStack(spacing: 6) {
                                    Text(length(radius, unit: unit))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Swing radius")
                        .accessibilityValue(length(radius, unit: unit))
                        .accessibilityIdentifier("anchor.radius")
                        accuracyRow(position?.accuracy, unit: unit)
                        Button("Arm anchor alarm", systemImage: "bell", action: confirmThenArm)
                            .disabled(
                                position?.isUsable != true || anchorWatch.isArming
                                    || anchorWatch.locationBlocked || anchorWatch.alarmPermissionDenied
                            )
                            .accessibilityIdentifier("anchor.arm")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("With good GPS, the drift alarm triggers more than 5 m outside this circle.")
                            Text("Allow room for the anchor rode and the boat to swing.")
                        }
                    }
                }

                if let center = anchorWatch.watch?.anchor ?? selectedPoint ?? position?.point {
                    Section {
                        AnchorCircleMap(
                            center: center, boat: position?.point, radius: anchorWatch.watch?.radius ?? radius,
                            canAdjust: anchorWatch.watch == nil, reset: mapReset,
                            select: { selectedPoint = $0 }
                        )
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                        if anchorWatch.watch == nil {
                            Button("Use current position", systemImage: "location") {
                                selectedPoint = nil
                                mapReset += 1
                            }
                            .disabled(selectedPoint == nil || position?.isUsable != true)
                            .accessibilityIdentifier("anchor.useCurrent")
                        }
                    } footer: {
                        if anchorWatch.watch == nil {
                            Text("Tap the map to adjust the anchor point. Not for navigation.")
                        } else {
                            Text("Not for navigation.")
                        }
                    }
                }

                if anchorWatch.watch != nil {
                    Section {
                        Button("Disarm anchor alarm", systemImage: "bell.slash", role: .destructive) {
                            confirmDisarm = true
                        }
                        .accessibilityIdentifier("anchor.disarm")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("The alarm uses location while armed, including with the screen locked.")
                            Text(
                                "If iOS suspends the app during automatic cancellation, an alarm may be silenced just as it starts ringing."
                            )
                        }
                    }
                }
            }
            .monospacedDigit()
        }
        .navigationTitle("Anchor Alarm")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { anchorWatch.beginSetup() }
        .onDisappear { anchorWatch.endSetup() }
        // Present outside the live GPS timeline so the choices stay stable during updates.
        .sheet(isPresented: $choosingRadius) {
            AnchorRadiusPicker(radius: $radius, unit: UserSettings.display(for: .motorboating).distance)
        }
        .confirmationDialog("Disarm the anchor alarm?", isPresented: $confirmDisarm, titleVisibility: .visible) {
            Button("Disarm", role: .destructive) {
                anchorWatch.disarm()
                selectedPoint = nil
                mapReset += 1
            }
            .accessibilityIdentifier("anchor.confirmDisarm")
        } message: {
            Text("Background anchor monitoring will stop.")
        }
        .confirmationDialog("The boat is already outside the swing circle", isPresented: $confirmOutside) {
            Button("Arm anyway", action: arm)
            Button("Keep adjusting", role: .cancel) {}
        } message: {
            Text("The alarm can sound as soon as it confirms the boat is outside.")
        }
    }

    private func confirmThenArm() {
        if let selectedPoint, let position = anchorWatch.position,
            let circle = AnchorAlarm(anchor: selectedPoint, radius: radius),
            circle.reading(at: position.point).distance > radius
        {
            confirmOutside = true
        } else {
            arm()
        }
    }

    private func arm() {
        Task { await anchorWatch.arm(at: selectedPoint, radius: radius) }
    }

    private func status(position: AnchorWatch.Position?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(anchorWatch.isAlarming ? "Anchor dragging" : anchorWatch.watch == nil ? "Alarm off" : "Armed")
                    .font(.headline)
                    .accessibilityIdentifier("anchor.status")
            } icon: {
                Image(systemName: anchorWatch.isAlarming ? "exclamationmark.triangle.fill" : "scope")
                    .foregroundStyle(anchorWatch.isAlarming ? Color.red : Color.accentColor)
            }
            if anchorWatch.alarmPermissionDenied {
                Text("Allow Alarms in Settings to hear the drift alert.")
            } else if anchorWatch.alarmError {
                Text("The system alarm couldn’t be scheduled. Check Alarms in Settings and watch the boat.")
            }
            if anchorWatch.gpsAlarmNeedsAttention {
                Text("GPS backup alarm isn’t set. Keep the boat in view.")
            }
            if anchorWatch.locationBlocked {
                Text("Allow Precise Location in Settings to monitor drift.")
            } else if position?.isUsable != true {
                Text(
                    anchorWatch.watch == nil
                        ? "Waiting for an accurate GPS fix."
                        : "GPS is unavailable or too weak to confirm drift.")
            }
        }
        .font(.subheadline)
    }

    private func accuracyRow(_ accuracy: Double?, unit: DistanceUnit) -> some View {
        LabeledContent("GPS accuracy", value: accuracy.map { "±" + length($0, unit: unit) } ?? "–")
            .accessibilityIdentifier("anchor.accuracy")
    }

    private func length(_ metres: Double?, unit: DistanceUnit) -> String {
        metres.map { unit.shortLength($0).text } ?? "–"
    }

    private func bearing(_ degrees: Double?) -> String {
        guard let degrees else { return "–" }
        return "\(LiveDisplay.course(degrees)) true"
    }
}

/// The distance to the anchor, large, over how much of the swing circle it uses. The bar
/// follows what the alarm can know: full and red while the drift alarm sounds, empty while
/// the GPS is too weak to tell, and otherwise placed with the fix's accuracy margin (red
/// only when even the near edge of the fix is outside, coral when its far edge reaches 80 %
/// of the radius). It never decides anything; the drift alarm does, in AnchorWatch.
struct AnchorSwingGauge: View {
    let distance: Double?
    let accuracy: Double?
    let isUsable: Bool
    let isDragging: Bool
    let radius: Double
    let distanceText: String
    let radiusText: String

    enum Zone {
        case unknown, inside, nearEdge, outside, dragging
    }

    static func zone(
        distance: Double?, accuracy: Double?, isUsable: Bool, isDragging: Bool, radius: Double
    ) -> Zone {
        if isDragging { return .dragging }
        guard isUsable, let distance, let accuracy, radius > 0 else { return .unknown }
        if distance - accuracy > radius { return .outside }
        if distance + accuracy >= radius * 0.8 { return .nearEdge }
        return .inside
    }

    var body: some View {
        let zone = Self.zone(
            distance: distance, accuracy: accuracy, isUsable: isUsable, isDragging: isDragging, radius: radius)
        let share = distance.map { radius > 0 ? $0 / radius : 0 } ?? 0
        let (fill, tint, note, spoken): (Double, Color, String, String) =
            switch zone {
            case .dragging: (1, .red, "Anchor dragging", "anchor dragging")
            case .unknown:
                (0, .clear, "GPS too weak to place the boat in the circle", "GPS too weak to place the boat")
            case .outside: (1, .red, "Outside the \(radiusText) swing radius", "outside the swing circle")
            case .nearEdge:
                (
                    share, Theme.coral, "Near the edge of the \(radiusText) swing radius",
                    "near the edge of the swing circle"
                )
            case .inside:
                (share, Theme.Metric.distance, "Inside the \(radiusText) swing radius", "inside the swing circle")
            }
        VStack(alignment: .leading, spacing: 10) {
            MetricValue(title: "Distance to anchor", value: distanceText, color: Theme.Metric.distance)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(1, max(0, fill)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text(note)
                .font(.footnote)
                .foregroundStyle(zone == .dragging || zone == .outside ? Color.red : .secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance to anchor, \(distanceText)")
        .accessibilityValue(spoken)
        .accessibilityIdentifier("anchor.distance")
    }
}

private struct AnchorRadiusPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var radius: Double
    let unit: DistanceUnit

    private static let radii = [10.0, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300, 500]

    var body: some View {
        NavigationStack {
            List(Self.radii, id: \.self) { candidate in
                Button {
                    radius = candidate
                    dismiss()
                } label: {
                    HStack {
                        Text(unit.shortLength(candidate).text)
                        Spacer()
                        if candidate == radius {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityAddTraits(candidate == radius ? .isSelected : [])
            }
            .monospacedDigit()
            .navigationTitle("Swing radius")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct AnchorCircleMap: View {
    let center: AnchorAlarm.Point
    let boat: AnchorAlarm.Point?
    let radius: Double
    let canAdjust: Bool
    let reset: Int
    let select: (AnchorAlarm.Point) -> Void
    @State private var camera = MapCameraPosition.automatic

    var body: some View {
        MapReader { reader in
            Map(position: $camera, interactionModes: canAdjust ? [.pan, .zoom] : []) {
                MapCircle(center: center.coordinate, radius: radius)
                    .foregroundStyle(.blue.opacity(0.13))
                    .stroke(.blue, lineWidth: 2)
                Marker("Anchor", systemImage: "mappin", coordinate: center.coordinate)
                    .tint(.blue)
                if let boat {
                    Annotation("Boat", coordinate: boat.coordinate) {
                        Circle().fill(.blue)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .frame(width: 16, height: 16)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    guard canAdjust, let coordinate = reader.convert(tap.location, from: .local),
                        let point = AnchorAlarm.Point(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    else { return }
                    select(point)
                }
            )
            .onChange(of: radius, initial: true) { _, _ in recenter() }
            .onChange(of: canAdjust) { _, _ in recenter() }
            .onChange(of: reset) { _, _ in recenter() }
        }
        .accessibilityIdentifier("anchor.map")
    }

    private func recenter() {
        camera = .region(
            MKCoordinateRegion(
                center: center.coordinate, latitudinalMeters: radius * 4, longitudinalMeters: radius * 4))
    }
}

private extension AnchorAlarm.Point {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct AnchorAlarmLink: View {
    @State private var anchorWatch = AnchorWatch.shared

    var body: some View {
        NavigationLink {
            AnchorAlarmView()
        } label: {
            Label(anchorWatch.watch == nil ? "Anchor alarm" : "Anchor alarm armed", systemImage: "scope")
        }
        .accessibilityIdentifier("anchor.open")
    }
}
