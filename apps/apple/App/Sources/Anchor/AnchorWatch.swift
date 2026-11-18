import AudioToolbox
import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications
import WaterKit

/// The iPhone anchor alarm (docs/PLAN.md §5): WaterKit's `AnchorAlarm` fed by its own
/// location updates, which keep running in the background for as long as the anchor is
/// set. It is independent of any recording and saved across relaunches.
///
/// Alerts do not depend on the app running: while armed, a local notification is kept
/// pending for the moment GPS would count as lost (a dead-man's switch, moved forward by
/// every usable fix), and while alarming, repeat notifications are pending every 30 s
/// (`AnchorAlertSchedule`). In the foreground the phone also sounds and buzzes.
@MainActor
@Observable
final class AnchorWatch {
    static let shared = AnchorWatch()

    /// How often the GPS-lost check and the in-app alarm run, s.
    static let tickInterval: Duration = .seconds(2)
    /// A pending notification is moved only when its time changes by more than this, s,
    /// so a fix every second does not reschedule it every second.
    static let rescheduleTolerance: TimeInterval = 10

    /// The latest position from any accuracy, for the screen.
    struct Position: Equatable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
    }

    private static let storageKey = "anchorWatch.alarm"
    private static let radiusKey = "anchorWatch.radius"

    private(set) var alarm: AnchorAlarm
    private(set) var position: Position?
    /// Why alerts may not reach the user; empty when notifications and location are allowed.
    private(set) var issues: [AnchorReadiness.Issue] = []
    /// The radius picked for the next anchor, m.
    var radius: Double {
        didSet { UserDefaults.standard.set(radius, forKey: Self.radiusKey) }
    }

    private var recent: [GPSFix] = []
    private var updates: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundActivity: CLBackgroundActivitySession?
    private let locationManager = CLLocationManager()
    /// `ProcessInfo.systemUptime` of the latest in-app alert; nil until the first alert of
    /// the current alarm in this process, so a restored alarm sounds at once.
    private var lastAlert: TimeInterval?
    /// Notifications this object has scheduled: identifier → fire time (unix time).
    private var scheduled: [String: Double] = [:]
    private var viewers = 0

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode(AnchorAlarm.self, from: data)
        {
            alarm = saved
        } else {
            alarm = AnchorAlarm()
        }
        let saved = defaults.double(forKey: Self.radiusKey)
        radius = AnchorAlarm.radiusRange.contains(saved) ? saved : AnchorAlarm.defaultRadius
        #if DEBUG
            if DemoFeed.isEnabled, ProcessInfo.processInfo.arguments.contains("-resetSettings") {
                alarm = AnchorAlarm()
                radius = AnchorAlarm.defaultRadius
                defaults.removeObject(forKey: Self.storageKey)
            }
        #endif
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AnchorWatch.shared.becameActive() }
        }
        // A saved anchor keeps being watched after a relaunch; a saved alarm sounds again
        // on the first tick.
        if alarm.isArmed {
            startUpdates()
            refreshReadiness()
        }
    }

    var isArmed: Bool { alarm.isArmed }
    var isAlarming: Bool { alarm.state.isAlarming }
    /// Armed, but alerts may not reach the user (notifications or location not allowed).
    var isLimited: Bool { alarm.isArmed && !issues.isEmpty }

    /// Whether "drop anchor here" has usable fixes (≤ 25 m) from the last 10 s.
    var canSetAnchor: Bool {
        AnchorAlarm.anchorPoint(from: recent, at: Date().timeIntervalSince1970) != nil
    }

    // MARK: - Screen lifetime

    /// The anchor screen is showing: get positions even before an anchor is set.
    func screenAppeared() {
        viewers += 1
        startUpdates()
        refreshReadiness()
    }

    func screenDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0, !alarm.isArmed { stopUpdates() }
    }

    // MARK: - Commands

    /// Sets the anchor at the current position: the average of the usable fixes from the
    /// last 10 s. Returns false when there are none.
    @discardableResult
    func setAnchorHere() -> Bool {
        let now = Date().timeIntervalSince1970
        guard let point = AnchorAlarm.anchorPoint(from: recent, at: now),
            alarm.set(latitude: point.latitude, longitude: point.longitude, radius: radius, at: now)
        else { return false }
        lastAlert = nil
        save()
        requestNotificationPermission()
        startUpdates()
        return true
    }

    func changeRadius(_ radius: Double) {
        self.radius = radius
        if alarm.setRadius(radius) { save() }
    }

    /// Acknowledges the alarm: quiet for a minute, then it sounds again if still outside.
    func silence(at date: Date = Date()) {
        alarm.silence(at: date.timeIntervalSince1970)
        lastAlert = nil
        save()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Raises the anchor: stops watching and, unless the screen is open, location.
    func raise() {
        alarm.clear()
        lastAlert = nil
        save()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if viewers == 0 { stopUpdates() }
    }

    // MARK: - Location

    private func startUpdates() {
        guard updates == nil else { return }
        if DemoFeed.isEnabled {
            updates = Task { [weak self] in await self?.runDemoFeed() }
        } else {
            // Keeps location updates (and so this process) running in the background.
            serviceSession = CLServiceSession(authorization: .whenInUse)
            backgroundActivity = CLBackgroundActivitySession()
            updates = Task { [weak self] in
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        if Task.isCancelled { break }
                        guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
                        self?.ingest(
                            GPSFix(
                                t: location.timestamp.timeIntervalSince1970, latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                horizontalAccuracy: location.horizontalAccuracy,
                                speed: location.speed >= 0 ? location.speed : nil))
                    }
                } catch {
                    print("AnchorWatch: location updates ended: \(error)")
                }
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func stopUpdates() {
        updates?.cancel()
        updates = nil
        ticker?.cancel()
        ticker = nil
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        serviceSession?.invalidate()
        serviceSession = nil
        recent = []
    }

    private func ingest(_ fix: GPSFix) {
        position = Position(
            latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.horizontalAccuracy ?? .infinity)
        recent.append(fix)
        recent.removeAll { fix.t - $0.t > 30 }
        // AnchorAlarm checks the gap before this fix, so waking from a suspension without
        // fixes raises the GPS alarm rather than hiding it.
        apply { $0.ingest(fix) }
    }

    /// Runs a change to the alarm, then saves, alerts and reschedules notifications.
    private func apply(_ change: (inout AnchorAlarm) -> Bool) {
        let before = alarm.state
        guard change(&alarm) else {
            syncNotifications()
            return
        }
        // A new alarm alerts at once, whatever the previous one did.
        if alarm.state.isAlarming, alarm.state != before { lastAlert = nil }
        save()
        alertIfDue()
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        apply { $0.advance(to: now) }
        if alarm.state.isAlarming, lastAlert != nil, UIApplication.shared.applicationState == .active {
            // In the foreground the phone keeps buzzing until the alarm is silenced.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        alertIfDue()
    }

    private func becameActive() {
        guard alarm.isArmed else { return }
        refreshReadiness()
        tick()
    }

    // MARK: - Alerts

    private func alertIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard AnchorAlertSchedule.isAlertDue(alarm: alarm, lastAlert: lastAlert, now: now) else { return }
        let isFirst = lastAlert == nil
        lastAlert = now
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            // The system alarm sound, with vibration where the device supports it.
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        } else if isFirst, case .alarming(let reason) = alarm.state {
            // In the background the scheduled repeats take over from here.
            post(id: "anchorAlarm.now", reason: reason, at: nil)
        }
    }

    /// Keeps exactly the notifications `AnchorAlertSchedule` asks for pending.
    private func syncNotifications() {
        guard !DemoFeed.isEnabled else { return }
        let wanted = AnchorAlertSchedule.pending(for: alarm, now: Date().timeIntervalSince1970)
        let wantedIDs = Set(wanted.map(\.id))
        let stale = scheduled.keys.filter { !wantedIDs.contains($0) }
        if !stale.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
            for id in stale { scheduled[id] = nil }
        }
        for alert in wanted {
            if let current = scheduled[alert.id], abs(current - alert.fireAt) <= Self.rescheduleTolerance { continue }
            post(id: alert.id, reason: alert.reason, at: alert.fireAt)
            scheduled[alert.id] = alert.fireAt
        }
    }

    /// Posts a notification now (`at` nil) or schedules it; the same ID replaces it.
    private func post(id: String, reason: AnchorAlarm.Reason, at fireAt: Double?) {
        guard !DemoFeed.isEnabled else { return }
        let content = UNMutableNotificationContent()
        switch reason {
        case .dragging:
            content.title = "Anchor dragging"
            if fireAt == nil, let distance = alarm.distance {
                content.body =
                    "\(Int(distance.rounded())) m from the anchor, outside the \(Int(alarm.anchor?.radius ?? 0)) m circle."
            } else {
                content.body = "The boat is outside the anchor circle. Check the boat."
            }
        case .gpsLost:
            content.title = "Anchor alarm: no GPS"
            content.body = "The position has not updated for 2 minutes. Check the boat."
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = fireAt.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0 - Date().timeIntervalSince1970), repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func requestNotificationPermission() {
        guard !DemoFeed.isEnabled else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            refreshReadiness()
        }
    }

    /// Re-reads whether notifications and location are allowed.
    func refreshReadiness() {
        if DemoFeed.isEnabled {
            let denied = ProcessInfo.processInfo.arguments.contains("-demoNotificationsDenied")
            issues = AnchorReadiness.issues(
                notifications: denied ? .denied : .authorized, location: .authorizedWhenInUse,
                accuracy: .fullAccuracy)
            return
        }
        let location = locationManager.authorizationStatus
        let accuracy = locationManager.accuracyAuthorization
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            issues = AnchorReadiness.issues(
                notifications: settings.authorizationStatus, location: location, accuracy: accuracy)
        }
    }

    private func save() {
        if alarm.isArmed, let data = try? JSONEncoder().encode(alarm) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
        syncNotifications()
    }

    // MARK: - Demo

    /// UI tests: a boat holding near `DemoFeed.origin` with a little GPS noise. With
    /// `-demoAnchorDrift` it starts dragging east at 1.5 m/s 5 s after the anchor is set.
    private func runDemoFeed() async {
        var step = 0
        while !Task.isCancelled {
            step += 1
            let now = Date().timeIntervalSince1970
            var distance = Double(step % 5)  // 0–4 m of jitter around the origin
            if ProcessInfo.processInfo.arguments.contains("-demoAnchorDrift"), let setAt = alarm.anchor?.setAt {
                distance += max(0, now - setAt - 5) * 1.5
            }
            let point = Geo.destination(
                lat: DemoFeed.origin.lat, lon: DemoFeed.origin.lon, bearing: 90, distance: distance)
            ingest(GPSFix(t: now, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: 0))
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// Whether the anchor alarm can actually reach the user. Pure, for tests.
enum AnchorReadiness {
    enum Issue: String, Equatable, CaseIterable {
        /// Without notifications the alarm is silent while the phone is locked.
        case notificationsOff
        /// Without location the alarm cannot watch the position at all.
        case locationOff
        /// Approximate location is never accurate enough (≤ 25 m) to use.
        case approximateLocation

        var message: String {
            switch self {
            case .notificationsOff:
                "Notifications are off, so the alarm can't alert you while the phone is locked or in another app."
            case .locationOff:
                "Location access is off, so the alarm can't watch the boat's position."
            case .approximateLocation:
                "Precise Location is off. The alarm needs precise positions to tell a drag from a swing."
            }
        }
    }

    static func issues(
        notifications: UNAuthorizationStatus, location: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization
    ) -> [Issue] {
        var issues: [Issue] = []
        switch notifications {
        case .authorized, .provisional, .ephemeral: break
        default: issues.append(.notificationsOff)
        }
        switch location {
        case .denied, .restricted: issues.append(.locationOff)
        default: if accuracy == .reducedAccuracy { issues.append(.approximateLocation) }
        }
        return issues
    }
}
