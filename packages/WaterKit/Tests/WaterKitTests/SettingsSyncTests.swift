import Testing

@testable import WaterKit

/// Two-way settings sync with a version per setting (PR #39 reviews, PR #62 reviews).
@Suite struct SettingsSyncTests {
    /// A device running a build with per-setting versions.
    final class Device {
        let id: String
        var values: [String: Any] = [:]

        init(id: String = "device-\(Int.random(in: 0..<1_000_000))") {
            self.id = id
        }

        func read(_ key: String) -> Any? { values[key] }
        func write(_ key: String, _ value: Any?) { values[key] = value }

        var stamps: [String: SettingsSync.Stamp] { SettingsSync.storedStamps(read) }
        func stamp(_ key: String) -> SettingsSync.Stamp? { stamps[key] }
        var snapshot: [String: Any] { SettingsSync.snapshot(reading: read) }
        var highestSeen: Int64? { SettingsSync.revision(values[SettingsSync.Key.highestSeen]) }

        /// A local edit, as `UserSettings.save` does it.
        func edit(_ sport: Sport, at now: Double, _ change: (inout SportSettings) -> Void) {
            var settings = SportSettings(sport: sport, reading: read)
            change(&settings)
            SettingsSync.save(settings, for: sport, now: now, device: id, reading: read, writing: write)
        }

        func receive(_ snapshot: [String: Any], at now: Double = 0) -> SettingsSync.Outcome {
            SettingsSync.apply(remote: snapshot, now: now, device: id, reading: read, writing: write)
        }

        func settings(_ sport: Sport) -> SportSettings { SportSettings(sport: sport, reading: read) }
    }

    /// A shipped build before per-setting versions: one revision for the whole state; its
    /// snapshot carries the keys it knows and that revision; a newer snapshot replaces
    /// every key it knows.
    final class LegacyBuild {
        let id: String
        var values: [String: Any] = [:]
        let known: Set<String>

        init(id: String = "legacy-\(Int.random(in: 0..<1_000_000))", alsoKnows: [String] = []) {
            self.id = id
            known = SettingsSync.legacyKnownKeys.union(alsoKnows)
        }

        func read(_ key: String) -> Any? { values[key] }
        func write(_ key: String, _ value: Any?) { values[key] = value }

        var revision: Int64? { SettingsSync.revision(values[SettingsSync.Key.revision]) }
        var stamp: SettingsSync.Stamp? {
            revision.map { .init(revision: $0, device: values[SettingsSync.Key.revisionDevice] as? String ?? "") }
        }

        var snapshot: [String: Any] {
            values.filter {
                known.contains($0.key) || $0.key == SettingsSync.Key.revision
                    || $0.key == SettingsSync.Key.revisionDevice
            }
        }

        /// A local edit: write the value, then stamp the whole state.
        func edit(_ key: String, _ value: Any?, at now: Double) {
            write(key, value)
            let seen = max(
                SettingsSync.revision(values[SettingsSync.Key.highestSeen]) ?? 0, revision ?? 0)
            let next = SettingsSync.nextRevision(now: now, highestSeen: seen)
            values[SettingsSync.Key.revision] = next
            values[SettingsSync.Key.revisionDevice] = id
            values[SettingsSync.Key.highestSeen] = next
        }

        /// The shipped apply: a newer (revision, device) replaces every key it knows.
        @discardableResult
        func receive(_ remote: [String: Any]) -> Bool {
            guard let theirs = SettingsSync.revision(remote[SettingsSync.Key.revision]) else { return false }
            let theirStamp = SettingsSync.Stamp(
                revision: theirs, device: remote[SettingsSync.Key.revisionDevice] as? String ?? "")
            if theirs > SettingsSync.revision(values[SettingsSync.Key.highestSeen]) ?? 0 {
                values[SettingsSync.Key.highestSeen] = theirs
            }
            if let stamp, theirStamp <= stamp { return false }
            for key in known { write(key, remote[key]) }
            values[SettingsSync.Key.revision] = theirs
            values[SettingsSync.Key.revisionDevice] = theirStamp.device
            return true
        }

        func settings(_ sport: Sport) -> SportSettings { SportSettings(sport: sport, reading: read) }

        /// The same device after installing a build with per-setting versions.
        func upgraded(at now: Double) -> Device {
            let device = Device(id: id)
            device.values = values
            SettingsSync.migrateToKeyStamps(now: now, device: id, reading: device.read, writing: device.write)
            return device
        }
    }

