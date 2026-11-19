/// Syncs per-sport settings between two devices (the phone and the watch) with a
/// last-writer-wins version per setting. Each per-sport key carries its own stamp: the
/// revision and device of the edit that last set it. A local edit stamps only the keys it
/// changes, and a return to the default is a stamped write like any other (the value is
/// removed, the stamp stays). Applying the other device's snapshot takes each key whose
/// stamp is newer than ours and keeps every other key, so edits to different settings on
/// the two devices both survive, whichever arrives first.
///
/// Revisions are a hybrid logical clock in milliseconds: a new local revision is
/// `max(now, highest revision seen + 1)`, and every revision received raises "highest
/// seen". So a revision never goes backwards when a clock is corrected, and an edit made
/// after seeing another device's state always wins over it. Two devices can still reach the
/// same revision (independent offline edits after a clock correction), so stamps compare as
/// (revision, device ID): both devices pick the same winner, and equal stamps are a no-op.
///
/// Builds before per-setting versions send one revision for the whole snapshot and apply a
/// newer snapshot by writing every key they know. A snapshot from such a build stamps each
/// key it knows (`legacyKnownKeys` plus any per-sport key it carries) with its revision. It
/// wins those keys only when it is newer than every stamp here, because that build takes
/// our whole state whenever ours is newer; anything else would leave the two devices
/// different. Every snapshot also carries those builds' fields: the values and, as the
/// revision, the newest stamp here.
///
/// Storage is reached through closures, like `SportSettings`, so this is pure and testable.
public enum SettingsSync {
    public enum Key {
        /// The stamp of every per-sport key that has one: a dictionary from key to
        /// `[revision, device]`. Stored on each device and sent in its snapshot.
        public static let stamps = "settings.stamps"
        /// Builds before per-setting versions: the revision of the whole snapshot. Sent as
        /// the newest stamp; stored only by those builds (migrated, then removed).
        public static let revision = "settings.revision"
        /// Builds before per-setting versions: the ID of the device that made `revision`.
        public static let revisionDevice = "settings.revisionDevice"
        /// Device-local: the highest revision seen from either device. Never sent.
        public static let highestSeen = "settings.revisionSeen"
        /// Device-local: this device's stable random ID, made once. Never sent on its own.
        public static let deviceID = "settings.deviceID"
    }

    /// Every stored key that belongs to synced settings, for resets.
    public static var storedKeys: [String] {
        SportSettings.Key.allSports + [Key.stamps, Key.revision, Key.revisionDevice]
    }

    /// A setting's position in the order both devices agree on.
    public struct Stamp: Comparable, Hashable, Sendable {
        public var revision: Int64
        public var device: String

        public init(revision: Int64, device: String) {
            self.revision = revision
            self.device = device
        }

        public static func < (a: Stamp, b: Stamp) -> Bool {
            (a.revision, a.device) < (b.revision, b.device)
        }
    }

    /// What applying a snapshot from the other device did.
    public struct Outcome: Equatable, Sendable {
        /// A value here changed.
        public var changed: Bool
        /// This device holds a setting newer than the snapshot's: send ours back.
        public var replyNeeded: Bool

        public init(changed: Bool, replyNeeded: Bool) {
            self.changed = changed
            self.replyNeeded = replyNeeded
        }

        public static let unchanged = Outcome(changed: false, replyNeeded: false)
        public static let applied = Outcome(changed: true, replyNeeded: false)
        public static let keptLocalNewer = Outcome(changed: false, replyNeeded: true)
        public static let appliedAndKeptLocalNewer = Outcome(changed: true, replyNeeded: true)
    }

