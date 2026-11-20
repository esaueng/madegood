import Foundation
import Testing

@testable import WaterKit

struct AnchorAlarmTests {
    private let anchor = AnchorAlarm.Point(latitude: 0, longitude: 179.9999)!

    private func fix(_ time: Double, _ distance: Double, accuracy: Double? = 5) -> GPSFix {
        let point = Geo.destination(lat: anchor.latitude, lon: anchor.longitude, bearing: 90, distance: distance)
        return GPSFix(t: time, latitude: point.lat, longitude: point.lon, horizontalAccuracy: accuracy)
    }

    @Test func readingLooksBackAcrossAntimeridian() throws {
        let alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        let sample = fix(0, 40)
        let boat = try #require(AnchorAlarm.Point(latitude: sample.latitude, longitude: sample.longitude))
        #expect(boat.longitude < 0)
        let reading = alarm.reading(at: boat)
        #expect(abs(reading.distance - 40) < 0.001)
        #expect(abs(try #require(reading.bearing) - 270) < 0.001)
        #expect(alarm.reading(at: anchor).bearing == nil)
        #expect(AnchorAlarm(anchor: anchor, radius: .nan) == nil)
        #expect(AnchorAlarm.Point(latitude: 91, longitude: 0) == nil)
    }

    @Test func outsideNeedsBothTimeAndThreeDistinctFixes() throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        #expect(alarm.ingest(fix(0, 50)) == false)
        #expect(alarm.ingest(fix(2, 50)) == false)
        #expect(alarm.ingest(fix(4, 50)) == false)
        #expect(alarm.ingest(fix(10, 50)) == true)
        #expect(alarm.ingest(fix(12, 2)) == false)
        #expect(alarm.isDrifting)
        alarm.acknowledge()
        #expect(!alarm.isDrifting)
        #expect(alarm.ingest(fix(13, 50)) == false)
        #expect(alarm.ingest(fix(24, 50)) == false)
        #expect(alarm.ingest(fix(24, 50)) == false)
        #expect(alarm.ingest(fix(22, 50)) == false)
        #expect(alarm.ingest(fix(25, 50)) == true)
    }

    @Test(arguments: [5.0, 15.0, 30.0, 60.0])
    func sustainedDriftWorksWithSparseFixes(interval: Double) throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        #expect(alarm.ingest(fix(0, 50)) == false)
        #expect(alarm.ingest(fix(interval, 50)) == false)
        #expect(alarm.ingest(fix(2 * interval, 50)) == true)
    }

    @Test func outsideEvidenceExpiresAcrossAGPSGap() throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 10))
        #expect(alarm.assess(fix(0, 14, accuracy: 2)) == .outside)
        #expect(alarm.assess(fix(5, 14, accuracy: 2)) == .outside)
        #expect(alarm.assess(fix(605, 12, accuracy: 1)) == .outside)
        #expect(alarm.assess(fix(610, 14, accuracy: 2)) == .outside)
        #expect(alarm.assess(fix(615, 14, accuracy: 2)) == .driftConfirmed)
    }

    @Test func usableFixOverlappingTheBoundaryBreaksEvidence() throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        #expect(alarm.ingest(fix(0, 50)) == false)
        #expect(alarm.ingest(fix(5, 50)) == false)
        #expect(alarm.ingest(fix(11, 33)) == false)
        #expect(alarm.ingest(fix(12, 50)) == false)
        #expect(alarm.ingest(fix(17, 50)) == false)
        #expect(alarm.ingest(fix(22, 50)) == true)
    }

    @Test(arguments: [26.0, -1.0, nil] as [Double?])
    func weakFixesDoNotHideSustainedDrift(accuracy: Double?) throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        #expect(alarm.ingest(fix(0, 50)) == false)
        #expect(alarm.ingest(fix(3, 300, accuracy: accuracy)) == false)
        #expect(alarm.ingest(fix(5, 50)) == false)
        #expect(alarm.ingest(fix(8, 300, accuracy: accuracy)) == false)
        #expect(alarm.ingest(fix(10, 50)) == true)
    }

    @Test func sparseOutsideFixesConfirmDriftAndNeverPostponeTheWatchdog() throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 10))
        var loss = AnchorGPSLoss()
        loss.arm(at: 0)
        let original = try #require(loss.request)
        var alertTimes: [Double] = []
        for minute in 0...60 {
            let time = Double(minute * 60)
            let assessment = alarm.assess(fix(time, 111, accuracy: 5))
            if assessment == .driftConfirmed { alertTimes.append(time) }
            loss.recordFix(at: time, assessment: assessment)
            #expect(loss.request == original)
        }
        #expect(alertTimes == [120])
        #expect(original.deadline == 120)
    }

    @Test func usableFixAfterGPSLossCanBreakEvidence() throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        #expect(alarm.ingest(fix(0, 50)) == false)
        #expect(alarm.ingest(fix(5, 50)) == false)
        #expect(alarm.ingest(fix(30, 55, accuracy: 40)) == false)
        #expect(alarm.ingest(fix(60, 30)) == false)
        #expect(alarm.ingest(fix(65, 50)) == false)
        #expect(alarm.ingest(fix(70, 50)) == false)
        #expect(alarm.ingest(fix(75, 50)) == true)
    }

    @Test func hoursOfSwingAndIsolatedJumpsStayQuiet() throws {
        var alarm = try #require(AnchorAlarm(anchor: anchor, radius: 30))
        for second in 0..<(12 * 3600) {
            let distance = second.isMultiple(of: 67) ? 55 : 27 + 6 * sin(Double(second) / 23)
            if alarm.ingest(fix(Double(second), distance)) {
                Issue.record("Unexpected drift at second \(second)")
                return
            }
        }
        #expect(!alarm.isDrifting)
    }
}
