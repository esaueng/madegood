import AlarmKit
import AudioToolbox
import CoreLocation
import Observation
import SwiftUI
import UIKit
import WaterKit

/// Owns the iPhone's anchor watch independently of any recording or screen.
@MainActor
@Observable
final class AnchorWatch: NSObject {
    static let shared = AnchorWatch()

    private struct SavedWatch: Codable {
        let point: AnchorAlarm.Point
        let radius: Double
        var alertPending = false
        var alarmScheduled = false
    }

    struct Position {
        let point: AnchorAlarm.Point
        let accuracy: Double?
        let measuredAt: ContinuousClock.Instant

        var isFresh: Bool { measuredAt.duration(to: .now) <= .seconds(15) }
        var isUsable: Bool {
            isFresh && accuracy.map { $0 <= AnchorAlarm.maximumAccuracy } == true
        }
    }

    private static let storageKey = "anchorWatch.configuration"
    // One system alarm per app. A later launch can clean it up even if the app
    // stopped between updating its saved configuration and cancelling the alarm.
    private static let soundID = UUID(uuidString: "235026A9-7F06-46D1-AB58-12CC791B87EA")!

    private let location = CLLocationManager()
    private let alarms = AlarmManager.shared
    private let gpsWatchdog = AnchorGPSWatchdog()
    private var serviceSession: CLServiceSession?
    private var backgroundActivity: CLBackgroundActivitySession?
    private let startedAt = ContinuousClock.now
    private var viewerCount = 0
    private var locationRunning = false
    private var demoUpdates: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var lastScheduleAttempt: ContinuousClock.Instant?
    private var evidenceStartedAt = ContinuousClock.now
    private var saved: SavedWatch?

    private(set) var watch: AnchorAlarm?
    private(set) var position: Position?
    private(set) var locationBlocked = false
    private(set) var alarmPermissionDenied = false
    private(set) var alarmError = false
    var gpsAlarmNeedsAttention: Bool { watch != nil && !DemoFeed.isEnabled && !gpsWatchdog.hasSystemAlarm }
    private(set) var isArming = false

    var isViewing: Bool { viewerCount > 0 }
    var isAlarming: Bool { saved?.alertPending == true }

