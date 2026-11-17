import Foundation
import WaterKit

/// The user's preferences, in UserDefaults on each device: per-sport settings
/// (`SportSettings`, edited on either device and kept in sync through
/// `RecordingTransfer`) plus device-local history used to order the start screen.
enum UserSettings {
    enum Key {
        /// When the per-sport settings last changed (unix time), for last-writer-wins
        /// syncing between the phone and the watch.
        static let updatedAt = "settings.updatedAt"
        /// Device-local: when each sport was last started, and its last session.
        static func lastUsed(_ sport: Sport) -> String { "history.lastUsed.\(sport.rawValue)" }
        static func lastDistance(_ sport: Sport) -> String { "history.lastDistance.\(sport.rawValue)" }
        static func lastDate(_ sport: Sport) -> String { "history.lastDate.\(sport.rawValue)" }
        /// Older builds remembered the last sport here (watch) and the selected one (iPhone).
        static let legacyWatchLastSport = "watch.lastSport"
        static let legacyPhoneSport = "recorder.sport"
    }

    /// Posted on the main queue when settings arrive from the other device.
    static let didChangeRemotely = Notification.Name("UserSettings.didChangeRemotely")

    static var defaults: UserDefaults { .standard }

    // MARK: Per sport

    static func settings(for sport: Sport) -> SportSettings {
        SportSettings(sport: sport) { defaults.object(forKey: $0) }
    }

    /// Stores a sport's settings and stamps the change time.
    static func save(_ settings: SportSettings, for sport: Sport, at date: Date = Date()) {
        settings.write(sport: sport) { key, value in
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set(date.timeIntervalSince1970, forKey: Key.updatedAt)
    }

    static func display(for sport: Sport) -> LiveDisplay {
        let settings = settings(for: sport)
        return LiveDisplay(
            speed: settings.resolvedSpeedUnit(for: sport), distance: settings.resolvedDistanceUnit(for: sport))
    }

    /// Whether sessions of this sport are saved to Apple Health (off for motorboating
    /// unless the user turns it on, PLAN §5).
    static func savesWorkout(for sport: Sport) -> Bool {
        settings(for: sport).savesWorkout
    }

    /// The sport's engine profile with the user's auto-pause choice applied.
    static func profile(for sport: Sport) -> SportProfile {
        var profile = SportProfile.standard(for: sport)
        profile.autoPause.enabled = settings(for: sport).autoPause
        return profile
    }

    static var hiddenSports: Set<Sport> {
        Set(Sport.allCases.filter { settings(for: $0).isHidden })
    }

    // MARK: Sync

    /// Every per-sport setting plus its change time, to send to the other device.
    static func snapshot() -> [String: Any] {
        var result: [String: Any] = [:]
        for key in SportSettings.Key.allSports + [Key.updatedAt] {
            if let value = defaults.object(forKey: key) { result[key] = value }
        }
        return result
    }

    /// Applies settings from the other device if they are newer than this device's.
    /// Keys missing from the snapshot are removed, so "Automatic" stays automatic.
    /// Returns whether anything was applied.
    @discardableResult
    static func apply(_ snapshot: [String: Any]) -> Bool {
        // Older builds sent units for every sport and no time stamp.
        var snapshot = snapshot
        SportSettings.migrateLegacyUnits(reading: { snapshot[$0] }, writing: { snapshot[$0] = $1 })
        let theirs = snapshot[Key.updatedAt] as? Double ?? 0
        let ours = defaults.object(forKey: Key.updatedAt) as? Double ?? -1
        guard theirs > ours else { return false }
        for key in SportSettings.Key.allSports {
            if let value = snapshot[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(theirs, forKey: Key.updatedAt)
        return true
    }

    /// Moves settings from older builds to the current keys. Run at launch.
    static func migrate() {
        SportSettings.migrateLegacyUnits(
            reading: { defaults.object(forKey: $0) },
            writing: { key, value in
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            })
        for key in [Key.legacyWatchLastSport, Key.legacyPhoneSport] {
            if let raw = defaults.string(forKey: key), let sport = Sport(rawValue: raw),
                defaults.object(forKey: Key.lastUsed(sport)) == nil
            {
                defaults.set(1.0, forKey: Key.lastUsed(sport))  // used, but before anything newer
            }
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Device-local history

    struct LastSession: Equatable {
        var distance: Double
        var date: Date
    }

    static func lastUsed() -> [Sport: Double] {
        Sport.allCases.reduce(into: [:]) { result, sport in
            if let time = defaults.object(forKey: Key.lastUsed(sport)) as? Double { result[sport] = time }
        }
    }

    static func markUsed(_ sport: Sport, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.lastUsed(sport))
    }

    static func lastSession(_ sport: Sport) -> LastSession? {
        guard let distance = defaults.object(forKey: Key.lastDistance(sport)) as? Double,
            let time = defaults.object(forKey: Key.lastDate(sport)) as? Double
        else { return nil }
        return LastSession(distance: distance, date: Date(timeIntervalSince1970: time))
    }

    static func recordSession(_ sport: Sport, distance: Double, date: Date) {
        defaults.set(distance, forKey: Key.lastDistance(sport))
        defaults.set(date.timeIntervalSince1970, forKey: Key.lastDate(sport))
    }

    /// Debug builds launched with `-resetSettings` start from defaults, so UI tests do not
    /// depend on what an earlier run changed.
    static func resetIfRequested() {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-resetSettings") else { return }
            var keys = SportSettings.Key.allSports + [Key.updatedAt]
            for sport in Sport.allCases {
                keys += [Key.lastUsed(sport), Key.lastDistance(sport), Key.lastDate(sport)]
            }
            for key in keys { defaults.removeObject(forKey: key) }
        #endif
    }
}
