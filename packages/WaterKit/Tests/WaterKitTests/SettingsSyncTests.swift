import Testing

@testable import WaterKit

/// Regression tests from the PR #39 review: two-way settings sync.
@Suite struct SettingsSyncTests {
    final class Device {
        var values: [String: Any] = [:]
        func read(_ key: String) -> Any? { values[key] }
        func write(_ key: String, _ value: Any?) { values[key] = value }

        var revision: Int64? { SettingsSync.revision(values[SettingsSync.Key.revision]) }
        var snapshot: [String: Any] { SettingsSync.snapshot(reading: read) }

        /// A local edit, as `UserSettings.save` does it.
        func edit(_ sport: Sport, at now: Double, _ change: (inout SportSettings) -> Void) {
            var settings = SportSettings(sport: sport, reading: read)
            change(&settings)
            settings.write(sport: sport, to: write)
            SettingsSync.stampLocalChange(now: now, reading: read, writing: write)
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
        #expect(SettingsSync.assignMissingRevision(now: 1_000, reading: upgraded.read, writing: upgraded.write))
        #expect(upgraded.revision == 1_000_000)

        let fresh = Device()
        // Nothing to assign on an empty device.
        #expect(!SettingsSync.assignMissingRevision(now: 2_000, reading: fresh.read, writing: fresh.write))
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
        #expect(!SettingsSync.assignMissingRevision(now: 99, reading: device.read, writing: device.write))
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
        // Seeing a revision, even one that is rejected, raises the floor.
        let device = Device()
        device.edit(.kayak, at: 100) { $0.autoPause = false }
        _ = device.receive([SettingsSync.Key.revision: Int64(50_000_000)] as [String: Any])
        device.edit(.kayak, at: 100) { $0.autoPause = true }
        #expect(device.revision == 50_000_001)
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
        #expect(Set(device.snapshot.keys) == [SportSettings.Key.firstScreen(.sailing), SettingsSync.Key.revision])
    }
}