    private override init() {
        super.init()
        location.delegate = self
        location.activityType = .otherNavigation
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        if !DemoFeed.isEnabled,
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let restored = try? JSONDecoder().decode(SavedWatch.self, from: data),
            let watch = AnchorAlarm(anchor: restored.point, radius: restored.radius)
        {
            saved = restored
            self.watch = watch
        }
        refreshPermissions()
        if !DemoFeed.isEnabled {
            if watch == nil {
                gpsWatchdog.stop()
            } else {
                gpsWatchdog.start(restoring: true)
            }
            Task { [weak self] in
                for await _ in AlarmManager.shared.alarmUpdates {
                    self?.reconcileSound()
                }
            }
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.significantTimeChangeNotification) {
                    self?.gpsWatchdog.reconcile()
                }
            }
            Task { [weak self] in
                for await _ in AlarmManager.shared.authorizationUpdates {
                    self?.refreshPermissions()
                    self?.reconcileSound()
                    self?.gpsWatchdog.reconcile()
                }
            }
        }
        updateLocationDemand()
        reconcileSound()
    }

    func becameActive() {
        refreshPermissions()
        updateLocationDemand()
        if locationRunning, !DemoFeed.isEnabled { location.startUpdatingLocation() }
        reconcileSound()
        gpsWatchdog.reconcile()
    }

    func beginSetup() {
        viewerCount += 1
        refreshPermissions()
        if !DemoFeed.isEnabled, location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        updateLocationDemand()
    }

    func endSetup() {
        viewerCount = max(0, viewerCount - 1)
        updateLocationDemand()
    }

    func arm(at point: AnchorAlarm.Point?, radius: Double) async {
        guard watch == nil, !isArming, position?.isUsable == true,
            let anchor = point ?? position?.point,
            let configured = AnchorAlarm(anchor: anchor, radius: radius)
        else { return }

        isArming = true
        defer { isArming = false }
        if !DemoFeed.isEnabled {
            do {
                let permission =
                    alarms.authorizationState == .notDetermined
                    ? try await AlarmManager.shared.requestAuthorization() : alarms.authorizationState
                alarmPermissionDenied = permission != .authorized
                alarmError = false
                guard !alarmPermissionDenied else { return }
            } catch {
                alarmError = true
                return
            }
        }

        // Location and the screen can change while the system's permission sheet is open.
        guard !Task.isCancelled, isViewing, position?.isUsable == true, !locationBlocked else { return }
        lastScheduleAttempt = nil
        evidenceStartedAt = .now
        saved = SavedWatch(point: anchor, radius: radius)
        watch = configured
        if !DemoFeed.isEnabled { gpsWatchdog.start() }
        persist()
        updateLocationDemand()
    }

    func acknowledge() {
        guard isAlarming else { return }
        saved?.alertPending = false
        saved?.alarmScheduled = false
        watch?.acknowledge()
        evidenceStartedAt = .now
        alarmError = false
        lastScheduleAttempt = nil
        persist()
        cancelSound()
    }

    func disarm() {
        saved = nil
        watch = nil
        alarmError = false
        persist()
        cancelSound()
        gpsWatchdog.stop()
        updateLocationDemand()
    }

    private func refreshPermissions() {
        guard !DemoFeed.isEnabled else { return }
        switch location.authorizationStatus {
        case .denied, .restricted: locationBlocked = true
        default: locationBlocked = location.accuracyAuthorization == .reducedAccuracy
        }
        if locationBlocked { position = nil }
        alarmPermissionDenied = alarms.authorizationState == .denied
    }

    private func updateLocationDemand() {
        let shouldRun = watch != nil || isViewing
        if DemoFeed.isEnabled {
            if shouldRun, demoUpdates == nil {
                demoUpdates = Task { await runDemo() }
            } else if !shouldRun {
                demoUpdates?.cancel()
                demoUpdates = nil
                position = nil
            }
            return
        }

        // Standard updates continue when stationary and with the display locked.
        // Enabling background delivery only while armed keeps setup foreground-only.
        let authorized =
            location.authorizationStatus == .authorizedWhenInUse
            || location.authorizationStatus == .authorizedAlways
        let shouldTrack = shouldRun && authorized && !locationBlocked
        let background = shouldTrack && watch != nil
        if background, backgroundActivity == nil {
            serviceSession = CLServiceSession(authorization: .whenInUse)
            backgroundActivity = CLBackgroundActivitySession()
        } else if !background {
            backgroundActivity?.invalidate()
            backgroundActivity = nil
            serviceSession?.invalidate()
            serviceSession = nil
        }
        let restart = location.allowsBackgroundLocationUpdates != background
        if locationRunning, !shouldTrack || restart { location.stopUpdatingLocation() }
        location.allowsBackgroundLocationUpdates = background
        location.showsBackgroundLocationIndicator = background
        if shouldTrack, !locationRunning || restart { location.startUpdatingLocation() }
        locationRunning = shouldTrack
        if !shouldTrack { position = nil }
    }

    private func ingest(point: AnchorAlarm.Point, accuracy: Double?, measuredAt: ContinuousClock.Instant) {
        if let position, measuredAt <= position.measuredAt { return }
        position = Position(point: point, accuracy: accuracy, measuredAt: measuredAt)
        guard watch != nil, measuredAt >= evidenceStartedAt, position?.isFresh == true else { return }

        let elapsed = startedAt.duration(to: measuredAt).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard let assessment = watch?.assess(
            GPSFix(t: seconds, latitude: point.latitude, longitude: point.longitude, horizontalAccuracy: accuracy)
        ) else { return }
        if assessment == .driftConfirmed, !isAlarming {
            saved?.alertPending = true
            persist()
        }
        if isAlarming { scheduleSoundIfNeeded() }
        if !DemoFeed.isEnabled {
            let age = measuredAt.duration(to: .now).components
            gpsWatchdog.renew(fixAge: Double(age.seconds) + Double(age.attoseconds) / 1e18, assessment: assessment)
        }
    }

    private func persist() {
        guard !DemoFeed.isEnabled else { return }
        UserDefaults.standard.set(saved.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.storageKey)
    }

    // MARK: - System alarm

    private func reconcileSound() {
        guard !DemoFeed.isEnabled, scheduleTask == nil else { return }
        guard isAlarming else {
            cancelSound()
            return
        }
        // Missing after successful scheduling means the system stopped the alarm
        // (for example, the user tapped Stop on the Lock Screen).
        alarmPermissionDenied = alarms.authorizationState == .denied
        if alarmPermissionDenied, saved?.alarmScheduled == true {
            saved?.alarmScheduled = false
            lastScheduleAttempt = nil
            persist()
        }
        if saved?.alarmScheduled == true {
            if let current = try? alarms.alarms, !current.contains(where: { $0.id == Self.soundID }) {
                acknowledge()
            }
        } else {
            scheduleSoundIfNeeded()
        }
    }

    private func scheduleSoundIfNeeded() {
        guard !DemoFeed.isEnabled, isAlarming, saved?.alarmScheduled == false,
            scheduleTask == nil,
            lastScheduleAttempt.map({ $0.duration(to: .now) >= .seconds(5) }) ?? true
        else { return }
        lastScheduleAttempt = .now
        guard !alarmPermissionDenied else {
            signalSoundFailure()
            return
        }
        scheduleTask = Task {
            defer {
                scheduleTask = nil
                reconcileSound()
            }
            do {
                // The alarm may already exist after a relaunch between schedule and persist.
                if try !alarms.alarms.contains(where: { $0.id == Self.soundID }) {
                    let configuration = anchorAlarmConfiguration(
                        title: "Anchor dragging", deadline: Date.now.addingTimeInterval(2))
                    _ = try await AlarmManager.shared.schedule(id: Self.soundID, configuration: configuration)
                }
                guard isAlarming else {
                    cancelSound()
                    return
                }
                saved?.alarmScheduled = true
                alarmError = false
                persist()
            } catch {
                guard isAlarming else { return }
                signalSoundFailure()
            }
        }
    }

    private func signalSoundFailure() {
        alarmError = true
        if UIApplication.shared.applicationState == .active {
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        }
    }

    private func cancelSound() {
        guard !DemoFeed.isEnabled,
            let alarm = try? alarms.alarms.first(where: { $0.id == Self.soundID })
        else { return }
        if alarm.state == .alerting {
            try? alarms.stop(id: Self.soundID)
        } else {
            try? alarms.cancel(id: Self.soundID)
        }
    }

    private func runDemo() async {
        let drift = ProcessInfo.processInfo.arguments.contains("-demoAnchorDrift")
        var step = 0
        while !Task.isCancelled {
            let distance = drift && watch != nil ? max(0, Double(step - 2)) * 8 : 0
            let coordinate = Geo.destination(
                lat: DemoFeed.origin.lat, lon: DemoFeed.origin.lon, bearing: 90, distance: distance)
            if let point = AnchorAlarm.Point(latitude: coordinate.lat, longitude: coordinate.lon) {
                ingest(point: point, accuracy: 5, measuredAt: .now)
            }
            step = watch == nil ? 0 : step + 1
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

extension AnchorWatch: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            refreshPermissions()
            updateLocationDemand()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard locationRunning, !locationBlocked else { return }
            let now = ContinuousClock.now
            let wallNow = Date.now
            for fix in locations {
                let age = wallNow.timeIntervalSince(fix.timestamp)
                guard (-1...15).contains(age),
                    let point = AnchorAlarm.Point(
                        latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                else { continue }
                let accuracy = fix.horizontalAccuracy
                ingest(
                    point: point, accuracy: accuracy.isFinite && accuracy >= 0 ? accuracy : nil,
                    measuredAt: now - .seconds(max(0, age)))
            }
        }
    }
}
