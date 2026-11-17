/// Syncs per-sport settings between two devices (the phone and the watch). Each device
/// sends its whole snapshot; the receiver keeps whichever state carries the higher
/// revision.
///
/// Revisions are a hybrid logical clock in milliseconds: a new local revision is
/// `max(now, highest revision seen + 1)`, and every revision received raises "highest
/// seen". So a revision never goes backwards when a clock is corrected, and an edit made
/// after seeing another device's state always wins over it.
///
/// A snapshot without a revision comes from a device that never had settings of its own
/// (a fresh install). It never replaces or removes anything. A device that has stored
/// values always has a revision: saving assigns one, and `assignMissingRevision` gives
/// one to values that predate revisions (migrated from older builds).
///
/// Storage is reached through closures, like `SportSettings`, so this is pure and testable.
public enum SettingsSync {
    public enum Key {
        /// The revision of this device's settings, in the snapshot it sends.
        public static let revision = "settings.revision"
        /// Device-local: the highest revision seen from either device. Never sent.
        public static let highestSeen = "settings.revisionSeen"
    }

    /// Every key a snapshot carries.
    public static var snapshotKeys: [String] { SportSettings.Key.allSports + [Key.revision] }

    /// The next revision for a local change at `now` (unix time, s).
    public static func nextRevision(now: Double, highestSeen: Int64) -> Int64 {
        let millis = now.isFinite ? Int64(max(0, now * 1000).rounded(.down)) : 0
        return max(millis, highestSeen + 1)
    }

    /// Stamps a local change: call after writing the new values.
    public static func stampLocalChange(
        now: Double, reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) {
        let seen = max(revision(value(Key.highestSeen)) ?? 0, revision(value(Key.revision)) ?? 0)
        let next = nextRevision(now: now, highestSeen: seen)
        set(Key.revision, next)
        set(Key.highestSeen, next)
    }

    /// Gives a revision to stored values that have none (settings from an older build),
    /// so a fresh device's empty state cannot replace them. Does nothing when there are
    /// no values or they already have a revision. Returns whether it assigned one.
    @discardableResult
    public static func assignMissingRevision(
        now: Double, reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) -> Bool {
        guard revision(value(Key.revision)) == nil,
            SportSettings.Key.allSports.contains(where: { value($0) != nil })
        else { return false }
        stampLocalChange(now: now, reading: value, writing: set)
        return true
    }

    /// What to do with a snapshot from the other device.
    public enum Outcome: Equatable, Sendable {
        /// It was newer: its values replaced this device's.
        case applied
        /// This device's state is newer: send it back so the other side catches up.
        case keptLocalNewer
        /// Same revision, or neither side has anything: nothing to do.
        case unchanged
    }

    /// Applies `remote` if its revision is higher than this device's. Keys it lacks are
    /// removed, so "Automatic" stays automatic. Older builds' global units in `remote` are
    /// migrated first. Always raises "highest seen" to the remote revision.
    public static func apply(
        remote: [String: Any], reading value: (String) -> Any?, writing set: (String, Any?) -> Void
    ) -> Outcome {
        var remote = remote
        SportSettings.migrateLegacyUnits(reading: { remote[$0] }, writing: { remote[$0] = $1 })
        let theirs = revision(remote[Key.revision])
        let ours = revision(value(Key.revision))
        if let theirs {
            let seen = revision(value(Key.highestSeen)) ?? 0
            if theirs > seen { set(Key.highestSeen, theirs) }
        }
        guard let theirs, theirs > (ours ?? 0) else {
            // No revision (a device that never had settings) never wins.
            return (ours ?? 0) > (theirs ?? 0) ? .keptLocalNewer : .unchanged
        }
        for key in SportSettings.Key.allSports {
            set(key, remote[key])
        }
        set(Key.revision, theirs)
        return .applied
    }

    /// This device's snapshot to send.
    public static func snapshot(reading value: (String) -> Any?) -> [String: Any] {
        snapshotKeys.reduce(into: [:]) { result, key in
            if let stored = value(key) { result[key] = stored }
        }
    }

    /// A stored revision; nil when missing or not a positive number.
    static func revision(_ value: Any?) -> Int64? {
        guard let number = SportSettings.number(value), number.isFinite, number >= 1 else { return nil }
        return Int64(number)
    }
}
