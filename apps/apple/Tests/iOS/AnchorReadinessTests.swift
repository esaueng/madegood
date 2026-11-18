import CoreLocation
import UserNotifications
import XCTest

@testable import MadeGood

/// Review regression: a denied notification permission used to be discarded, so the
/// anchor watch looked fully armed with no way to alert a locked phone.
final class AnchorReadinessTests: XCTestCase {
    func testAllowedPermissionsHaveNoIssues() {
        for notifications in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            XCTAssertEqual(
                AnchorReadiness.issues(
                    notifications: notifications, location: .authorizedWhenInUse, accuracy: .fullAccuracy), [])
        }
        XCTAssertEqual(
            AnchorReadiness.issues(notifications: .authorized, location: .authorizedAlways, accuracy: .fullAccuracy),
            [])
    }

    func testDeniedOrUnaskedNotificationsAreReported() {
        for notifications in [UNAuthorizationStatus.denied, .notDetermined] {
            XCTAssertEqual(
                AnchorReadiness.issues(
                    notifications: notifications, location: .authorizedWhenInUse, accuracy: .fullAccuracy),
                [.notificationsOff])
        }
    }

    func testLocationProblemsAreReported() {
        XCTAssertEqual(
            AnchorReadiness.issues(notifications: .authorized, location: .denied, accuracy: .fullAccuracy),
            [.locationOff])
        XCTAssertEqual(
            AnchorReadiness.issues(notifications: .denied, location: .restricted, accuracy: .reducedAccuracy),
            [.notificationsOff, .locationOff])
        XCTAssertEqual(
            AnchorReadiness.issues(
                notifications: .authorized, location: .authorizedWhenInUse, accuracy: .reducedAccuracy),
            [.approximateLocation])
    }
}