    // MARK: Local edits and migration

    /// An edit stamps only the settings it changes; saving the same values stamps nothing.
    @Test func anEditStampsOnlyWhatChanged() {
        let device = Device(id: "d")
        device.edit(.sailing, at: 10) {
            $0.countdownMinutes = 5
            $0.actionButton = .mark
        }
        device.edit(.sailing, at: 20) { $0.countdownMinutes = 3 }
        #expect(device.stamp(SportSettings.Key.countdown(.sailing)) == .init(revision: 20_000, device: "d"))
        #expect(device.stamp(SportSettings.Key.actionButton(.sailing)) == .init(revision: 10_000, device: "d"))
        #expect(device.stamps.count == 2)

        device.edit(.sailing, at: 30) { _ in }
        #expect(device.stamps.count == 2)
        #expect(device.highestSeen == 20_000)
    }

    /// Returning to the default is a stamped write: the value goes, the stamp stays.
    @Test func resetToDefaultIsAStampedWrite() {
        let device = Device(id: "d")
        device.edit(.sup, at: 10) { $0.distanceAlert = 1 }
        device.edit(.sup, at: 20) { $0 = .standard(for: .sup) }
        #expect(device.values[SportSettings.Key.distanceAlert(.sup)] == nil)
        #expect(device.stamp(SportSettings.Key.distanceAlert(.sup)) == .init(revision: 20_000, device: "d"))
    }

    /// Settings from a build with one revision get that revision as the stamp of every
    /// stored value; defaults stay unstamped, and the old fields go.
    @Test func migrationStampsWithTheSnapshotRevision() {
        let legacy = LegacyBuild(id: "w", alsoKnows: [SportSettings.Key.actionButton(.kayak)])
        legacy.edit(SportSettings.Key.actionButton(.kayak), "mark", at: 7)
        let device = legacy.upgraded(at: 100)
        let stamp = SettingsSync.Stamp(revision: 7_000, device: "w")
        #expect(device.stamp(SportSettings.Key.actionButton(.kayak)) == stamp)
        #expect(device.stamp(SportSettings.Key.countdown(.canoe)) == nil)  // a default
        #expect(device.stamp(SportSettings.Key.fuelBurn(.motorboating)) == nil)  // unknown, unset
        #expect(device.values[SettingsSync.Key.revision] == nil)
        #expect(device.values[SettingsSync.Key.revisionDevice] == nil)
        // Once is enough.
        #expect(!SettingsSync.migrateToKeyStamps(now: 200, device: "w", reading: device.read, writing: device.write))
        #expect(device.stamp(SportSettings.Key.actionButton(.kayak)) == stamp)
    }

    /// Finding 1 of #39: values from before revisions get a stamp, so a freshly installed
    /// companion's empty snapshot cannot replace them.
    @Test func freshCompanionNeverWipesMigratedSettings() {
        let upgraded = Device()
        upgraded.values[SportSettings.Key.legacySpeedUnit] = "mph"
        upgraded.values[SportSettings.Key.autoPause(.kayak)] = false
        SportSettings.migrateLegacyUnits(reading: upgraded.read, writing: upgraded.write)
        #expect(
            SettingsSync.migrateToKeyStamps(
                now: 1_000, device: upgraded.id, reading: upgraded.read, writing: upgraded.write))
        #expect(upgraded.stamp(SportSettings.Key.autoPause(.kayak))?.revision == 1_000_000)

