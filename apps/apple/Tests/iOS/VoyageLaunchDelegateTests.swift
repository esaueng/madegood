import XCTest

@testable import MadeGood

final class VoyageLaunchDelegateTests: XCTestCase {
    @MainActor
    func testReplayDemoDoesNotResumeAnActiveVoyage() {
        VoyageLaunchDelegate.restoreActiveLeg(isReplayDemo: true) {
            XCTFail("Replay demos must leave the Voyage library closed")
        }
    }

    @MainActor
    func testNormalLaunchOnlyOpensTheLibraryWhenVoyagesAreEnabled() {
        var recoveryCount = 0
        VoyageLaunchDelegate.restoreActiveLeg(isReplayDemo: false) {
            recoveryCount += 1
        }
        #if DEBUG
            XCTAssertEqual(recoveryCount, 1)
        #else
            XCTAssertEqual(recoveryCount, 0)
        #endif
    }
}