    /// The per-sport keys a snapshot without stamps is assumed to know: those of the first
    /// per-sport settings (PR #39): speed and distance unit, first screen, auto-pause, save
    /// workout, distance alert, countdown and hidden, for every sport. Builds that also know
    /// the Action button (#58) or the fuel estimate (#60) are covered for each such key they
    /// carry; one they leave at its default is not sent, so it is not applied.
    public static var legacyKnownKeys: Set<String> {
        typealias K = SportSettings.Key
        return Set(
            Sport.allCases.flatMap { sport in
                [
                    K.speedUnit(sport), K.distanceUnit(sport), K.firstScreen(sport), K.autoPause(sport),
                    K.saveWorkout(sport), K.distanceAlert(sport), K.countdown(sport), K.hidden(sport),
                ]
            })
    }

    /// The next revision for a local change at `now` (unix time, s).
    public static func nextRevision(now: Double, highestSeen: Int64) -> Int64 {
        let millis = now.isFinite ? Int64(max(0, now * 1000).rounded(.down)) : 0
        return max(millis, highestSeen + 1)
    }

    // MARK: Local changes

    /// Stores a sport's settings as a local edit by `device` (this device's ID) at `now`:
    /// every key whose value changes gets one new stamp. Keys left as they were keep theirs.
    public static func save(
        _ settings: SportSettings, for sport: Sport, now: Double, device: String,
        reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) {
        let keys = SportSettings.Key.all(sport)
        let before = keys.map { value($0) }
        settings.write(sport: sport, to: set)
        let changed = zip(keys, before).filter { !sameValue($0.1, value($0.0)) }.map(\.0)
        guard !changed.isEmpty else { return }
        var stamps = storedStamps(value)
        let seen = max(revision(value(Key.highestSeen)) ?? 0, stamps.values.map(\.revision).max() ?? 0)
        let stamp = Stamp(revision: nextRevision(now: now, highestSeen: seen), device: device)
        for key in changed { stamps[key] = stamp }
        set(Key.stamps, encode(stamps))
        set(Key.highestSeen, stamp.revision)
    }

    /// Gives stamps to settings stored by a build before per-setting versions. Their
    /// revision (or, for values from before revisions, a new one at `now`) stamps every key
    /// that build knew, values and defaults alike, plus any newer key it stored. Does
    /// nothing once stamps exist. Returns whether it stamped anything.
    @discardableResult
    public static func migrateToKeyStamps(
        now: Double, device: String, reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) -> Bool {
        guard value(Key.stamps) == nil else { return false }
        let stored = SportSettings.Key.allSports.filter { value($0) != nil }
        let seen = revision(value(Key.highestSeen)) ?? 0
        var stamp: Stamp?
        if let legacy = revision(value(Key.revision)) {
            stamp = Stamp(revision: legacy, device: value(Key.revisionDevice) as? String ?? device)
        } else if !stored.isEmpty {
            stamp = Stamp(revision: nextRevision(now: now, highestSeen: seen), device: device)
        }
        var stamps: [String: Stamp] = [:]
        if let stamp {
            for key in legacyKnownKeys.union(stored) { stamps[key] = stamp }
            if stamp.revision > seen { set(Key.highestSeen, stamp.revision) }
        }
        set(Key.stamps, encode(stamps))
        set(Key.revision, nil)
        set(Key.revisionDevice, nil)
        return stamp != nil
    }

    // MARK: Sync

