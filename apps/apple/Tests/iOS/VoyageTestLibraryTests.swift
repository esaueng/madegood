import XCTest

@testable import MadeGood

/// The remembered UI-test voyage library (Debug, simulator): it expires, and an expired or
/// unreadable marker is removed.
final class VoyageTestLibraryTests: XCTestCase {
    #if DEBUG && targetEnvironment(simulator)
        @MainActor
        func testARememberedLibraryOpensUntilItExpires() throws {
            try XCTSkipIf(
                ProcessInfo.processInfo.environment["MADEGOOD_TEST_VOYAGES"] != nil,
                "A test environment names its own library")
            let id = UUID()
            let written = Date(timeIntervalSince1970: 1_000_000)
            VoyageRecorder.rememberTestLibrary(id, at: written)
            let root = VoyageRecorder.testLibraryRoot(now: written.addingTimeInterval(60))
            XCTAssertEqual(root?.lastPathComponent, id.uuidString)
            XCTAssertEqual(root?.deletingLastPathComponent().lastPathComponent, "TestVoyages")

            let late = written.addingTimeInterval(VoyageRecorder.testLibraryLifetime + 1)
            XCTAssertNil(VoyageRecorder.testLibraryRoot(now: late))
            // Expired markers are removed, so even an earlier clock no longer finds it.
            XCTAssertNil(VoyageRecorder.testLibraryRoot(now: written))
        }

        @MainActor
        func testAMarkerFromTheFutureIsIgnored() throws {
            try XCTSkipIf(ProcessInfo.processInfo.environment["MADEGOOD_TEST_VOYAGES"] != nil)
            let written = Date(timeIntervalSince1970: 2_000_000)
            VoyageRecorder.rememberTestLibrary(UUID(), at: written)
            XCTAssertNil(VoyageRecorder.testLibraryRoot(now: written.addingTimeInterval(-60)))
        }
    #endif
}
