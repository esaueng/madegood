import Foundation
import XCTest

@testable import MadeGood

@MainActor
final class AnchorGPSWatchdogTests: XCTestCase {
    func testRapidRearmSchedulesWithoutAnotherFixAndRemovesLateAlarm() async {
        let system = FakeAlarms()
        let started = expectation(description: "first arming passed its request to AlarmKit")
        let rearmed = expectation(description: "latest arming installed its watchdog")
        system.onSchedule = { attempt in
            if attempt == 1 { started.fulfill() } else { rearmed.fulfill() }
        }
        system.holdFirstSchedule = true
        let watchdog = system.makeWatchdog()
        let firstArm = system.wallTime
        watchdog.start()
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(startedResult, .completed)

        watchdog.stop()
        watchdog.start()
        watchdog.stop()
        let lastArm = system.wallTime
        watchdog.start()
        system.resumeFirstSchedule()

        let rearmedResult = await XCTWaiter.fulfillment(of: [rearmed], timeout: 5)
        XCTAssertEqual(rearmedResult, .completed)
        XCTAssertEqual(system.attempts.count, 2)
        XCTAssertEqual(system.attempts.first?.deadline.timeIntervalSince(firstArm) ?? 0, 120, accuracy: 1)
        XCTAssertEqual(system.attempts.last?.deadline.timeIntervalSince(lastArm) ?? 0, 120, accuracy: 1)
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertEqual(system.pending.values.first, system.attempts.last?.deadline)
        XCTAssertEqual(system.pendingAtSchedule, [0, 0])
    }

    func testRestoreKeepsTheExistingDeadlineAndRenewalLeavesSoundingAlarmAlone() async throws {
        let system = FakeAlarms()
        let started = expectation(description: "initial watchdog scheduled")
        system.onSchedule = { _ in started.fulfill() }
        let first = system.makeWatchdog()
        first.start()
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(startedResult, .completed)
        let original = try XCTUnwrap(system.pending.first)

        let read = expectation(description: "restored watchdog read the existing alarm")
        system.onSnapshot = { read.fulfill() }
        let restored = system.makeWatchdog()
        restored.start(restoring: true)
        let readResult = await XCTWaiter.fulfillment(of: [read], timeout: 5)
        XCTAssertEqual(readResult, .completed)
        system.onSnapshot = nil
        XCTAssertEqual(system.attempts.count, 1)
        XCTAssertEqual(system.pending[original.key], original.value)

        system.advance(by: 120)
        system.pending.removeValue(forKey: original.key)
        system.sounding = [original.key]
        let renewed = expectation(description: "first usable fix assigned another slot")
        system.onSchedule = { _ in renewed.fulfill() }
        restored.renew(fixAge: 0, assessment: .withinOrUncertain)
        let renewedResult = await XCTWaiter.fulfillment(of: [renewed], timeout: 5)
        XCTAssertEqual(renewedResult, .completed)
        XCTAssertEqual(system.sounding, [original.key])
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertNil(system.pending[original.key])
    }

    func testRestoreWithoutAnExistingAlarmSchedulesWithoutAFix() async {
        let system = FakeAlarms()
        let scheduled = expectation(description: "restore installed the missing watchdog")
        system.onSchedule = { _ in scheduled.fulfill() }
        let watchdog = system.makeWatchdog()
        let restoredAt = system.wallTime
        watchdog.start(restoring: true)

        let scheduledResult = await XCTWaiter.fulfillment(of: [scheduled], timeout: 5)
        XCTAssertEqual(scheduledResult, .completed)
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertEqual(system.pending.values.first?.timeIntervalSince(restoredAt) ?? 0, 120, accuracy: 1)
    }

    func testRenewalSchedulesTheReplacementBeforeRemovingTheCurrentAlarm() async throws {
        let system = FakeAlarms()
        let started = expectation(description: "initial watchdog scheduled")
        system.onSchedule = { _ in started.fulfill() }
        let watchdog = system.makeWatchdog()
        watchdog.start()
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(startedResult, .completed)
        let original = try XCTUnwrap(system.pending.first)

        let renewed = expectation(description: "first usable fix replaced the initial deadline")
        system.onSchedule = { _ in renewed.fulfill() }
        let removed = expectation(description: "the original watchdog was removed after replacement")
        system.onRemove = { id in
            if id == original.key { removed.fulfill() }
        }
        system.advance(by: 2)
        watchdog.renew(fixAge: 0, assessment: .withinOrUncertain)
        let renewedResult = await XCTWaiter.fulfillment(of: [renewed, removed], timeout: 5, enforceOrder: true)
        XCTAssertEqual(renewedResult, .completed)
        XCTAssertEqual(system.pendingAtSchedule, [0, 1])
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertNil(system.pending[original.key])
    }

