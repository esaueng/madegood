import Foundation
import Observation
import SwiftUI
import WaterKit

/// Observable synced settings for the UI on both devices. Reads and writes go through
/// `UserSettings`; every change is sent to the other device.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var heartRateZones = HeartRateZones()
    private(set) var sports: [Sport: SportSettings] = [:]
    private(set) var lastUsed: [Sport: Double] = [:]
    private(set) var lastSessions: [Sport: UserSettings.LastSession] = [:]
    /// The start screen order the user dragged into, or nil for most recent first.
    private(set) var startOrder: [Sport]?

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: UserSettings.didChangeRemotely, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        heartRateZones = UserSettings.heartRateZones
        sports = Dictionary(uniqueKeysWithValues: Sport.allCases.map { ($0, UserSettings.settings(for: $0)) })
        lastUsed = UserSettings.lastUsed()
        startOrder = UserSettings.startOrder
        lastSessions = Sport.allCases.reduce(into: [:]) { result, sport in
            result[sport] = UserSettings.lastSession(sport)
        }
    }

    subscript(sport: Sport) -> SportSettings {
        sports[sport] ?? .standard(for: sport)
    }

    func update(_ sport: Sport, _ change: (inout SportSettings) -> Void) {
        var settings = self[sport]
        change(&settings)
        if settings.isHidden, !SportList.canHide(sport, hidden: hiddenSports.subtracting([sport])) {
            settings.isHidden = false
        }
        guard settings != self[sport] else { return }
        UserSettings.save(settings, for: sport)
        sports[sport] = settings
        RecordingTransfer.shared.pushSettings()
    }

    func updateHeartRateZones(_ zones: HeartRateZones) {
        guard zones != heartRateZones else { return }
        UserSettings.save(zones)
        heartRateZones = zones
        RecordingTransfer.shared.pushSettings()
    }

    /// A binding to one field of a sport's settings, for forms.
    func binding<Value>(_ sport: Sport, _ field: WritableKeyPath<SportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self[sport][keyPath: field] },
            set: { value in self.update(sport) { $0[keyPath: field] = value } })
    }

    var hiddenSports: Set<Sport> {
        Set(Sport.allCases.filter { self[$0].isHidden })
    }

    /// The start screen's sports: visible ones in the user's own order once they have
    /// dragged one, otherwise most recently used first. `extraUse` adds use times from
    /// elsewhere (sessions in the iPhone's history).
    func startList(extraUse: [Sport: Double] = [:]) -> [Sport] {
        if let startOrder { return SportList.ordered(custom: startOrder, hidden: hiddenSports) }
        let merged = lastUsed.merging(extraUse) { max($0, $1) }
        return SportList.ordered(lastUsed: merged, hidden: hiddenSports)
    }

    /// Keeps the visible sports in `visible`'s order from now on (hidden ones keep their
    /// places). `current` is the list as shown, so the first drag starts from recent use.
    func reorderStartList(current: [Sport], to visible: [Sport]) {
        let order = SportList.reordered(
            custom: startOrder ?? (current + Sport.allCases.filter { !current.contains($0) }), visible: visible)
        UserSettings.startOrder = order
        startOrder = order
    }

    /// Back to most recently used first.
    func useRecentStartOrder() {
        UserSettings.startOrder = nil
        startOrder = nil
    }

    func canHide(_ sport: Sport) -> Bool {
        SportList.canHide(sport, hidden: hiddenSports)
    }

    func markUsed(_ sport: Sport) {
        UserSettings.markUsed(sport)
        lastUsed = UserSettings.lastUsed()
    }

    func recordSession(_ sport: Sport, distance: Double, date: Date) {
        UserSettings.recordSession(sport, distance: distance, date: date)
        lastSessions[sport] = UserSettings.lastSession(sport)
    }

    /// Drops the sport's saved last session, after the recording it described was deleted.
    func forgetLastSession(_ sport: Sport) {
        UserSettings.forgetLastSession(sport)
        lastSessions[sport] = nil
    }
}
