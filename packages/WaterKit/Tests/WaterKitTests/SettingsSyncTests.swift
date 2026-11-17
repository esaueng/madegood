import Testing

@testable import WaterKit

/// Regression tests from the PR #39 review: two-way settings sync.
@Suite struct SettingsSyncTests {
    final class Device {
        let id: String
        var values: [String: Any] = [:]

        init(id: String = "device-\(Int.random(in: 0..<1_000_000))") {
            self.id = id
        }

        func read(_ key: String) -> Any? { values[key] }
        func write(_ key: String, _ value: Any?) { values[key] = value }

        var revision: Int64? { SettingsSync.revision(values[SettingsSync.Key.revision]) }
        var snapshot: [String: Any] { SettingsSync.snapshot(reading: read) }

        /// A local edit, as `UserSettings.save` does it.
        func edit(_ sport: Sport, at now: Double, _ change: (inout SportSettings) -> Void) {
            var settings = SportSettings(sport: sport, reading: read)
            change(&settings)
            settings.write(sport: sport, to: write)
            SettingsSync.stampLocalChange(now: now, device: id, reading: read, writing: write)
        }

        func receive(_ snapshot: [String: Any]) -> SettingsSync.Outcome {
            SettingsSync.apply(remote: snapshot, reading: read, writing: write)
        }

        func settings(_ sport: Sport) -> SportSettings { SportSettings(sport: sport, reading: read) }
    }

    /// Finding 1: an upgraded device's migrated settings survived a freshly installed
    /// companion's empty snapshot only by luck of timestamps; now they always do.
    @Test func freshCompanionNeverWipesMigratedSettings() {
        let upgraded = Device()
        upgraded.values[SportSettings.Key.legacySpeedUnit] = "mph"
        upgraded.values[SportSettings.Key.autoPause(.kayak)] = false
        SportSettings.migrateLegacyUnits(reading: upgraded.read, writing: upgraded.write)
        #expect(
            SettingsSync.assignMissingRevision(
                now: 1_000, device: upgraded.id, reading: upgraded.read, writing: upgraded.write))
        #expect(upgraded.revision == 1_000_000)

