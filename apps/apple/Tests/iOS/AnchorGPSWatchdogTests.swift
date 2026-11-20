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
        let watchdog = AnchorGPSWatchdog(system: system.driver)
        let firstArm = Date.now
        watchdog.start()
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(startedResult, .completed)

        watchdog.stop()
        watchdog.start()
        watchdog.stop()
        let lastArm = Date.now
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
        let first = AnchorGPSWatchdog(system: system.driver)
        first.start()
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(startedResult, .completed)
        let original = try XCTUnwrap(system.pending.first)

        let read = expectation(description: "restored watchdog read the existing alarm")
        system.onSnapshot = { read.fulfill() }
        let restored = AnchorGPSWatchdog(system: system.driver)
        restored.start(restoring: true)
        let readResult = await XCTWaiter.fulfillment(of: [read], timeout: 5)
        XCTAssertEqual(readResult, .completed)
        system.onSnapshot = nil
        XCTAssertEqual(system.attempts.count, 1)
        XCTAssertEqual(system.pending[original.key], original.value)

        system.pending.removeValue(forKey: original.key)
        system.sounding = [original.key]
        let renewed = expectation(description: "first usable fix assigned another slot")
        system.onSchedule = { _ in renewed.fulfill() }
        restored.renew(fixAt: .now)
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
        let watchdog = AnchorGPSWatchdog(system: system.driver)
        let restoredAt = Date.now
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
        let watchdog = AnchorGPSWatchdog(system: system.driver)
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
        watchdog.renew(fixAt: .now + .seconds(2))
        let renewedResult = await XCTWaiter.fulfillment(of: [renewed, removed], timeout: 5, enforceOrder: true)
        XCTAssertEqual(renewedResult, .completed)
        XCTAssertEqual(system.pendingAtSchedule, [0, 1])
        XCTAssertEqual(system.pending.count, 1)
        XCTAssertNil(system.pending[original.key])
    }

    @MainActor
    private final class FakeAlarms {
        var pending: [UUID: Date] = [:]
        var sounding: Set<UUID> = []
        var attempts: [(id: UUID, deadline: Date)] = []
        var pendingAtSchedule: [Int] = []
        var holdFirstSchedule = false
        var onSnapshot: (() -> Void)?
        var onSchedule: ((Int) -> Void)?
        var onRemove: ((UUID) -> Void)?
        private var firstSchedule: CheckedContinuation<Void, Never>?

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
                    self.pending.removeValue(forKey: id)
                    if mode == .any { self.sounding.remove(id) }
                    self.onRemove?(id)
                }
            )
        }

        func resumeFirstSchedule() {
            firstSchedule?.resume()
            firstSchedule = nil
        }
    }
}