    func testFirstScheduleRetriesWithoutFixAndReportsMissingCoverage() async {
        let system = FakeAlarms()
        system.failScheduleAttempts = [1, 2]
        let watchdog = system.makeWatchdog(retryDelay: .milliseconds(100))
        let failed = expectation(description: "initial AlarmKit schedule failed")
        let installed = expectation(description: "retry installed the watchdog without GPS")
        system.onSchedule = { attempt in
            if attempt == 1 { failed.fulfill() }
            if attempt == 3 { installed.fulfill() }
        }

        watchdog.start()
        XCTAssertFalse(watchdog.hasSystemAlarm)
        await waitFor(failed)
        XCTAssertFalse(watchdog.hasSystemAlarm)
        XCTAssertTrue(system.pending.isEmpty)

        await waitFor(installed)
        XCTAssertEqual(system.attempts.count, 3)
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertTrue(watchdog.hasSystemAlarm)
    }

    func testReconcileReinstallsExternallyRemovedAlarmAtOriginalDeadline() async throws {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog()
        let initial = expectation(description: "watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        await waitFor(initial)
        let original = try XCTUnwrap(system.pending.first)

        system.pending.removeAll()
        system.advance(by: 40)
        let restored = expectation(description: "foreground or authorization restored coverage")
        system.onSchedule = { _ in restored.fulfill() }
        watchdog.reconcile()
        await waitFor(restored)

        XCTAssertEqual(system.pending.count, 1)
        XCTAssertEqual(system.pending.values.first, original.value)
        XCTAssertTrue(watchdog.hasSystemAlarm)
    }

    func testAlarmUpdatesRestoreCoverageWithoutGPSAndShowWhenItIsMissing() async throws {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog(retryDelay: .milliseconds(100))
        let observer = Task { await watchdog.observeAlarmChanges() }
        defer { observer.cancel() }
        let initial = expectation(description: "initial watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        await waitFor(initial)
        let original = try XCTUnwrap(system.pending.values.first)

        let failedReplacement = expectation(description: "alarm update attempted replacement")
        let restored = expectation(description: "retry restored coverage")
        system.failScheduleAttempts = [2]
        system.onSchedule = { attempt in
            XCTAssertFalse(watchdog.hasSystemAlarm)
            if attempt == 2 {
                failedReplacement.fulfill()
            } else if attempt == 3 {
                restored.fulfill()
            }
        }
        system.pending.removeAll()
        system.emitChange()

        await waitFor(failedReplacement)
        await waitFor(restored)
        XCTAssertTrue(watchdog.hasSystemAlarm)
        XCTAssertEqual(Array(system.pending.values), [original])
    }

    func testActiveTimerRecoversWhenAnAlarmUpdateIsMissed() async throws {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog(checkInterval: .milliseconds(25))
        let initial = expectation(description: "initial watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        watchdog.setActive(true)
        defer { watchdog.setActive(false) }
        await waitFor(initial)
        let original = try XCTUnwrap(system.pending.values.first)

        let restored = expectation(description: "periodic check restored coverage")
        system.onSchedule = { _ in restored.fulfill() }
        system.pending.removeAll()
        await waitFor(restored)

        XCTAssertTrue(watchdog.hasSystemAlarm)
        XCTAssertEqual(Array(system.pending.values), [original])
    }

    func testDisarmRetriesCancellationOfAnAlarmThatCompletesLate() async {
        let system = FakeAlarms()
        system.holdFirstSchedule = true
        system.removeFailures = 1
        let watchdog = system.makeWatchdog()
        let started = expectation(description: "schedule is in flight")
        system.onSchedule = { _ in started.fulfill() }
        watchdog.start()
        await waitFor(started)

        let removed = expectation(description: "late alarm was removed after cancellation failed")
        system.onRemove = { _ in removed.fulfill() }
        watchdog.stop()
        system.resumeFirstSchedule()
        await waitFor(removed)

        XCTAssertEqual(system.attempts.count, 1)
        XCTAssertEqual(system.failedRemovals, 1)
        XCTAssertTrue(system.pending.isEmpty)
        XCTAssertFalse(watchdog.hasSystemAlarm)
    }

    func testRearmClearsLateAlarmBeforeInstallingAnotherWhenCancellationFails() async {
        let system = FakeAlarms()
        system.holdFirstSchedule = true
        system.removeFailures = 1
        let watchdog = system.makeWatchdog()
        let started = expectation(description: "schedule is in flight")
        system.onSchedule = { _ in started.fulfill() }
        watchdog.start()
        await waitFor(started)

        let rearmed = expectation(description: "new generation installed after cleanup")
        system.onSchedule = { _ in rearmed.fulfill() }
        watchdog.stop()
        system.advance(by: 10)
        watchdog.start()
        system.resumeFirstSchedule()
        await waitFor(rearmed)

        XCTAssertEqual(system.failedRemovals, 1)
        XCTAssertEqual(system.pendingAtSchedule, [0, 0])
        XCTAssertEqual(Array(system.pending.values), [system.wallTime.addingTimeInterval(120)])
    }

    func testAlarmUpdateStopsSupersededWatchdogThatFiresAfterAGoodFix() async throws {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog(retryDelay: .seconds(30))
        let observer = Task { await watchdog.observeAlarmChanges() }
        defer { observer.cancel() }
        let initial = expectation(description: "initial watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        await waitFor(initial)
        let original = try XCTUnwrap(system.pending.keys.first)

        system.advance(by: 119.75)
        system.removeFailures = 1
        let failed = expectation(description: "couldn't remove the old watchdog")
        system.onFailedRemove = { _ in failed.fulfill() }
        system.onSchedule = nil
        watchdog.renew(fixAge: 0, assessment: .withinOrUncertain)
        await waitFor(failed)

        system.advance(by: 0.25)
        system.pending.removeValue(forKey: original)
        system.sounding.insert(original)
        let stopped = expectation(description: "stale alarm stopped before the scheduled retry")
        system.onRemove = { id in
            XCTAssertEqual(id, original)
            stopped.fulfill()
        }
        system.emitChange()
        await waitFor(stopped)

        XCTAssertTrue(system.sounding.isEmpty)
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertTrue(watchdog.hasSystemAlarm)
    }

    func testNextFixRetriesDisarmCleanupWithoutWaitingForBackoff() async throws {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog(retryDelay: .seconds(30))
        let initial = expectation(description: "watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        await waitFor(initial)
        let original = try XCTUnwrap(system.pending.keys.first)

        system.advance(by: 119.75)
        system.removeFailures = 2
        let failed = expectation(description: "immediate and queued disarm cancellations failed")
        failed.expectedFulfillmentCount = 2
        system.onFailedRemove = { _ in failed.fulfill() }
        watchdog.stop()
        await waitFor(failed)

        let removed = expectation(description: "next fix retried disarm cleanup")
        system.onRemove = { id in
            XCTAssertEqual(id, original)
            removed.fulfill()
        }
        watchdog.renew(fixAge: 0, assessment: .unusable)
        await waitFor(removed)
        XCTAssertTrue(system.pending.isEmpty)
        XCTAssertFalse(watchdog.hasSystemAlarm)
    }

    func testForegroundFindsRingingStrayAndTheAppCanStopItIfCleanupFails() async throws {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog(retryDelay: .seconds(30))
        let initial = expectation(description: "watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        await waitFor(initial)
        let original = try XCTUnwrap(system.pending.keys.first)

        system.removeFailures = 3
        let failed = expectation(description: "both disarm cancellations failed")
        failed.expectedFulfillmentCount = 2
        system.onFailedRemove = { _ in failed.fulfill() }
        watchdog.stop()
        await waitFor(failed)

        system.pending.removeValue(forKey: original)
        system.sounding.insert(original)
        let foreground = expectation(description: "foreground tried to stop the ringing alarm")
        system.onFailedRemove = { _ in foreground.fulfill() }
        watchdog.reconcile()
        await waitFor(foreground)
        XCTAssertTrue(watchdog.hasStraySoundingAlarm)

        watchdog.stopStrayAlarms()
        XCTAssertTrue(system.sounding.isEmpty)
        XCTAssertFalse(watchdog.hasStraySoundingAlarm)
        XCTAssertFalse(watchdog.hasSystemAlarm)
    }

    func testRenewalCancellationFailureKeepsReplacementAndRetriesCleanup() async {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog()
        let started = expectation(description: "initial watchdog installed")
        system.onSchedule = { _ in started.fulfill() }
        watchdog.start()
        await waitFor(started)

        system.advance(by: 10)
        system.removeFailures = 1
        let removed = expectation(description: "old fallback removed on retry")
        system.onRemove = { _ in removed.fulfill() }
        system.onSchedule = nil
        watchdog.renew(fixAge: 0, assessment: .withinOrUncertain)
        await waitFor(removed)

        XCTAssertEqual(system.failedRemovals, 1)
        XCTAssertEqual(system.pendingAtSchedule, [0, 1])
        XCTAssertEqual(Array(system.pending.values), [system.wallTime.addingTimeInterval(150)])
    }

    func testClockRollbackReprojectsMonotonicDeadlineWithoutAUsableFix() async {
        let system = FakeAlarms()
        let watchdog = system.makeWatchdog()
        let initial = expectation(description: "initial watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        watchdog.start()
        await waitFor(initial)

        // A time-zone-only event leaves both UTC and elapsed time in agreement.
        system.advance(by: 20)
        let checked = expectation(description: "time-zone change reconciled")
        system.onSnapshot = { checked.fulfill() }
        watchdog.reconcile()
        await waitFor(checked)
        system.onSnapshot = nil
        XCTAssertEqual(system.attempts.count, 1)

        system.wallTime.addTimeInterval(-3_600)
        let corrected = expectation(description: "wall date shifted back with clock")
        system.onSchedule = { _ in corrected.fulfill() }
        watchdog.reconcile()
        await waitFor(corrected)
        XCTAssertEqual(Array(system.pending.values), [system.wallTime.addingTimeInterval(100)])
    }

    func testRelaunchAfterRollbackUsesPersistedElapsedDeadline() async throws {
        let system = FakeAlarms()
        let suite = "AnchorGPSWatchdogTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = expectation(description: "initial watchdog installed")
        system.onSchedule = { _ in initial.fulfill() }
        system.makeWatchdog(defaults: defaults).start()
        await waitFor(initial)

        system.advance(by: 130)
        system.wallTime.addTimeInterval(-3_600)
        let restored = system.makeWatchdog(defaults: defaults)
        let corrected = expectation(description: "overdue restored watchdog scheduled immediately")
        system.onSchedule = { _ in corrected.fulfill() }
        restored.start(restoring: true)
        await waitFor(corrected)

        XCTAssertEqual(Array(system.pending.values), [system.wallTime.addingTimeInterval(1)])
        XCTAssertTrue(restored.hasSystemAlarm)
    }

    private func waitFor(_ event: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        XCTAssertEqual(result, .completed)
    }

    @MainActor
    private final class FakeAlarms {
        private enum Failure: Error { case schedule, remove }

        var wallTime = Date(timeIntervalSince1970: 10_000)
        var uptime = 1_000.0
        var failScheduleAttempts: Set<Int> = []
        var removeFailures = 0
        var failedRemovals = 0
        var pending: [UUID: Date] = [:]
        var sounding: Set<UUID> = []
        var attempts: [(id: UUID, deadline: Date)] = []
        var pendingAtSchedule: [Int] = []
        var holdFirstSchedule = false
        var onSnapshot: (() -> Void)?
        var onSchedule: ((Int) -> Void)?
        var onRemove: ((UUID) -> Void)?
        var onFailedRemove: ((UUID) -> Void)?
        private var firstSchedule: CheckedContinuation<Void, Never>?
        private let changes = AsyncStream<Void>.makeStream()

        func makeWatchdog(
            defaults: UserDefaults? = nil, retryDelay: Duration = .milliseconds(20),
            checkInterval: Duration = .seconds(15)
        ) -> AnchorGPSWatchdog {
            AnchorGPSWatchdog(
                system: driver, clock: { .init(uptime: self.uptime, wallTime: self.wallTime) },
                defaults: defaults, retryDelay: retryDelay, checkInterval: checkInterval)
        }

        func advance(by interval: TimeInterval) {
            wallTime.addTimeInterval(interval)
            uptime += interval
        }

        var driver: AnchorGPSWatchdog.SystemAlarms {
            .init(
                snapshot: {
                    self.onSnapshot?()
                    return .init(pending: self.pending, sounding: self.sounding)
                },
                schedule: { id, deadline in
                    let attempt = self.attempts.count + 1
                    self.attempts.append((id, deadline))
                    self.pendingAtSchedule.append(self.pending.count)
                    if self.failScheduleAttempts.contains(attempt) {
                        self.onSchedule?(attempt)
                        throw Failure.schedule
                    }
                    if attempt == 1, self.holdFirstSchedule {
                        await withCheckedContinuation { continuation in
                            self.firstSchedule = continuation
                            self.onSchedule?(attempt)
                        }
                        self.pending[id] = deadline
                    } else {
                        self.pending[id] = deadline
                        self.onSchedule?(attempt)
                    }
                },
                remove: { id, mode in
                    guard self.pending[id] != nil || (mode == .any && self.sounding.contains(id)) else { return }
                    if self.removeFailures > 0 {
                        self.removeFailures -= 1
                        self.failedRemovals += 1
                        self.onFailedRemove?(id)
                        throw Failure.remove
                    }
                    self.pending.removeValue(forKey: id)
                    if mode == .any { self.sounding.remove(id) }
                    self.onRemove?(id)
                },
                observeChanges: { changed in
                    for await _ in self.changes.stream { changed() }
                }
            )
        }

        func emitChange() {
            changes.continuation.yield()
        }

        func resumeFirstSchedule() {
            firstSchedule?.resume()
            firstSchedule = nil
        }
    }
}