        let fresh = Device()
        // Nothing to assign on an empty device.
        #expect(
            !SettingsSync.assignMissingRevision(now: 2_000, device: fresh.id, reading: fresh.read, writing: fresh.write)
        )
        // The fresh device's empty snapshot (no revision) changes nothing and asks for ours.
        #expect(upgraded.receive(fresh.snapshot) == .keptLocalNewer)
        #expect(upgraded.settings(.sailing).speedUnit == .milesPerHour)
        #expect(!upgraded.settings(.kayak).autoPause)

        // Ours reaches the fresh device.
        #expect(fresh.receive(upgraded.snapshot) == .applied)
        #expect(fresh.settings(.sailing).speedUnit == .milesPerHour)
        #expect(!fresh.settings(.kayak).autoPause)
    }

    /// An empty snapshot even with a zero or junk revision never removes values.
    @Test func snapshotWithoutARevisionNeverRemovesValues() {
        let device = Device()
        device.edit(.sup, at: 500) { $0.countdownMinutes = 3 }
        for junk: Any in [0, -5, "abc", Double.nan] {
            #expect(device.receive([SettingsSync.Key.revision: junk]) == .keptLocalNewer)
            #expect(device.settings(.sup).countdownMinutes == 3)
        }
        // A device with no values and no revision ignores an empty snapshot too.
        let empty = Device()
        #expect(empty.receive([:]) == .unchanged)
        #expect(empty.values.isEmpty)
    }

    /// Values from before revisions that already have one keep it.
    @Test func assignsOnlyWhenMissing() {
        let device = Device()
        device.edit(.canoe, at: 10) { $0.isHidden = true }
        let revision = device.revision
        #expect(
            !SettingsSync.assignMissingRevision(now: 99, device: device.id, reading: device.read, writing: device.write)
        )
        #expect(device.revision == revision)
    }

    /// Finding 3: a device whose clock ran ahead and was then corrected still produces
    /// revisions that beat the state it has seen, so its next edit is not lost.
    @Test func revisionsSurviveAClockCorrection() {
        let phone = Device()
        let watch = Device()
        // The watch's clock is an hour ahead when it edits.
        watch.edit(.sailing, at: 10_000 + 3_600) { $0.countdownMinutes = 5 }
        #expect(phone.receive(watch.snapshot) == .applied)

        // The phone edits later, by real time, with a correct clock.
        phone.edit(.sailing, at: 10_060) { $0.countdownMinutes = 1 }
        #expect((phone.revision ?? 0) > (watch.revision ?? 0))
        #expect(watch.receive(phone.snapshot) == .applied)
        #expect(watch.settings(.sailing).countdownMinutes == 1)

        // The watch's clock is corrected (now behind its old revisions); its next edit
        // still wins.
        watch.edit(.sailing, at: 10_120) { $0.countdownMinutes = 3 }
        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(phone.settings(.sailing).countdownMinutes == 3)
    }

    @Test func nextRevisionIsMonotonic() {
        #expect(SettingsSync.nextRevision(now: 2, highestSeen: 0) == 2_000)
        #expect(SettingsSync.nextRevision(now: 2, highestSeen: 5_000) == 5_001)
        #expect(SettingsSync.nextRevision(now: .nan, highestSeen: 7) == 8)
    }

    /// An accepted revision from a clock that ran ahead raises the floor for later edits.
    @Test func acceptedRevisionRaisesTheFloor() {
        let device = Device()
        device.edit(.kayak, at: 100) { $0.autoPause = false }
        let ahead: [String: Any] = [SettingsSync.Key.revision: Int64(50_000_000), SettingsSync.Key.revisionDevice: "x"]
        #expect(device.receive(ahead) == .applied)
        device.edit(.kayak, at: 100) { $0.autoPause = false }
        #expect(device.revision == 50_000_001)
    }

    /// Review re-check: a rejected (older) snapshot changes neither the values nor the
    /// revisions, and the next local edit continues from this device's own revision.
    @Test func rejectedRevisionChangesNothing() {
        let device = Device()
        device.edit(.kayak, at: 100_000) { $0.distanceAlert = 2 }
        let before = device.values.count
        let revision = device.revision
        let older: [String: Any] = [
            SettingsSync.Key.revision: Int64(50_000_000), SettingsSync.Key.revisionDevice: "zzz",
            SportSettings.Key.distanceAlert(.kayak): 5.0,
        ]
        #expect(device.receive(older) == .keptLocalNewer)
        #expect(device.settings(.kayak).distanceAlert == 2)
        #expect(device.revision == revision)
        #expect(device.values.count == before)
        #expect(SettingsSync.revision(device.values[SettingsSync.Key.highestSeen]) == revision)
        device.edit(.kayak, at: 1) { $0.distanceAlert = 1 }  // clock far behind
        #expect(device.revision == (revision ?? 0) + 1)
    }

    /// Review re-check: two devices that reach the same revision with different settings
    /// converge on the same winner, the higher device ID, and stop replying.
    @Test func equalRevisionsConvergeOnOneWinner() {
        let a = Device(id: "A")
        let b = Device(id: "B")
        // Both saw revision R from a clock that ran ahead, then edited offline.
        let ahead: [String: Any] = [SettingsSync.Key.revision: Int64(9_000_000), SettingsSync.Key.revisionDevice: "C"]
        #expect(a.receive(ahead) == .applied)
        #expect(b.receive(ahead) == .applied)
        a.edit(.sailing, at: 10) { $0.countdownMinutes = 1 }
        b.edit(.sailing, at: 10) { $0.countdownMinutes = 5 }
        #expect(a.revision == 9_000_001)
        #expect(a.revision == b.revision)

        // Messages cross: each side gets the other's snapshot.
        let fromA = a.snapshot
        let fromB = b.snapshot
        #expect(a.receive(fromB) == .applied)  // B wins the tie on both sides
        #expect(b.receive(fromA) == .keptLocalNewer)  // B replies with its own...
        #expect(a.receive(b.snapshot) == .unchanged)  // ...which A already has: no loop
        #expect(a.settings(.sailing).countdownMinutes == 5)
        #expect(b.settings(.sailing).countdownMinutes == 5)
        // A's reply after applying (the phone re-pushes) is a no-op at B.
        #expect(b.receive(a.snapshot) == .unchanged)
    }

    /// The order is lexicographic: revision first, then device ID.
    @Test func stampsCompareRevisionThenDevice() {
        typealias Stamp = SettingsSync.Stamp
        #expect(Stamp(revision: 2, device: "A") > Stamp(revision: 1, device: "Z"))
        #expect(Stamp(revision: 2, device: "B") > Stamp(revision: 2, device: "A"))
        #expect(Stamp(revision: 2, device: "A") == Stamp(revision: 2, device: "A"))
    }

    /// Finding 4 (and the receiver's half of it): an edit made while the other device was
    /// unreachable arrives later and wins over older state; an older snapshot arriving
    /// late is rejected and answered with ours.
    @Test func newerStateWinsWhicheverArrivesFirst() {
        let phone = Device()
        let watch = Device()
        phone.edit(.kayak, at: 100) { $0.speedUnit = .knots }
        let oldPhone = phone.snapshot
        watch.edit(.kayak, at: 200) { $0.speedUnit = .milesPerHour }  // before activation

        #expect(phone.receive(watch.snapshot) == .applied)
        #expect(phone.settings(.kayak).speedUnit == .milesPerHour)
        #expect(watch.receive(oldPhone) == .keptLocalNewer)
        #expect(watch.settings(.kayak).speedUnit == .milesPerHour)
        // Converged: the same revision both ways is a no-op, so pushes do not loop.
        #expect(watch.receive(phone.snapshot) == .unchanged)
        #expect(phone.receive(watch.snapshot) == .unchanged)
    }

    /// A deliberate return to defaults has a revision, so it does propagate.
    @Test func aRevisedResetToDefaultsPropagates() {
        let phone = Device()
        let watch = Device()
        phone.edit(.sup, at: 100) { $0.distanceAlert = 1 }
        #expect(watch.receive(phone.snapshot) == .applied)
        phone.edit(.sup, at: 200) { $0 = .standard(for: .sup) }
        #expect(watch.receive(phone.snapshot) == .applied)
        #expect(watch.settings(.sup) == .standard(for: .sup))
    }

    /// A snapshot from an older build carries global units; they are migrated, not lost.
    @Test func migratesLegacyUnitsInARemoteSnapshot() {
        let watch = Device()
        let remote: [String: Any] = [SportSettings.Key.legacyDistanceUnit: "mi", SettingsSync.Key.revision: 5_000]
        #expect(watch.receive(remote) == .applied)
        #expect(watch.settings(.canoe).distanceUnit == .statuteMiles)
        #expect(watch.values[SportSettings.Key.legacyDistanceUnit] == nil)
    }

    /// The snapshot never carries the device-local "highest seen".
    @Test func snapshotCarriesOnlySettingsAndRevision() {
        let device = Device()
        device.edit(.sailing, at: 1) { $0.firstScreen = .map }
        device.values["history.lastUsed.sailing"] = 1.0
        #expect(
            Set(device.snapshot.keys) == [
                SportSettings.Key.firstScreen(.sailing), SettingsSync.Key.revision, SettingsSync.Key.revisionDevice,
            ])
        #expect(device.snapshot[SettingsSync.Key.revisionDevice] as? String == device.id)
    }
}
