import MapKit
import SwiftUI
import WaterKit

struct AnchorAlarmView: View {
    @State private var anchorWatch = AnchorWatch.shared
    @State private var position: AnchorFixDisplay?
    @State private var selectedPoint: AnchorAlarm.Point?
    @State private var mapReset = 0
    @State private var radius = 40.0
    @State private var confirmDisarm = false
    @State private var confirmOutside = false
    @Environment(\.openURL) private var openURL

    private static let radii = [10.0, 15, 20, 30, 40, 50, 75, 100, 150, 200, 300, 500]

    var body: some View {
        let unit = UserSettings.display(for: .motorboating).distance
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
                    LabeledContent("Distance to anchor", value: length(reading?.distance, unit: unit))
                        .accessibilityIdentifier("anchor.distance")
                    LabeledContent("Bearing to anchor", value: bearing(reading?.bearing))
                        .accessibilityIdentifier("anchor.bearing")
                    LabeledContent("Swing radius", value: length(watch.radius, unit: unit))
                        .accessibilityIdentifier("anchor.armedRadius")
                    accuracyRow(position?.accuracy, unit: unit)
                }
            } else {
                Section {
                    Picker("Swing radius", selection: $radius) {
                        ForEach(Self.radii, id: \.self) { candidate in
                            Text(length(candidate, unit: unit)).tag(candidate)
                        }
                    }
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
                    Text("The alarm uses location while armed, including with the screen locked.")
                }
            }
        }
        .monospacedDigit()
        .background {
            AnchorFixUpdates(anchorWatch: anchorWatch, fix: $position)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationTitle("Anchor Alarm")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            position = AnchorFixDisplay.current(from: anchorWatch.position)
            anchorWatch.beginSetup()
        }
        .onDisappear {
            position = nil
            anchorWatch.endSetup()
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

    private func status(position: AnchorFixDisplay?) -> some View {
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

private struct AnchorFixDisplay: Equatable {
    let point: AnchorAlarm.Point
    let accuracy: Double?
    let isUsable: Bool

    static func current(from position: AnchorWatch.Position?) -> Self? {
        guard let position, position.isFresh else { return nil }
        return Self(point: position.point, accuracy: position.accuracy, isUsable: position.isUsable)
    }
}

/// Observe GPS timestamps separately so a renewed fix with identical readings leaves the list alone.
private struct AnchorFixUpdates: View {
    let anchorWatch: AnchorWatch
    @Binding var fix: AnchorFixDisplay?

    var body: some View {
        let position = anchorWatch.position
        Color.clear
            .task(id: position?.measuredAt) {
                guard let position, let display = AnchorFixDisplay.current(from: position) else {
                    if fix != nil { fix = nil }
                    return
                }
                if fix != display { fix = display }

                // Expire a fix once, even if Core Location stops sending updates.
                do {
                    try await ContinuousClock().sleep(until: position.freshUntil)
                } catch {
                    return
                }
                guard !Task.isCancelled, anchorWatch.position?.measuredAt == position.measuredAt else { return }
                fix = nil
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
