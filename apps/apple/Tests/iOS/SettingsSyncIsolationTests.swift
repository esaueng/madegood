import Foundation
import WaterKit
import XCTest

@testable import MadeGood

/// A `-demoSession` launch (UI tests, screenshots) keeps its settings to itself, so the
/// paired device's settings cannot undo `-resetSettings` (QA-05).
@MainActor
final class SettingsSyncIsolationTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        let defaults = UserDefaults.standard
        for key in Self.keys { saved[key] = defaults.object(forKey: key) }
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        for key in Self.keys {
            if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private static var keys: [String] {
        SettingsSync.storedKeys + [SettingsSync.Key.highestSeen, SettingsSync.Key.deviceID]
    }

    func testDemoLaunchDoesNotSyncSettings() {
        XCTAssertTrue(RecordingTransfer.syncsSettings(arguments: ["MadeGood"]))
        #if DEBUG
            XCTAssertFalse(RecordingTransfer.syncsSettings(arguments: ["MadeGood", "-demoSession"]))
            XCTAssertFalse(RecordingTransfer.syncsSettings(arguments: ["MadeGood", "-demoSession", "-demoTacks"]))
        #endif
    }

    func testIsolatedLaunchIgnoresNewerSettingsFromThePairedDevice() {
        let remote = pairedDeviceHidingWindsurfing()
        XCTAssertFalse(UserSettings.settings(for: .windsurfing).isHidden)

        let isolated = RecordingTransfer(syncsSettings: false)
        XCTAssertFalse(isolated.applyReceivedSettings(remote, alwaysPush: true))
        XCTAssertFalse(UserSettings.settings(for: .windsurfing).isHidden)
        XCTAssertEqual(UserSettings.settings(for: .sailing).countdownMinutes, 0)
    }

    /// Production sync is unchanged: the same snapshot is applied when syncing.
    func testSyncingLaunchAppliesNewerSettingsFromThePairedDevice() {
        let remote = pairedDeviceHidingWindsurfing()
        let syncing = RecordingTransfer(syncsSettings: true)
        _ = syncing.applyReceivedSettings(remote)
        XCTAssertTrue(UserSettings.settings(for: .windsurfing).isHidden)
        XCTAssertEqual(UserSettings.settings(for: .sailing).countdownMinutes, 1)
    }

    /// Starts this device from defaults and returns a newer snapshot from a paired device
    /// that hid windsurfing and set a one-minute sailing countdown.
    private func pairedDeviceHidingWindsurfing() -> [String: Any] {
        for key in Self.keys where key != SettingsSync.Key.deviceID {
            UserDefaults.standard.removeObject(forKey: key)
        }
        var store: [String: Any] = [:]
        let read: (String) -> Any? = { store[$0] }
        let write: (String, Any?) -> Void = { store[$0] = $1 }
        let later = Date().timeIntervalSince1970 + 3600
        var windsurfing = SportSettings(sport: .windsurfing, reading: read)
        windsurfing.isHidden = true
        SettingsSync.save(windsurfing, for: .windsurfing, now: later, device: "paired", reading: read, writing: write)
        var sailing = SportSettings(sport: .sailing, reading: read)
        sailing.countdownMinutes = 1
        SettingsSync.save(sailing, for: .sailing, now: later, device: "paired", reading: read, writing: write)
        return SettingsSync.snapshot(reading: read)
    }
}
