import Testing

@testable import WaterKit

@Suite struct SportSettingsTests {
    /// An in-memory key-value store standing in for UserDefaults.
    final class Store {
        var values: [String: Any] = [:]
        func read(_ key: String) -> Any? { values[key] }
        func write(_ key: String, _ value: Any?) { values[key] = value }
    }

    @Test func defaultsFollowTheSport() {
        let kayak = SportSettings.standard(for: .kayak)
        #expect(kayak.autoPause)
        #expect(kayak.savesWorkout)
        #expect(kayak.resolvedSpeedUnit(for: .kayak) == .kilometresPerHour)
        #expect(kayak.resolvedDistanceUnit(for: .kayak) == .metric)
        #expect(kayak.firstScreen == .speed)
        #expect(kayak.distanceAlert == nil)
        #expect(kayak.countdownSeconds == nil)
        #expect(!kayak.isHidden)

        let sailing = SportSettings.standard(for: .sailing)
        #expect(!sailing.autoPause)
        #expect(sailing.resolvedSpeedUnit(for: .sailing) == .knots)
        #expect(sailing.resolvedDistanceUnit(for: .sailing) == .nauticalMiles)
        #expect(!SportSettings.standard(for: .motorboating).savesWorkout)
    }

    @Test func emptyStoreReadsAsDefaults() {
        let store = Store()
        for sport in Sport.allCases {
            #expect(SportSettings(sport: sport, reading: store.read) == .standard(for: sport))
        }
    }

    @Test func roundTripsEveryField() {
        let store = Store()
        var settings = SportSettings.standard(for: .sailing)
        settings.speedUnit = .milesPerHour
        settings.distanceUnit = .statuteMiles
        settings.firstScreen = .map
        settings.autoPause = true
        settings.savesWorkout = false
        settings.distanceAlert = 0.5
        settings.countdownMinutes = 5
        settings.isHidden = true
        settings.write(sport: .sailing, to: store.write)
        #expect(SportSettings(sport: .sailing, reading: store.read) == settings)
        // Other sports are untouched.
        #expect(SportSettings(sport: .kayak, reading: store.read) == .standard(for: .kayak))
    }

    @Test func defaultsAreNotStored() {
        let store = Store()
        SportSettings.standard(for: .kayak).write(sport: .kayak, to: store.write)
        #expect(store.values.compactMapValues { $0 }.isEmpty)

        // Turning a setting off again removes it, so a later default change applies.
        var settings = SportSettings.standard(for: .kayak)
        settings.autoPause = false
        settings.write(sport: .kayak, to: store.write)
        #expect(store.values[SportSettings.Key.autoPause(.kayak)] as? Bool == false)
        settings.autoPause = true
        settings.write(sport: .kayak, to: store.write)
        #expect(store.values[SportSettings.Key.autoPause(.kayak)] == nil)
    }

    /// Existing installs stored auto-pause and Health per sport under these names.
    @Test func readsExistingKeys() {
        let store = Store()
        store.values["settings.autoPause.kayak"] = false
        store.values["settings.saveWorkout.motorboating"] = true
        #expect(!SportSettings(sport: .kayak, reading: store.read).autoPause)
        #expect(SportSettings(sport: .motorboating, reading: store.read).savesWorkout)
    }

    /// Launch arguments (`-settings.countdown.sailing 1`) arrive as strings.
    @Test func readsStringValues() {
        let store = Store()
        store.values[SportSettings.Key.countdown(.sailing)] = "3"
        store.values[SportSettings.Key.distanceAlert(.sailing)] = "0.25"
        store.values[SportSettings.Key.hidden(.sailing)] = "YES"
        store.values[SportSettings.Key.autoPause(.sailing)] = "1"
        store.values[SportSettings.Key.firstScreen(.sailing)] = "heartRate"
        let settings = SportSettings(sport: .sailing, reading: store.read)
        #expect(settings.countdownMinutes == 3)
        #expect(settings.distanceAlert == 0.25)
        #expect(settings.isHidden)
        #expect(settings.autoPause)
        #expect(settings.firstScreen == .heartRate)
    }

    @Test func ignoresInvalidValues() {
        let store = Store()
        store.values[SportSettings.Key.speedUnit(.sup)] = "warp"
        store.values[SportSettings.Key.speedUnit(.canoe)] = SportSettings.automaticValue
        store.values[SportSettings.Key.firstScreen(.sup)] = "radar"
        store.values[SportSettings.Key.distanceAlert(.sup)] = -1.0
        store.values[SportSettings.Key.countdown(.sup)] = 600
        #expect(SportSettings(sport: .sup, reading: store.read) == .standard(for: .sup))
        #expect(SportSettings(sport: .canoe, reading: store.read).speedUnit == nil)
    }

    @Test func distanceAlertUsesTheSportsUnit() {
        var settings = SportSettings.standard(for: .sailing)
        settings.distanceAlert = 1
        #expect(settings.distanceAlertMetres(for: .sailing) == 1852)
        settings.distanceUnit = .metric
        #expect(settings.distanceAlertMetres(for: .sailing) == 1000)
        settings.distanceAlert = nil
        #expect(settings.distanceAlertMetres(for: .sailing) == nil)
    }

