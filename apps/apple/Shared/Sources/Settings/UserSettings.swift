import Foundation
import WaterKit

/// The user's preferences, in UserDefaults on each device: per-sport settings
/// (`SportSettings`, edited on either device and kept in sync through
/// `RecordingTransfer` and `SettingsSync`) plus device-local history used to order the
/// start screen.
///
/// Every write to the synced settings runs on the main actor (local edits, incoming
/// snapshots, migration), so a revision check and the keys it writes are never
/// interleaved with another write. Reads are safe anywhere.
enum UserSettings {
    enum Key {
        /// Device-local: when each sport was last started, and its last session.
        static func lastUsed(_ sport: Sport) -> String { "history.lastUsed.\(sport.rawValue)" }
        static func lastDistance(_ sport: Sport) -> String { "history.lastDistance.\(sport.rawValue)" }
        static func lastDate(_ sport: Sport) -> String { "history.lastDate.\(sport.rawValue)" }
        /// Older builds remembered the last sport here (watch) and the selected one (iPhone).
        static let legacyWatchLastSport = "watch.lastSport"
        static let legacyPhoneSport = "recorder.sport"
        /// iPhone only, device-local: System, Light or Dark (`Appearance`).
        static let appearance = "app.appearance"
        /// iPhone only, device-local: the start screen's sports in the order the user
        /// dragged them (raw values); absent for most recently used first.
        static let startOrder = "start.order"
        /// iPhone only, device-local: whether the start screen shows local conditions.
        static let localWeather = "weather.enabled"
        /// iPhone only, device-local: the last conditions fetched, for a quick first draw.
        static let lastWeather = "weather.last"
    }

    /// Posted on the main queue when settings arrive from the other device.
    static let didChangeRemotely = Notification.Name("UserSettings.didChangeRemotely")

    static var defaults: UserDefaults { .standard }

    // MARK: Per sport

    static func settings(for sport: Sport) -> SportSettings {
        SportSettings(sport: sport) { defaults.object(forKey: $0) }
    }

    /// Stores a sport's settings and stamps each changed setting with a new revision.
    @MainActor
    static func save(_ settings: SportSettings, for sport: Sport, at date: Date = Date()) {
        SettingsSync.save(
            settings, for: sport, now: date.timeIntervalSince1970, device: deviceID, reading: read, writing: write)
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

    /// The sport's analysis profile with the user's settings applied.
    static func profile(for sport: Sport) -> SportProfile {
        var profile = SportProfile.standard(for: sport)
        let settings = settings(for: sport)
        profile.autoPause.enabled = settings.autoPause
        profile.planingSpeedThreshold = settings.planingSpeedThreshold
        return profile
    }

    static var hiddenSports: Set<Sport> {
        Set(Sport.allCases.filter { settings(for: $0).isHidden })
    }

    // MARK: Sync

    /// This device's per-sport settings and their stamps, to send to the other device.
    /// Main actor only, so it never mixes values from before a save with the revision
    /// from after it.
    @MainActor
    static func snapshot() -> [String: Any] {
        SettingsSync.snapshot(reading: read)
    }

    /// Applies each setting from the other device whose stamp is newer (`SettingsSync`).
    @MainActor
    static func apply(_ snapshot: [String: Any], at date: Date = Date()) -> SettingsSync.Outcome {
        SettingsSync.apply(
            remote: snapshot, now: date.timeIntervalSince1970, device: deviceID, reading: read, writing: write)
    }

    /// Moves settings from older builds to the current keys and gives them per-setting
    /// stamps (from their snapshot revision, or a new one for values from before
    /// revisions), so a fresh companion's empty settings never replace them. Run at launch,
    /// before syncing.
    @MainActor
    static func migrate(now: Date = Date()) {
        SportSettings.migrateLegacyUnits(reading: read, writing: write)
        SettingsSync.migrateToKeyStamps(
            now: now.timeIntervalSince1970, device: deviceID, reading: read, writing: write)
        for key in [Key.legacyWatchLastSport, Key.legacyPhoneSport] {
            if let raw = defaults.string(forKey: key), let sport = Sport(rawValue: raw),
                defaults.object(forKey: Key.lastUsed(sport)) == nil
            {
                defaults.set(1.0, forKey: Key.lastUsed(sport))  // used, but before anything newer
            }
            defaults.removeObject(forKey: key)
        }
    }

    /// A stable random ID for this device, made once; breaks ties between revisions.
    @MainActor
    static var deviceID: String {
        if let id = defaults.string(forKey: SettingsSync.Key.deviceID), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: SettingsSync.Key.deviceID)
        return id
    }

    private static func read(_ key: String) -> Any? {
        defaults.object(forKey: key)
    }

    private static func write(_ key: String, _ value: Any?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: Device-local start order

    /// The order the user dragged the start screen into, or nil for most recent first.
    static var startOrder: [Sport]? {
        get {
            (defaults.array(forKey: Key.startOrder) as? [String]).map { $0.compactMap(Sport.init(rawValue:)) }
        }
        set {
            if let newValue { defaults.set(newValue.map(\.rawValue), forKey: Key.startOrder) }
            else { defaults.removeObject(forKey: Key.startOrder) }
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
    @MainActor
    static func resetIfRequested() {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-resetSettings") else { return }
            var keys =
                SettingsSync.storedKeys + [
                    SettingsSync.Key.highestSeen, Key.appearance, Key.startOrder, Key.localWeather, Key.lastWeather,
                ]
            for sport in Sport.allCases {
                keys += [Key.lastUsed(sport), Key.lastDistance(sport), Key.lastDate(sport)]
            }
            for key in keys { defaults.removeObject(forKey: key) }
        #endif
    }
}
