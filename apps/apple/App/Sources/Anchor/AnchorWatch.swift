import AudioToolbox
import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications
import WaterKit

/// The iPhone anchor alarm (docs/PLAN.md §5): WaterKit's `AnchorAlarm` fed by its own
/// location updates, which keep running in the background for as long as the anchor is
/// set. It is independent of any recording, saved across relaunches, and alerts with
/// haptics and sound in the foreground and a notification in the background.
@MainActor
@Observable
final class AnchorWatch {
    static let shared = AnchorWatch()

    /// A position is current for this long, s; older ones are shown as stale.
    static let freshFor: TimeInterval = 15
    /// While alarming, alerts repeat this often, s.
    static let alertInterval: TimeInterval = 30
    /// How often the GPS-lost check and the foreground alarm run, s.
    static let tickInterval: Duration = .seconds(2)

    /// The latest position from any accuracy, for the screen.
    struct Position: Equatable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        var receivedUptime: TimeInterval
    }

    private static let storageKey = "anchorWatch.alarm"
    private static let radiusKey = "anchorWatch.radius"

    private(set) var alarm: AnchorAlarm
    private(set) var position: Position?
    /// The radius picked for the next anchor, m.
    var radius: Double {
        didSet { UserDefaults.standard.set(radius, forKey: Self.radiusKey) }
    }

    private var recent: [GPSFix] = []
    private var updates: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundActivity: CLBackgroundActivitySession?
    private var lastAlert: TimeInterval?
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
        // A saved anchor keeps being watched after a relaunch.
        if alarm.isArmed { startUpdates() }
    }

    var isArmed: Bool { alarm.isArmed }
    var isAlarming: Bool { alarm.state.isAlarming }

    func isFresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let position else { return false }
        return now - position.receivedUptime <= Self.freshFor
    }

    /// Whether "drop anchor here" can use the current position.
    var canSetAnchor: Bool {
        isFresh() && AnchorAlarm.anchorPoint(from: recent) != nil
    }

    // MARK: - Screen lifetime

    /// The anchor screen is showing: get positions even before an anchor is set.
    func screenAppeared() {
        viewers += 1
        startUpdates()
    }

    func screenDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0, !alarm.isArmed { stopUpdates() }
    }

    // MARK: - Commands

    /// Sets the anchor at the current position (an average of the last few seconds).
    @discardableResult
    func setAnchorHere() -> Bool {
        guard isFresh(), let newest = recent.last, let point = AnchorAlarm.anchorPoint(from: recent),
            alarm.set(latitude: point.latitude, longitude: point.longitude, radius: radius, at: newest.t)
        else { return false }
        // The newest fix gives the first distance and bearing at once.
        alarm.ingest(newest)
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
                try? await Task.sleep(for: Self.tickInterval)
                self?.tick()
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
            latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.horizontalAccuracy ?? .infinity,
            receivedUptime: ProcessInfo.processInfo.systemUptime)
        recent.append(fix)
        recent.removeAll { fix.t - $0.t > 30 }
        let wasAlarming = alarm.state.isAlarming
        if alarm.ingest(fix) {
            save()
            if alarm.state.isAlarming, !wasAlarming { alert() }
        }
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        if alarm.advance(to: now) {
            save()
            alert()
        } else if alarm.state.isAlarming, let lastAlert,
            ProcessInfo.processInfo.systemUptime - lastAlert >= Self.alertInterval
        {
            alert()
        } else if alarm.state.isAlarming, UIApplication.shared.applicationState == .active {
            // In the foreground the phone keeps buzzing until the alarm is silenced.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - Alerts

    private func alert() {
        lastAlert = ProcessInfo.processInfo.systemUptime
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            // The system alarm sound, with vibration where the device supports it.
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        } else {
            postNotification()
        }
    }

    private func postNotification() {
        guard !DemoFeed.isEnabled, case .alarming(let reason) = alarm.state else { return }
        let content = UNMutableNotificationContent()
        switch reason {
        case .dragging:
            content.title = "Anchor dragging"
            let distance = alarm.distance.map { "\(Int($0.rounded())) m" } ?? "Outside"
            content.body = "\(distance) from the anchor, outside the \(Int(alarm.anchor?.radius ?? 0)) m circle."
        case .gpsLost:
            content.title = "Anchor alarm: no GPS"
            content.body = "The position has not updated for 2 minutes. Check the boat."
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "anchorAlarm", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        guard !DemoFeed.isEnabled else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    private func save() {
        if alarm.isArmed, let data = try? JSONEncoder().encode(alarm) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
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
