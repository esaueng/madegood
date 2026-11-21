import XCTest

@testable import MadeGood

@MainActor
final class RefreshCoalescerTests: XCTestCase {
    /// Regression: pulling to refresh while the start screen's own refresh was running
    /// returned at once, so the spinner vanished and the list snapped back mid-fetch.
    func testCallDuringARunningRefreshWaitsForIt() async {
        let refresher = RefreshCoalescer()
        var runs = 0
        var finished = false
        let release = AsyncStream<Void>.makeStream()

        let first = Task {
            await refresher.run {
                runs += 1
                for await _ in release.stream { break }
                finished = true
            }
        }
        while !refresher.isRunning { await Task.yield() }

        let second = Task {
            await refresher.run { runs += 1 }
            return finished
        }
        // The second caller is still waiting while the first refresh is held open.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished)

        release.continuation.yield()
        let secondSawFinish = await second.value
        await first.value

        XCTAssertTrue(secondSawFinish, "the second caller returned before the running refresh finished")
        XCTAssertEqual(runs, 1, "a call during a running refresh started another one")
        XCTAssertFalse(refresher.isRunning)
    }

    func testRunsAgainAfterTheLastRefreshFinished() async {
        let refresher = RefreshCoalescer()
        var runs = 0
        await refresher.run { runs += 1 }
        await refresher.run { runs += 1 }
        XCTAssertEqual(runs, 2)
    }
}
