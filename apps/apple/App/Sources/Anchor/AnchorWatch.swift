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
        var confirmedOutside: Bool?
        var snoozeUntil: Date?
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
    // Stable ID lets a later launch find the drift alarm.
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
    private var driftCleanupPending = false
    private var driftRevision = 0

    private(set) var watch: AnchorAlarm?
    private(set) var position: Position?
    private(set) var locationBlocked = false
    private(set) var alarmPermissionDenied = false
    private(set) var alarmError = false
    var gpsAlarmNeedsAttention: Bool { watch != nil && !DemoFeed.isEnabled && !gpsWatchdog.hasSystemAlarm }
    private(set) var isArming = false

    var isViewing: Bool { viewerCount > 0 }
    var isAlarming: Bool { saved?.alertPending == true || (watch != nil && driftSounding) }
    private(set) var driftSounding = false
    var gpsLossSounding: Bool { gpsWatchdog.hasSoundingAlarm }
    var canStopDrift: Bool { driftSounding || (DemoFeed.isEnabled && isAlarming) }
    var hasSoundingAlarm: Bool { driftSounding || gpsLossSounding }
    private var wantsDriftAlarm: Bool { saved?.alertPending == true || saved?.snoozeUntil != nil }

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
            let watch = AnchorAlarm(
                anchor: restored.point, radius: restored.radius,
                confirmedOutside: restored.confirmedOutside ?? restored.alertPending)
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
            gpsWatchdog.setActive(UIApplication.shared.applicationState == .active)
            Task { [gpsWatchdog, weak self] in
                await gpsWatchdog.observeAlarmChanges { self?.reconcileSound() }
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
        guard !DemoFeed.isEnabled else { return }
        gpsWatchdog.setActive(true)
        gpsWatchdog.reconcile()
    }

    func becameInactive() {
        gpsWatchdog.setActive(false)
    }

    func stopGPSLossAlarm() {
        gpsWatchdog.stopSoundingAlarms()
    }

    func reconcileAfterSystemStop(id: UUID) async {
        if id == Self.soundID {
            reconcileSound()
            await scheduleTask?.value
        } else {
            await gpsWatchdog.reconcileAfterSystemStop(id: id)
        }
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

    func stopDriftAlarm() {
        guard DemoFeed.isEnabled || (try? stopSoundingAnchorAlarm(id: Self.soundID)) == true else {
            reconcileSound()
            return
        }
        driftSounding = false
        if watch != nil { driftAlarmStopped() }
    }

    private func driftAlarmStopped() {
        driftRevision += 1
        saved?.alertPending = false
        saved?.alarmScheduled = false
        saved?.snoozeUntil = watch?.snoozeDeadline(afterStopAt: Date.now.timeIntervalSinceReferenceDate)
            .map { Date(timeIntervalSinceReferenceDate: $0) }
        alarmError = false
        lastScheduleAttempt = nil
        persist()
        scheduleSoundIfNeeded()
    }

    func disarm() {
        driftRevision += 1
        saved = nil
        watch = nil
        alarmError = false
        persist()
        reconcileSound()
        if !DemoFeed.isEnabled { gpsWatchdog.stop() }
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
        if driftCleanupPending { reconcileSound() }
        guard watch != nil, measuredAt >= evidenceStartedAt, position?.isFresh == true else { return }
        let wasDrifting = watch?.isDrifting == true

        let elapsed = startedAt.duration(to: measuredAt).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard let assessment = watch?.assess(
            GPSFix(t: seconds, latitude: point.latitude, longitude: point.longitude, horizontalAccuracy: accuracy)
        ) else { return }
        let confirmedOutside = watch?.isDrifting == true
        if wasDrifting != confirmedOutside {
            let cancelSnooze = !confirmedOutside && saved?.snoozeUntil != nil
            saved?.confirmedOutside = confirmedOutside
            if assessment == .driftConfirmed, !wantsDriftAlarm {
                driftRevision += 1
                saved?.alertPending = true
            } else if cancelSnooze {
                driftRevision += 1
                saved?.snoozeUntil = nil
                saved?.alarmScheduled = false
                lastScheduleAttempt = nil
            }
            persist()
            if cancelSnooze { reconcileSound() }
        }
        if DemoFeed.isEnabled, let snoozeUntil = saved?.snoozeUntil, snoozeUntil <= .now {
            saved?.snoozeUntil = nil
            saved?.alertPending = true
        }
        if wantsDriftAlarm { scheduleSoundIfNeeded() }
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
        guard !DemoFeed.isEnabled else { return }
        alarmPermissionDenied = alarms.authorizationState == .denied
        if alarmPermissionDenied, saved?.alarmScheduled == true {
            saved?.alarmScheduled = false
            lastScheduleAttempt = nil
            persist()
        }
        do {
            let alarm = try alarms.alarms.first { $0.id == Self.soundID }
            driftSounding = alarm?.state == .alerting
            guard scheduleTask == nil else { return }
            if driftCleanupPending || !wantsDriftAlarm {
                try cancelPendingAnchorAlarm(id: Self.soundID)
                driftCleanupPending = false
            }
            guard wantsDriftAlarm else { return }
            if saved?.alarmScheduled == true {
                if alarm == nil { driftAlarmStopped() }
            } else {
                scheduleSoundIfNeeded()
            }
        } catch {
            if !wantsDriftAlarm { driftCleanupPending = true }
        }
    }

    private func scheduleSoundIfNeeded() {
        guard !DemoFeed.isEnabled, wantsDriftAlarm, saved?.alarmScheduled == false,
            !driftCleanupPending, scheduleTask == nil,
            lastScheduleAttempt.map({ $0.duration(to: .now) >= .seconds(5) }) ?? true
        else { return }
        lastScheduleAttempt = .now
        guard !alarmPermissionDenied else {
            signalSoundFailure()
            return
        }
        let revision = driftRevision
        scheduleTask = Task {
            defer {
                scheduleTask = nil
                reconcileSound()
            }
            guard revision == driftRevision else { return }
            do {
                // Adopt a sounding alarm or an installation interrupted by relaunch.
                if try !alarms.alarms.contains(where: { $0.id == Self.soundID }) {
                    let now = Date.now
                    let deadline = saved?.snoozeUntil.map { max($0, now.addingTimeInterval(1)) }
                        ?? now.addingTimeInterval(2)
                    let configuration = anchorAlarmConfiguration(
                        id: Self.soundID, title: "Anchor dragging", deadline: deadline)
                    _ = try await AlarmManager.shared.schedule(id: Self.soundID, configuration: configuration)
                }
                guard revision == driftRevision else {
                    driftCleanupPending = true
                    return
                }
                saved?.alarmScheduled = true
                alarmError = false
                persist()
            } catch {
                if revision != driftRevision {
                    driftCleanupPending = true
                } else {
                    signalSoundFailure()
                }
            }
        }
    }

    private func signalSoundFailure() {
        alarmError = true
        if UIApplication.shared.applicationState == .active {
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
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
