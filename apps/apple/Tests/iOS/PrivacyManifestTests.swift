import XCTest

@testable import MadeGood

/// The shipped app's privacy declarations (docs/app-store.md): the privacy manifest, the
/// permission strings and the privacy policy link.
final class PrivacyManifestTests: XCTestCase {
    private func manifest(in bundle: Bundle) throws -> [String: Any] {
        let url = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testManifestDeclaresNoTrackingAndTheRequiredReasonAPIsInUse() throws {
        let plist = try manifest(in: .main)
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
        let accessed = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in accessed {
            reasons[try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)] =
                entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(
            reasons,
            [
                // Settings, sync preferences (UserDefaults, @AppStorage).
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                // ProcessInfo.systemUptime. 35F9.1: elapsed time that stays on the device (session
                // timer, man-overboard age, live stroke rate). 8FFB.1: the recording's clock
                // anchor in meta.json, which turns motion timestamps (time since boot) into
                // absolute times and leaves the device with the recording (watch to phone,
                // raw export) (docs/formats.md, "Clock").
                "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1"],
                // Modification dates of the app's own recording files (RawSessionReader.revision).
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            ])
    }

    func testManifestListsTheDataSyncUploads() throws {
        let plist = try manifest(in: .main)
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(
            types,
            [
                "NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypeHealth",
                "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypeOtherUserContent",
                "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeName",
            ])
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }

    func testPermissionStringsDescribeWhatTheAppDoes() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertTrue((info["NSHealthUpdateUsageDescription"] as? String)?.contains("saves your sessions to Health") == true)
        XCTAssertTrue((info["NSHealthShareUsageDescription"] as? String)?.contains("heart rate") == true)
        let motion = info["NSMotionUsageDescription"] as? String
        XCTAssertTrue(motion?.contains("paddle strokes") == true)
        XCTAssertFalse(motion?.contains("maneuver") == true, "maneuvers come from GPS, not motion")
        XCTAssertNil(info["NSLocationAlwaysAndWhenInUseUsageDescription"], "the app never asks for Always")
        XCTAssertNil(info["NSUserTrackingUsageDescription"])
    }

    func testPrivacyPolicyLinkPointsAtTheSite() throws {
        let url = try XCTUnwrap(AppInfo.privacyPolicyURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.lastPathComponent, "privacy")
    }
}