    /// This device's snapshot to send: its stored values and their stamps, plus, for builds
    /// before per-setting versions, the newest stamp as the snapshot's revision.
    public static func snapshot(reading value: (String) -> Any?) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in SportSettings.Key.allSports {
            if let stored = value(key) { result[key] = stored }
        }
        let stamps = storedStamps(value)
        result[Key.stamps] = encode(stamps)
        if let newest = stamps.values.max() {
            result[Key.revision] = newest.revision
            result[Key.revisionDevice] = newest.device
        }
        return result
    }

    /// Applies a snapshot from the other device: each setting whose stamp is newer than
    /// ours is taken, every other setting is kept. Always raises "highest seen".
    public static func apply(
        remote: [String: Any], reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) -> Outcome {
        var remote = remote
        SportSettings.migrateLegacyUnits(reading: { remote[$0] }, writing: { remote[$0] = $1 })
        var stamps = storedStamps(value)
        let theirs: [String: Stamp]
        let isLegacy = remote[Key.stamps] == nil
        if isLegacy {
            // One revision for every key the older build knows.
            guard let legacy = revision(remote[Key.revision]) else {
                // No revision (a device that never had settings) never wins.
                return stamps.isEmpty ? .unchanged : .keptLocalNewer
            }
            let stamp = Stamp(revision: legacy, device: remote[Key.revisionDevice] as? String ?? "")
            raiseHighestSeen(stamp.revision, reading: value, writing: set)
            // That build takes our whole state whenever ours is newer, so it wins only when
            // it is newer than everything here.
            if let newest = stamps.values.max(), stamp <= newest {
                return stamp == newest ? .unchanged : .keptLocalNewer
            }
            let all = Set(SportSettings.Key.allSports)
            let known = legacyKnownKeys.union(remote.keys.filter(all.contains))
            theirs = Dictionary(uniqueKeysWithValues: known.map { ($0, stamp) })
        } else {
            theirs = decode(remote[Key.stamps])
            if let newest = theirs.values.map(\.revision).max() {
                raiseHighestSeen(newest, reading: value, writing: set)
            }
        }

        var changed = false
        var stampsChanged = false
        for key in SportSettings.Key.allSports {
            guard let stamp = theirs[key], stamps[key].map({ stamp > $0 }) ?? true else { continue }
            if !sameValue(value(key), remote[key]) {
                set(key, remote[key])
                changed = true
            }
            stamps[key] = stamp
            stampsChanged = true
        }
        if stampsChanged { set(Key.stamps, encode(stamps)) }

        // Reply when this device holds a setting newer than the one received, or one the
        // sender has no stamp for. An older build that won above was newer than everything
        // here, so it needs nothing back.
        let replyNeeded =
            !isLegacy && stamps.contains { key, stamp in theirs[key].map { stamp > $0 } ?? true }
        return Outcome(changed: changed, replyNeeded: replyNeeded)
    }

    // MARK: Values and stamps

    /// Whether two stored values are the same setting. Values may arrive as numbers, Bools
    /// or strings of different types after a round trip through the platform's store.
    static func sameValue(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        default: break
        }
        if let x = a as? String, let y = b as? String { return x == y }
        func scalar(_ value: Any?) -> Double? {
            if value is String { return nil }
            return SportSettings.number(value) ?? SportSettings.bool(value).map { $0 ? 1 : 0 }
        }
        if let x = scalar(a), let y = scalar(b) { return x == y }
        return false
    }

    /// This device's stored stamps.
    static func storedStamps(_ value: (String) -> Any?) -> [String: Stamp] {
        decode(value(Key.stamps))
    }

    /// Stamps from a stored or received dictionary; malformed entries are skipped.
    static func decode(_ raw: Any?) -> [String: Stamp] {
        guard let entries = raw as? [String: Any] else { return [:] }
        var stamps: [String: Stamp] = [:]
        for (key, entry) in entries {
            guard let pair = entry as? [Any], pair.count == 2, let revision = revision(pair[0]),
                let device = pair[1] as? String
            else { continue }
            stamps[key] = Stamp(revision: revision, device: device)
        }
        return stamps
    }

    /// Stamps as a property-list dictionary, for storage and WatchConnectivity.
    static func encode(_ stamps: [String: Stamp]) -> [String: Any] {
        stamps.mapValues { [$0.revision, $0.device] as [Any] }
    }

    private static func raiseHighestSeen(
        _ revision: Int64, reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) {
        if revision > (Self.revision(value(Key.highestSeen)) ?? 0) { set(Key.highestSeen, revision) }
    }

    /// A stored revision; nil when missing or not a positive number.
    static func revision(_ value: Any?) -> Int64? {
        guard let number = SportSettings.number(value), number.isFinite, number >= 1 else { return nil }
        return Int64(number)
    }
}