    @Test func migratesUnitsThatWereForEverySport() {
        let store = Store()
        store.values[SportSettings.Key.legacySpeedUnit] = "mph"
        store.values[SportSettings.Key.legacyDistanceUnit] = "auto"
        // A sport that already has its own unit keeps it.
        store.values[SportSettings.Key.speedUnit(.kayak)] = "kmh"
        SportSettings.migrateLegacyUnits(reading: store.read, writing: store.write)

        #expect(store.values[SportSettings.Key.legacySpeedUnit] == nil)
        #expect(store.values[SportSettings.Key.legacyDistanceUnit] == nil)
        #expect(SportSettings(sport: .sailing, reading: store.read).speedUnit == .milesPerHour)
        #expect(SportSettings(sport: .kayak, reading: store.read).speedUnit == .kilometresPerHour)
        // "Automatic" was the default, so nothing is copied.
        #expect(SportSettings(sport: .sailing, reading: store.read).distanceUnit == nil)

        // Running it again changes nothing.
        let before = store.values.count
        SportSettings.migrateLegacyUnits(reading: store.read, writing: store.write)
        #expect(store.values.count == before)
    }

    @Test func ordersByLastUse() {
        #expect(SportList.ordered(lastUsed: [:], hidden: []) == Sport.allCases)
        let order = SportList.ordered(lastUsed: [.kayak: 100, .sup: 300, .sailing: 200], hidden: [])
        #expect(order == [.sup, .sailing, .kayak, .windsurfing, .motorboating, .canoe])
        let visible = SportList.ordered(lastUsed: [.kayak: 100, .sup: 300], hidden: [.sup, .canoe])
        #expect(visible == [.kayak, .sailing, .windsurfing, .motorboating])
    }

    @Test func oneSportStaysVisible() {
        let allButSailing = Set(Sport.allCases.filter { $0 != .sailing })
        #expect(!SportList.canHide(.sailing, hidden: allButSailing))
        #expect(SportList.canHide(.kayak, hidden: allButSailing))  // already hidden: may be shown
        #expect(SportList.canHide(.sailing, hidden: []))
        // A store that hides everything still shows every sport rather than none.
        #expect(SportList.ordered(lastUsed: [:], hidden: Set(Sport.allCases)) == Sport.allCases)
    }
}

@Suite struct StartCountdownTests {
    @Test func countsDown() {
        let countdown = StartCountdown(duration: 300, startingAt: 1_000)
        #expect(countdown.displaySeconds(at: 1_000) == 300)
        #expect(countdown.displaySeconds(at: 1_000.4) == 300)
        #expect(countdown.displaySeconds(at: 1_001) == 299)
        #expect(countdown.displaySeconds(at: 1_299.5) == 1)
        #expect(countdown.displaySeconds(at: 1_300) == 0)
        #expect(!countdown.isFinished(at: 1_299.9))
        #expect(countdown.isFinished(at: 1_300))
        #expect(countdown.remaining(at: 2_000) == 0)
    }

    @Test func syncRoundsToTheNearestMinute() {
        var countdown = StartCountdown(duration: 300, startingAt: 0)
        countdown.sync(at: 8)  // 4:52 left → 5:00
        #expect(countdown.remaining(at: 8) == 300)
        countdown.sync(at: 50)  // 4:18 left → 4:00
        #expect(countdown.remaining(at: 50) == 240)
        countdown.sync(at: 50 + 210)  // 0:30 left rounds up to 1:00
        #expect(countdown.remaining(at: 260) == 60)
        countdown.sync(at: 260 + 35)  // 0:25 left → zero, finished
        #expect(countdown.isFinished(at: 295))
    }

    @Test func cuesEachMinuteTheLastTenSecondsAndTheStart() {
        let countdown = StartCountdown(duration: 180, startingAt: 0)
        var cues: [StartCountdown.Cue] = []
        var previous = 0.0
        // Ticks a little off whole seconds, as a real timer delivers them.
        for tick in stride(from: 0.3, through: 181, by: 1) {
            if let cue = countdown.cue(from: previous, to: tick) { cues.append(cue) }
            previous = tick
        }
        #expect(
            cues == [
                .minute(2), .minute(1), .second(10), .second(9), .second(8), .second(7), .second(6), .second(5),
                .second(4), .second(3), .second(2), .second(1), .start,
            ])
    }

    @Test func aGapGivesOneCue() {
        let countdown = StartCountdown(duration: 300, startingAt: 0)
        #expect(countdown.cue(from: 10, to: 200) == .minute(2))
        #expect(countdown.cue(from: 10, to: 400) == .start)
        #expect(countdown.cue(from: 400, to: 401) == nil)
        #expect(countdown.cue(from: 20, to: 20) == nil)
    }
}

@Suite struct DistanceAlertTests {
    @Test func firesAtEachMilestone() {
        var alert = DistanceAlert(interval: 100)!
        #expect(alert.update(distance: 0) == nil)
        #expect(alert.update(distance: 99.9) == nil)
        #expect(alert.update(distance: 100) == 100)
        #expect(alert.update(distance: 150) == nil)
        #expect(alert.update(distance: 120) == nil)  // recalculated down: no repeat
        #expect(alert.update(distance: 199) == nil)
        #expect(alert.update(distance: 450) == 400)  // jumped past two: one alert
        #expect(alert.count == 4)
    }

    @Test func toleratesRounding() {
        var alert = DistanceAlert(interval: 0.1 * 1000)!
        #expect(alert.update(distance: 0.1 * 3 * 1000) == 300)
    }

    @Test func offWithoutAnInterval() {
        #expect(DistanceAlert(interval: nil) == nil)
        #expect(DistanceAlert(interval: 0) == nil)
        #expect(DistanceAlert(interval: .infinity) == nil)
    }
}
