import Testing

@testable import WaterKit

struct AnchorGPSLossTests {
    @Test func armingSetsATwoMinuteDeadlineWithoutAnyFix() throws {
        var loss = AnchorGPSLoss()
        let armedAt = 1_000.0

        loss.arm(at: armedAt)

        let request = try #require(loss.request)
        #expect(request.deadline == armedAt + 120)
        #expect(loss.isCurrent(request))
    }

    @Test func rearmingWithGPSAlreadyLostStartsAFullNewTimeout() throws {
        var loss = AnchorGPSLoss()
        let start = 1_000.0
        loss.arm(at: start)
        let first = try #require(loss.request)

        loss.disarm()
        let rearmedAt = start + 40
        loss.arm(at: rearmedAt)

        let second = try #require(loss.request)
        #expect(second.deadline == rearmedAt + 120)
        #expect(second.deadline > first.deadline)
        #expect(!loss.isCurrent(first))
        #expect(loss.isCurrent(second))
    }

    @Test func rapidCyclesLeaveOnlyTheLatestArmingCurrent() throws {
        var loss = AnchorGPSLoss()
        let now = 1_000.0
        var requests: [AnchorGPSLoss.Request] = []
        for _ in 0..<3 {
            loss.arm(at: now)
            let request = try #require(loss.request)
            requests.append(request)
            loss.disarm()
            #expect(loss.request == nil)
            #expect(!loss.isCurrent(request))
        }

        loss.arm(at: now)
        requests.append(try #require(loss.request))

        #expect(requests.filter { loss.isCurrent($0) } == [requests[3]])
    }

    @Test func firstUsableFixResetsTheDeadlineEvenInsideTheRenewalInterval() throws {
        var loss = AnchorGPSLoss()
        let armedAt = 1_000.0
        loss.arm(at: armedAt)
        let initial = try #require(loss.request)
        loss.recordFix(at: armedAt - 1, assessment: .withinOrUncertain)
        #expect(loss.request == initial)

        let fixAt = armedAt + 2
        loss.recordFix(at: fixAt, assessment: .withinOrUncertain)
        let renewed = try #require(loss.request)
        #expect(renewed.deadline == fixAt + 120)
        #expect(renewed.generation == initial.generation)

        loss.recordFix(at: fixAt + 29, assessment: .withinOrUncertain)
        #expect(loss.request == renewed)
        loss.recordFix(at: fixAt + 30, assessment: .withinOrUncertain)
        #expect(loss.request?.deadline == fixAt + 150)
    }

    @Test func restoreCanKeepTheExistingSystemAlarmUntilAUsableFix() throws {
        var loss = AnchorGPSLoss()
        let restoredAt = 1_000.0
        loss.arm(at: restoredAt, restoring: true)
        let restored = try #require(loss.request)
        #expect(restored.preservesExistingAlarm)
        #expect(restored.deadline == restoredAt + 120)

        loss.recordFix(at: restoredAt + 1, assessment: .withinOrUncertain)
        #expect(loss.request?.preservesExistingAlarm == false)
    }
    @Test func healthyFixesRequireAtMost120RenewalsPerHour() {
        var loss = AnchorGPSLoss()
        loss.arm(at: 0)
        var renewals = 0
        for second in 1...3_600 {
            let previous = loss.request
            loss.recordFix(at: Double(second), assessment: .withinOrUncertain)
            if loss.request != previous { renewals += 1 }
            let remaining = (loss.request?.deadline ?? 0) - Double(second)
            #expect((90...120).contains(remaining))
        }
        #expect(renewals == 120)
    }

    @Test func checkpointPreservesElapsedTimeAcrossRelaunch() throws {
        var loss = AnchorGPSLoss()
        loss.arm(at: 1_000)
        let checkpoint = try #require(loss.checkpoint(at: 1_020))
        var restored = AnchorGPSLoss()
        restored.arm(at: 1_070, restoring: true, checkpoint: checkpoint)
        let request = try #require(restored.request)
        #expect(request.delay(at: 1_070) == 50)
        #expect(request.delay(at: 1_121) == 1)
        #expect(request.matches(remaining: 50, at: 1_070))
        #expect(!request.matches(remaining: 3_650, at: 1_070))

        restored.arm(at: 10, restoring: true, checkpoint: checkpoint)
        #expect(restored.request?.delay(at: 10) == 1)
    }

}
