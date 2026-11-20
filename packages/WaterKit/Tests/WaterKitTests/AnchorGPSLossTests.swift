import Testing

@testable import WaterKit

struct AnchorGPSLossTests {
    @Test func armingSetsATwoMinuteDeadlineWithoutAnyFix() throws {
        var loss = AnchorGPSLoss()
        let armedAt = ContinuousClock.now

        loss.arm(at: armedAt)

        let request = try #require(loss.request)
        #expect(request.deadline == armedAt + .seconds(120))
        #expect(loss.isCurrent(request))
    }

    @Test func rearmingWithGPSAlreadyLostStartsAFullNewTimeout() throws {
        var loss = AnchorGPSLoss()
        let start = ContinuousClock.now
        loss.arm(at: start)
        let first = try #require(loss.request)

        loss.disarm()
        let rearmedAt = start + .seconds(40)
        loss.arm(at: rearmedAt)

        let second = try #require(loss.request)
        #expect(second.deadline == rearmedAt + .seconds(120))
        #expect(second.deadline > first.deadline)
        #expect(!loss.isCurrent(first))
        #expect(loss.isCurrent(second))
    }

    @Test func rapidCyclesLeaveOnlyTheLatestArmingCurrent() throws {
        var loss = AnchorGPSLoss()
        let now = ContinuousClock.now
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
        let armedAt = ContinuousClock.now
        loss.arm(at: armedAt)
        let initial = try #require(loss.request)
        loss.recordUsableFix(at: armedAt - .seconds(1))
        #expect(loss.request == initial)

        let fixAt = armedAt + .seconds(2)
        loss.recordUsableFix(at: fixAt)
        let renewed = try #require(loss.request)
        #expect(renewed.deadline == fixAt + .seconds(120))
        #expect(renewed.generation == initial.generation)

        loss.recordUsableFix(at: fixAt + .seconds(14))
        #expect(loss.request == renewed)
        loss.recordUsableFix(at: fixAt + .seconds(15))
        #expect(loss.request?.deadline == fixAt + .seconds(135))
    }

    @Test func restoreCanKeepTheExistingSystemAlarmUntilAUsableFix() throws {
        var loss = AnchorGPSLoss()
        let restoredAt = ContinuousClock.now
        loss.arm(at: restoredAt, restoring: true)
        let restored = try #require(loss.request)
        #expect(restored.preservesExistingAlarm)
        #expect(restored.deadline == restoredAt + .seconds(120))

        loss.recordUsableFix(at: restoredAt + .seconds(1))
        #expect(loss.request?.preservesExistingAlarm == false)
    }
}