        let fresh = Device()
        #expect(
            !SettingsSync.migrateToKeyStamps(now: 2_000, device: fresh.id, reading: fresh.read, writing: fresh.write))
        #expect(upgraded.receive(fresh.snapshot) == .keptLocalNewer)
        #expect(upgraded.settings(.sailing).speedUnit == .milesPerHour)

        #expect(fresh.receive(upgraded.snapshot) == .applied)
        #expect(fresh.settings(.sailing).speedUnit == .milesPerHour)
        #expect(!fresh.settings(.kayak).autoPause)
    }

    /// Review of the rework, finding 2: both devices had explicit values in different
    /// settings before upgrading. Whichever migrates later, neither one's defaults erase
    /// the other's values.
    @Test func migratingBothDevicesKeepsBothExplicitValues() {
        let phoneLegacy = LegacyBuild(id: "phone")
        let watchLegacy = LegacyBuild(id: "watch")
        phoneLegacy.edit(SportSettings.Key.distanceUnit(.kayak), "mi", at: 10)
        watchLegacy.edit(SportSettings.Key.speedUnit(.kayak), "mph", at: 20)
        // Offline: neither has seen the other's edit.
        let phone = phoneLegacy.upgraded(at: 30)
        let watch = watchLegacy.upgraded(at: 40)
        let fromPhone = phone.snapshot
        let fromWatch = watch.snapshot
        #expect(phone.receive(fromWatch).changed)
        #expect(watch.receive(fromPhone).changed)
        #expect(watch.receive(phone.snapshot) == .unchanged)
        #expect(phone.receive(watch.snapshot) == .unchanged)
        for device in [phone, watch] {
            #expect(device.settings(.kayak).distanceUnit == .statuteMiles)
            #expect(device.settings(.kayak).speedUnit == .milesPerHour)
        }
    }

    /// Review of the rework, finding 3: crossing hide edits can hide every sport. Both
    /// devices show the same sport again (the oldest hide) and converge.
    @Test func crossingHidesNeverLeaveEverySportHidden() {
        let phone = Device(id: "phone")
        let watch = Device(id: "watch")
        let others = Sport.allCases.filter { $0 != .sailing && $0 != .kayak }
        for (index, sport) in others.enumerated() {
            phone.edit(sport, at: Double(10 + index)) { $0.isHidden = true }
        }
        #expect(watch.receive(phone.snapshot) == .applied)
        // Offline, each hides one of the two visible sports; each is allowed locally.
        #expect(SportList.canHide(.sailing, hidden: Set(others)))
        phone.edit(.sailing, at: 100) { $0.isHidden = true }
        watch.edit(.kayak, at: 101) { $0.isHidden = true }
        let fromPhone = phone.snapshot
        let fromWatch = watch.snapshot
        #expect(phone.receive(fromWatch, at: 102) == .appliedAndKeptLocalNewer)
        #expect(watch.receive(fromPhone, at: 103) == .appliedAndKeptLocalNewer)
        // The oldest hide is the first of `others`; both show it again.
        let shown = others[0]
        #expect(!phone.settings(shown).isHidden)
        #expect(!watch.settings(shown).isHidden)
        // Their replies settle on one stamp for it, and nothing more is sent.
        _ = phone.receive(watch.snapshot, at: 104)
        _ = watch.receive(phone.snapshot, at: 105)
        #expect(phone.receive(watch.snapshot) == .unchanged)
        #expect(watch.receive(phone.snapshot) == .unchanged)
        for device in [phone, watch] {
            #expect(Sport.allCases.filter { !device.settings($0).isHidden } == [shown])
            #expect(device.stamp(SportSettings.Key.hidden(shown)) == phone.stamp(SportSettings.Key.hidden(shown)))
        }
    }

    /// With no stamps on any hide (migrated values), the usual sport order decides.
    @Test func allHiddenWithoutStampsShowsTheFirstSport() {
        let device = Device(id: "d")
        for sport in Sport.allCases { device.values[SportSettings.Key.hidden(sport)] = true }
        #expect(SettingsSync.sportToShowWhenAllHidden(stamps: [:], reading: device.read) == Sport.allCases[0])
        device.values[SportSettings.Key.hidden(.sup)] = nil
        #expect(SettingsSync.sportToShowWhenAllHidden(stamps: [:], reading: device.read) == nil)
    }

    /// An old-format snapshot with no or junk revision never changes anything.
    @Test func snapshotWithoutARevisionNeverRemovesValues() {
        let device = Device()
        device.edit(.sup, at: 500) { $0.countdownMinutes = 3 }
        for junk: Any in [0, -5, "abc", Double.nan] {
            #expect(device.receive([SettingsSync.Key.revision: junk]) == .keptLocalNewer)
            #expect(device.settings(.sup).countdownMinutes == 3)
        }
        let empty = Device()
        #expect(empty.receive([:]) == .unchanged)
        #expect(empty.values.isEmpty)
    }

    // MARK: Clocks and ties

    @Test func nextRevisionIsMonotonic() {
        #expect(SettingsSync.nextRevision(now: 2, highestSeen: 0) == 2_000)
        #expect(SettingsSync.nextRevision(now: 2, highestSeen: 5_000) == 5_001)
        #expect(SettingsSync.nextRevision(now: .nan, highestSeen: 7) == 8)
    }

    @Test func stampsCompareRevisionThenDevice() {
        typealias Stamp = SettingsSync.Stamp
        #expect(Stamp(revision: 2, device: "A") > Stamp(revision: 1, device: "Z"))
        #expect(Stamp(revision: 2, device: "B") > Stamp(revision: 2, device: "A"))
        #expect(Stamp(revision: 2, device: "A") == Stamp(revision: 2, device: "A"))
    }

    /// A device whose clock ran ahead and was then corrected still makes edits that beat
    /// what it has seen.
    @Test func revisionsSurviveAClockCorrection() {
        let phone = Device()
        let watch = Device()
        watch.edit(.sailing, at: 10_000 + 3_600) { $0.countdownMinutes = 5 }  // clock an hour ahead
        #expect(phone.receive(watch.snapshot) == .applied)
        phone.edit(.sailing, at: 10_060) { $0.countdownMinutes = 1 }
        #expect(watch.receive(phone.snapshot) == .applied)
        #expect(watch.settings(.sailing).countdownMinutes == 1)
        watch.edit(.sailing, at: 10_120) { $0.countdownMinutes = 3 }  // clock corrected
        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(phone.settings(.sailing).countdownMinutes == 3)
    }

    /// A received stamp from a clock that ran ahead raises the floor for later edits.
    @Test func acceptedRevisionRaisesTheFloor() {
        let ahead = Device(id: "x")
        ahead.edit(.kayak, at: 50_000) { $0.autoPause = false }
        let device = Device()
        #expect(device.receive(ahead.snapshot) == .applied)
        device.edit(.kayak, at: 100) { $0.countdownMinutes = 1 }
        #expect(device.stamp(SportSettings.Key.countdown(.kayak))?.revision == 50_000_001)
    }

    /// Two edits of one setting at the same revision: both devices pick the higher device
    /// ID and stop replying.
    @Test func equalRevisionsConvergeOnOneWinner() {
        let a = Device(id: "A")
        let b = Device(id: "B")
        let ahead = Device(id: "C")
        ahead.edit(.sailing, at: 9_000) { $0.firstScreen = .map }
        #expect(a.receive(ahead.snapshot) == .applied)
        #expect(b.receive(ahead.snapshot) == .applied)
        a.edit(.sailing, at: 10) { $0.countdownMinutes = 1 }
        b.edit(.sailing, at: 10) { $0.countdownMinutes = 5 }

        let fromA = a.snapshot
        let fromB = b.snapshot
        #expect(a.receive(fromB) == .applied)
        #expect(b.receive(fromA) == .keptLocalNewer)
        #expect(a.receive(b.snapshot) == .unchanged)
        #expect(b.receive(a.snapshot) == .unchanged)
        #expect(a.settings(.sailing).countdownMinutes == 5)
        #expect(b.settings(.sailing).countdownMinutes == 5)
    }

    // MARK: Between new builds

    /// A newer edit wins whichever arrives first; an older snapshot arriving late is
    /// answered with ours.
    @Test func newerStateWinsWhicheverArrivesFirst() {
        let phone = Device()
        let watch = Device()
        phone.edit(.kayak, at: 100) { $0.speedUnit = .knots }
        let oldPhone = phone.snapshot
        watch.edit(.kayak, at: 200) { $0.speedUnit = .milesPerHour }
        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(watch.receive(oldPhone) == .keptLocalNewer)
        #expect(watch.settings(.kayak).speedUnit == .milesPerHour)
        #expect(watch.receive(phone.snapshot) == .unchanged)
        #expect(phone.receive(watch.snapshot) == .unchanged)
    }

    /// Crossing edits of different settings both survive on both devices.
    @Test func crossingEditsOfDifferentSettingsBothSurvive() {
        let phone = Device(id: "phone")
        let watch = Device(id: "watch")
        phone.edit(.sailing, at: 100) { $0.actionButton = .mark }
        watch.edit(.sailing, at: 101) { $0.countdownMinutes = 5 }
        let fromPhone = phone.snapshot
        let fromWatch = watch.snapshot
        #expect(phone.receive(fromWatch) == .appliedAndKeptLocalNewer)
        #expect(watch.receive(fromPhone) == .appliedAndKeptLocalNewer)
        // The replies change nothing more and ask for nothing more.
        #expect(watch.receive(phone.snapshot) == .unchanged)
        #expect(phone.receive(watch.snapshot) == .unchanged)
        for device in [phone, watch] {
            #expect(device.settings(.sailing).actionButton == .mark)
            #expect(device.settings(.sailing).countdownMinutes == 5)
        }
    }

    /// A deliberate reset to the default propagates between new builds.
    @Test func resetToDefaultPropagatesBetweenNewBuilds() {
        let phone = Device()
        let watch = Device()
        phone.edit(.sup, at: 100) {
            $0.distanceAlert = 1
            $0.actionButton = .manOverboard
        }
        #expect(watch.receive(phone.snapshot) == .applied)
        phone.edit(.sup, at: 200) { $0 = .standard(for: .sup) }
        #expect(watch.receive(phone.snapshot) == .applied)
        #expect(watch.settings(.sup) == .standard(for: .sup))
        #expect(watch.values[SportSettings.Key.actionButton(.sup)] == nil)
    }

    /// Clock skew between new builds: an edit on a phone whose clock runs ahead does not
    /// override a later edit of another setting on the watch.
    @Test func clockSkewOnlyOrdersEditsOfTheSameSetting() {
        let phone = Device(id: "phone")
        let watch = Device(id: "watch")
        phone.edit(.sailing, at: 11.5) { $0.actionButton = .mark }  // clock ahead
        watch.edit(.sailing, at: 11.2) { $0.countdownMinutes = 3 }  // later, clock behind
        #expect(watch.receive(phone.snapshot) == .appliedAndKeptLocalNewer)
        #expect(phone.receive(watch.snapshot) == .applied)
        for device in [phone, watch] {
            #expect(device.settings(.sailing).countdownMinutes == 3)
            #expect(device.settings(.sailing).actionButton == .mark)
        }
    }

    /// WatchConnectivity delivers only the latest application context; skipping earlier
    /// ones loses nothing, because every snapshot carries the full state and stamps.
    @Test func onlyTheLatestOfCoalescedSnapshotsIsNeeded() {
        let phone = Device(id: "phone")
        let watch = Device(id: "watch")
        phone.edit(.canoe, at: 10) { $0.countdownMinutes = 1 }
        _ = phone.snapshot  // never delivered
        phone.edit(.canoe, at: 20) { $0.actionButton = .mark }
        _ = phone.snapshot  // never delivered
        phone.edit(.canoe, at: 30) { $0.countdownMinutes = 0 }
        watch.edit(.canoe, at: 25) { $0.distanceAlert = 2 }
        #expect(watch.receive(phone.snapshot) == .appliedAndKeptLocalNewer)
        #expect(phone.receive(watch.snapshot) == .applied)
        for device in [phone, watch] {
            #expect(device.settings(.canoe).countdownMinutes == 0)
            #expect(device.settings(.canoe).actionButton == .mark)
            #expect(device.settings(.canoe).distanceAlert == 2)
        }
    }

    // MARK: With shipped builds

    /// Legacy → new: an edit on the older build applies the keys it knows (including a
    /// removal) and leaves the Action button and fuel settings alone.
    @Test func legacyEditKeepsNewerKeys() {
        let phone = Device(id: "phone")
        phone.edit(.motorboating, at: 100) {
            $0.actionButton = .manOverboard
            $0.fuelBurnRate = 30
            $0.fuelUnit = .usGallons
            $0.distanceAlert = 2
        }
        let watch = LegacyBuild(id: "watch")
        #expect(watch.receive(phone.snapshot))
        #expect(watch.values[SportSettings.Key.distanceAlert(.motorboating)] as? Double == 2)

        watch.edit(SportSettings.Key.countdown(.motorboating), 5, at: 200)
        watch.edit(SportSettings.Key.distanceAlert(.motorboating), nil, at: 300)
        #expect(phone.receive(watch.snapshot) == .applied)
        let settings = phone.settings(.motorboating)
        #expect(settings.countdownMinutes == 5)
        #expect(settings.distanceAlert == nil)
        #expect(settings.actionButton == .manOverboard)
        #expect(settings.fuelBurnRate == 30)
        #expect(settings.fuelUnit == .usGallons)
        // Our newest stamp is now the older build's own, so it ignores our snapshot.
        #expect(phone.snapshot[SettingsSync.Key.revision] as? Int64 == 300_000)
        #expect(!watch.receive(phone.snapshot))
    }

    /// New → legacy: the older build reads the values it knows, and the newer keys come
    /// back intact after the round trip.
    @Test func newSnapshotStillWorksOnALegacyBuild() {
        let phone = Device(id: "phone")
        phone.edit(.kayak, at: 100) {
            $0.speedUnit = .milesPerHour
            $0.countdownMinutes = 3
            $0.actionButton = .mark
        }
        let watch = LegacyBuild(id: "watch")
        #expect(watch.receive(phone.snapshot))
        #expect(watch.settings(.kayak).speedUnit == .milesPerHour)
        #expect(watch.settings(.kayak).countdownMinutes == 3)
        #expect(watch.values[SportSettings.Key.actionButton(.kayak)] == nil)
        #expect(phone.receive(watch.snapshot) == .unchanged)
        #expect(phone.settings(.kayak).actionButton == .mark)
    }

    /// A legacy snapshot older than our newest stamp would lose on the older build too,
    /// so it is not applied here either; we answer and both end on the same state.
    @Test func olderLegacySnapshotLosesAndBothConverge() {
        let phone = Device(id: "phone")
        let watch = LegacyBuild(id: "watch")
        phone.edit(.sailing, at: 11.5) { $0.actionButton = .mark }  // phone clock ahead
        watch.edit(SportSettings.Key.countdown(.sailing), 3, at: 11.2)  // before seeing it
        let fromWatch = watch.snapshot
        #expect(watch.receive(phone.snapshot))  // the older build takes our whole state
        #expect(phone.receive(fromWatch) == .keptLocalNewer)
        #expect(watch.settings(.sailing).countdownMinutes == phone.settings(.sailing).countdownMinutes)
        #expect(phone.settings(.sailing).actionButton == .mark)
    }

    /// Re-check finding 1: a later legacy edit is never overwritten by a stamp the phone
    /// made up, because the phone makes none when it applies.
    @Test func laterLegacyEditsAlwaysApply() {
        let phone = Device(id: "phone")
        let watch = LegacyBuild(id: "watch")
        phone.edit(.sailing, at: 10) { $0.actionButton = .mark }
        #expect(watch.receive(phone.snapshot))
        watch.edit(SportSettings.Key.countdown(.sailing), 3, at: 11)
        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(!watch.receive(phone.snapshot))  // nothing newer to take
        watch.edit(SportSettings.Key.countdown(.sailing), 5, at: 11.2)
        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(phone.settings(.sailing).countdownMinutes == 5)
        #expect(phone.settings(.sailing).actionButton == .mark)
    }

    /// First review finding and re-check finding 2: the watch upgrades, its activation
    /// snapshot is coalesced away, and its first edit (a different setting) neither
    /// clears the phone's Action button nor keeps the watch from getting it.
    @Test func keptValuesSurviveTheLegacyBuildsUpgrade() {
        let phone = Device(id: "phone")
        let legacy = LegacyBuild(id: "watch")
        phone.edit(.sailing, at: 10) { $0.actionButton = .mark }
        #expect(legacy.receive(phone.snapshot))
        legacy.edit(SportSettings.Key.countdown(.sailing), 3, at: 11)
        #expect(phone.receive(legacy.snapshot) == .applied)
        #expect(!legacy.receive(phone.snapshot))
        #expect(legacy.values[SportSettings.Key.actionButton(.sailing)] == nil)

        let watch = legacy.upgraded(at: 12)
        _ = watch.snapshot  // activation snapshot, coalesced away
        watch.edit(.sailing, at: 20) { $0.countdownMinutes = 5 }
        #expect(watch.stamp(SportSettings.Key.actionButton(.sailing)) == nil)
        #expect(phone.receive(watch.snapshot) == .appliedAndKeptLocalNewer)
        #expect(phone.settings(.sailing).actionButton == .mark)
        #expect(phone.settings(.sailing).countdownMinutes == 5)
        #expect(watch.receive(phone.snapshot) == .applied)
        #expect(watch.settings(.sailing).actionButton == .mark)
        #expect(watch.receive(phone.snapshot) == .unchanged)
        #expect(phone.receive(watch.snapshot) == .unchanged)
    }

    /// A legacy snapshot that carries a newer key (a build with the Action button) applies
    /// it; a newer key it lacks keeps the local value.
    @Test func legacySnapshotAppliesTheNewerKeysItCarries() {
        let phone = Device(id: "phone")
        phone.edit(.sailing, at: 100) {
            $0.actionButton = .mark
            $0.fuelBurnRate = 10
        }
        let watch = LegacyBuild(id: "watch", alsoKnows: [SportSettings.Key.actionButton(.sailing)])
        #expect(watch.receive(phone.snapshot))
        watch.edit(SportSettings.Key.actionButton(.sailing), "manOverboard", at: 200)
        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(phone.settings(.sailing).actionButton == .manOverboard)
        #expect(phone.settings(.sailing).fuelBurnRate == 10)
    }

    /// An older build's global units in its snapshot are migrated, not lost.
    @Test func migratesLegacyUnitsInARemoteSnapshot() {
        let watch = Device()
        let remote: [String: Any] = [SportSettings.Key.legacyDistanceUnit: "mi", SettingsSync.Key.revision: 5_000]
        #expect(watch.receive(remote) == .applied)
        #expect(watch.settings(.canoe).distanceUnit == .statuteMiles)
        #expect(watch.values[SportSettings.Key.legacyDistanceUnit] == nil)
    }

    @Test func legacyKnownKeysAreTheFirstPerSportFields() {
        let keys = SettingsSync.legacyKnownKeys
        #expect(keys.count == 8 * Sport.allCases.count)
        #expect(keys.contains(SportSettings.Key.hidden(.sup)))
        #expect(!keys.contains(SportSettings.Key.actionButton(.sailing)))
        #expect(!keys.contains(SportSettings.Key.fuelBurn(.motorboating)))
        #expect(!keys.contains(SportSettings.Key.fuelIdleBurn(.motorboating)))
        #expect(!keys.contains(SportSettings.Key.fuelUnit(.motorboating)))
    }

    // MARK: Format

    /// A snapshot carries values, stamps and the old builds' revision; never "highest seen"
    /// or history.
    @Test func snapshotCarriesSettingsStampsAndTheNewestRevision() {
        let device = Device(id: "d")
        device.edit(.sailing, at: 1) { $0.firstScreen = .map }
        device.edit(.sailing, at: 2) { $0.firstScreen = .speed }  // back to the default
        device.edit(.kayak, at: 3) { $0.countdownMinutes = 1 }
        device.values["history.lastUsed.sailing"] = 1.0
        let snapshot = device.snapshot
        #expect(
            Set(snapshot.keys) == [
                SportSettings.Key.countdown(.kayak), SettingsSync.Key.stamps, SettingsSync.Key.revision,
                SettingsSync.Key.revisionDevice,
            ])
        #expect(snapshot[SettingsSync.Key.revision] as? Int64 == 3_000)
        #expect(snapshot[SettingsSync.Key.revisionDevice] as? String == "d")
        let stamps = SettingsSync.decode(snapshot[SettingsSync.Key.stamps])
        #expect(stamps[SportSettings.Key.firstScreen(.sailing)] == .init(revision: 2_000, device: "d"))
        #expect(stamps.count == 2)
    }

    /// Stamps survive a round trip through property-list types and skip junk.
    @Test func stampsDecodeTolerantly() {
        let raw: [String: Any] = [
            "settings.countdown.sup": [Double(5_000), "d"] as [Any],
            "settings.hidden.sup": ["x", "d"] as [Any],
            "settings.firstScreen.sup": "junk",
        ]
        #expect(SettingsSync.decode(raw) == ["settings.countdown.sup": .init(revision: 5_000, device: "d")])
        #expect(SettingsSync.decode(nil).isEmpty)
    }

    /// A number that comes back as another numeric type is the same value.
    @Test func sameValueToleratesStoreTypes() {
        #expect(SettingsSync.sameValue(5, 5.0))
        #expect(SettingsSync.sameValue(Int64(5), 5))
        #expect(SettingsSync.sameValue(true, true))
        #expect(SettingsSync.sameValue("mark", "mark"))
        #expect(SettingsSync.sameValue(nil, nil))
        #expect(!SettingsSync.sameValue("mark", nil))
        #expect(!SettingsSync.sameValue("1", 1))
        #expect(!SettingsSync.sameValue(2, 3))
    }
}
