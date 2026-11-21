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
    static let shared: AnchorWatch = {
        let watch = AnchorWatch(
            system: .live(slots: soundSlots, title: "Anchor dragging"),
            clock: { .live }, defaults: .standard)
        watch.startMonitoring()
        return watch
    }()

    private struct SavedWatch: Codable {
        let point: AnchorAlarm.Point
        let radius: Double
        var alertPending = false
        var confirmedOutside: Bool?
        var snooze: DriftSnooze?
        var observedSounding: Set<UUID>?
        var snoozeUntil: Date?  // Legacy wall-clock snooze, migrated on restore.
    }

    private struct DriftSnooze: Codable {
        let measuredAt: TimeInterval
        let deadline: TimeInterval

        func remaining(at uptime: TimeInterval) -> TimeInterval {
            // A reboot can reset uptime. An uncertain deadline is due now.
            uptime >= measuredAt ? deadline - uptime : 0
        }
    }

    struct Position {
        let point: AnchorAlarm.Point
        let accuracy: Double?
        let measuredAt: ContinuousClock.Instant

        var freshUntil: ContinuousClock.Instant { measuredAt + .seconds(15) }
        var isFresh: Bool { ContinuousClock.now <= freshUntil }
        var isUsable: Bool {
            isFresh && accuracy.map { $0 <= AnchorAlarm.maximumAccuracy } == true
        }
    }

    private static let storageKey = "anchorWatch.configuration"
    // Keep the original stable ID for upgrades. A second slot lets a clock
    // correction install a replacement before cancelling the old alarm.
    static let soundID = UUID(uuidString: "235026A9-7F06-46D1-AB58-12CC791B87EA")!
    private static let soundSlots = [soundID, UUID(uuidString: "837294E8-DBFD-4775-A1CE-86CF282A85DD")!]

    private let location = CLLocationManager()
    private let alarms = AlarmManager.shared
    private let gpsWatchdog: AnchorGPSWatchdog
    private let system: AnchorSystemAlarms
    private let clock: () -> AnchorGPSWatchdog.ClockReading
    private let defaults: UserDefaults
    private var serviceSession: CLServiceSession?
    private var backgroundActivity: CLBackgroundActivitySession?
    private let startedAt = ContinuousClock.now
    private var viewerCount = 0
    private var locationRunning = false
    private var demoUpdates: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var driftRetry: Task<Void, Never>?
    private var evidenceStartedAt = ContinuousClock.now
    private var saved: SavedWatch?
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
    private var wantsDriftAlarm: Bool { saved?.alertPending == true || saved?.snooze != nil }

    init(
        system: AnchorSystemAlarms,
        clock: @escaping () -> AnchorGPSWatchdog.ClockReading,
        defaults: UserDefaults,
        gpsWatchdog: AnchorGPSWatchdog = AnchorGPSWatchdog()
    ) {
        self.system = system
        self.clock = clock
        self.defaults = defaults
        self.gpsWatchdog = gpsWatchdog
        super.init()
        if !DemoFeed.isEnabled,
            let data = defaults.data(forKey: Self.storageKey),
            let restored = try? JSONDecoder().decode(SavedWatch.self, from: data),
            let watch = AnchorAlarm(
                anchor: restored.point, radius: restored.radius,
                confirmedOutside: restored.confirmedOutside ?? restored.alertPending)
        {
            saved = restored
            self.watch = watch
            if let legacy = restored.snoozeUntil {
                let now = clock()
                let remaining = legacy.timeIntervalSince(now.wallTime)
                let delay = (0...AnchorAlarm.snoozeDuration).contains(remaining) ? remaining : 0
                saved?.snooze = DriftSnooze(measuredAt: now.uptime, deadline: now.uptime + delay)
                saved?.snoozeUntil = nil
                persist()
            }
        }
    }

    private func startMonitoring() {
        location.delegate = self
        location.activityType = .otherNavigation
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        refreshPermissions()
        if !DemoFeed.isEnabled {
            if watch == nil {
                gpsWatchdog.stop()
            } else {
                gpsWatchdog.start(restoring: true)
            }
            gpsWatchdog.setActive(UIApplication.shared.applicationState == .active)
            Task { [gpsWatchdog, weak self] in
                await gpsWatchdog.observeAlarmChanges { snapshot in
                    self?.rememberSounding(snapshot.sounding.intersection(Self.soundSlots))
                    self?.reconcileSound()
                }
            }
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.significantTimeChangeNotification) {
                    self?.reconcileSound()
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
        if position?.isFresh == false { position = nil }
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
        if Self.soundSlots.contains(id) {
            rememberSounding([id])
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
        evidenceStartedAt = .now
        saved = SavedWatch(point: anchor, radius: radius)
        watch = configured
        if !DemoFeed.isEnabled { gpsWatchdog.start() }
        persist()
        updateLocationDemand()
    }

    func stopDriftAlarm() {
        if DemoFeed.isEnabled {
            driftAlarmStopped()
            return
        }
        guard let snapshot = try? system.snapshot() else { return }
        var stopped = Set<UUID>()
        for id in snapshot.sounding where (try? system.stopSounding(id)) == true {
            stopped.insert(id)
        }
        if !stopped.isEmpty {
            saved?.observedSounding?.subtract(stopped)
            driftAlarmStopped()
        }
        reconcileSound()
    }

    private func driftAlarmStopped() {
        driftRevision += 1
        let now = clock().uptime
        saved?.alertPending = false
        saved?.snooze = watch?.snoozeDeadline(afterStopAt: now).map { DriftSnooze(measuredAt: now, deadline: $0) }
        alarmError = false
        persist()
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

    func ingest(point: AnchorAlarm.Point, accuracy: Double?, measuredAt: ContinuousClock.Instant) {
        if let position, measuredAt <= position.measuredAt { return }
        position = Position(point: point, accuracy: accuracy, measuredAt: measuredAt)
        guard watch != nil, measuredAt >= evidenceStartedAt, position?.isFresh == true else { return }
        let wasDrifting = watch?.isDrifting == true

        let elapsed = startedAt.duration(to: measuredAt).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard let assessment = watch?.assess(
            GPSFix(t: seconds, latitude: point.latitude, longitude: point.longitude, horizontalAccuracy: accuracy)
        ) else { return }
        let confirmedOutside = watch?.isDrifting == true
        if wasDrifting != confirmedOutside {
            let cancelSnooze = !confirmedOutside && saved?.snooze != nil
            saved?.confirmedOutside = confirmedOutside
            if assessment == .driftConfirmed, !wantsDriftAlarm {
                driftRevision += 1
                saved?.alertPending = true
            } else if cancelSnooze {
                driftRevision += 1
                saved?.snooze = nil
            }
            persist()
            if assessment == .driftConfirmed || cancelSnooze { reconcileSound() }
        }
        if DemoFeed.isEnabled, let snooze = saved?.snooze, snooze.remaining(at: clock().uptime) <= 0 {
            saved?.snooze = nil
            saved?.alertPending = true
        }
        // Until the boat is confidently inside, preserve the GPS alarm as a
        // fallback even if overlapping fixes keep arriving during a drift snooze.
        if !DemoFeed.isEnabled, !confirmedOutside {
            let age = measuredAt.duration(to: .now).components
            gpsWatchdog.renew(fixAge: Double(age.seconds) + Double(age.attoseconds) / 1e18, assessment: assessment)
        }
    }

    private func persist() {
        guard !DemoFeed.isEnabled else { return }
        defaults.set(saved.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.storageKey)
    }

    // MARK: - System alarm

    private func rememberSounding(_ ids: Set<UUID>) {
        guard let saved, !ids.isSubset(of: saved.observedSounding ?? []) else { return }
        self.saved?.observedSounding = (saved.observedSounding ?? []).union(ids)
        persist()
    }

    func reconcileSound() {
        guard !DemoFeed.isEnabled, !alarmPermissionDenied else { return }
        guard let snapshot = try? system.snapshot() else {
            if wantsDriftAlarm {
                signalSoundFailure()
                retryDriftReconciliation()
            }
            return
        }
        do {
            driftSounding = !snapshot.sounding.isEmpty
            let observed = saved?.observedSounding ?? []
            let stopped = snapshot.stoppedAlarms(since: .init(sounding: observed))
            if observed != snapshot.sounding {
                saved?.observedSounding = snapshot.sounding
                persist()
            }
            if !stopped.isEmpty { driftAlarmStopped() }
            guard scheduleTask == nil else { return }

            if !wantsDriftAlarm {
                try cancelDriftPending(in: snapshot)
                return
            }
            if driftSounding { return }
            let now = clock()
            let remaining = saved?.snooze?.remaining(at: now.uptime)
            if let current = snapshot.pending.first(where: { _, deadline in
                guard let remaining else { return true }
                let fixedRemaining = deadline.timeIntervalSince(now.wallTime)
                return remaining <= 0 ? (-1...1.5).contains(fixedRemaining) : abs(fixedRemaining - remaining) <= 1
            }) {
                alarmError = false
                try cancelDriftPending(in: snapshot, keeping: current.key)
            } else if let next = Self.soundSlots.first(where: { snapshot.pending[$0] == nil }) {
                let delay = remaining.map { max(1, $0) } ?? 2
                scheduleDriftAlarm(id: next, deadline: now.wallTime.addingTimeInterval(delay))
            } else {
                // Keep the earlier fallback while freeing a slot. Imminent
                // pending alarms will fire on their own and are left alone.
                try cancelDriftPending(in: snapshot, keeping: snapshot.earliestPending?.key)
                retryDriftReconciliation()
            }
        } catch {
            if wantsDriftAlarm { signalSoundFailure() }
            retryDriftReconciliation()
        }
    }

    private func cancelDriftPending(in snapshot: AnchorSystemAlarms.Snapshot, keeping id: UUID? = nil) throws {
        for (other, deadline) in snapshot.pending where other != id {
            guard canCancelPendingAnchorAlarm(deadline: deadline, now: clock().wallTime) else { continue }
            _ = try system.cancelPending(other)
        }
    }

    private func scheduleDriftAlarm(id: UUID, deadline: Date) {
        guard driftRetry == nil else { return }
        let revision = driftRevision
        scheduleTask = Task {
            defer {
                scheduleTask = nil
                reconcileSound()
            }
            guard revision == driftRevision else { return }
            do {
                try await system.schedule(id, deadline)
            } catch {
                if revision == driftRevision { signalSoundFailure() }
                retryDriftReconciliation()
            }
        }
    }

    private func retryDriftReconciliation() {
        guard driftRetry == nil else { return }
        driftRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            driftRetry = nil
            reconcileSound()
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
