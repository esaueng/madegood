import Foundation
import Testing

@testable import WaterKit

@Suite struct VoyageTests {
    @Test func reopensAndFinishesTheSameLegAfterATornWrite() throws {
        let folder = try TempFolder()
        var store = try VoyageStore(root: folder.url)
        let voyage = try store.createVoyage(named: "  Synthetic passage  ")
        let leg = try store.startLeg(in: voyage.id, at: 100)
        try store.record(fix(101))
        try store.record(fix(109))

        // Simulate termination halfway through an append, after two complete writes.
        let journal = folder.url.appendingPathComponent("\(leg.id.uuidString.lowercased()).ndjson")
        let committed = try Data(contentsOf: journal)
        try (committed + Data("{\"position\":".utf8)).write(to: journal)

        var recovered = try VoyageStore(root: folder.url)
        #expect(recovered.activeVoyage?.id == voyage.id)
        #expect(recovered.activeVoyage?.name == "Synthetic passage")
        #expect(recovered.activeLeg?.id == leg.id)
        #expect(recovered.activeFixCount == 2)
        #expect(recovered.activeLastFix == fix(109))
        #expect(recovered.activeLatestGap == nil)
        #expect(try Data(contentsOf: journal) == committed)
        #expect(throws: VoyageStore.StoreError.self) { try recovered.startLeg(in: voyage.id, at: 112) }

        try recovered.resumeLeg(at: 120)
        try recovered.record(fix(119))  // A cached location before Resume.
        try recovered.record(fix(121))
        try recovered.record(fix(121))  // Redelivered location.
        #expect(recovered.activeFixCount == 3)
        #expect(recovered.activeLastFix == fix(121))
        #expect(recovered.activeLatestGap == VoyageGap(start: 109, end: 121))

        var restarted = try VoyageStore(root: folder.url)
        #expect(restarted.activeLeg?.id == leg.id)
        #expect(restarted.activeLastFix == fix(121))
        #expect(restarted.activeLatestGap == VoyageGap(start: 109, end: 121))
        try restarted.resumeLeg(at: 121)
        try restarted.record(fix(121))
        let finished = try restarted.endLeg(at: 121)
        #expect(finished.id == leg.id)
        #expect(finished.endedAt == 121)
        #expect(finished.endingGap == nil)
        #expect(restarted.activeLastFix == nil)
        #expect(restarted.activeLatestGap == nil)

        var reopened = try VoyageStore(root: folder.url)
        #expect(reopened.activeLeg == nil)
        let savedLeg = try #require(reopened.voyages.first?.legs.first)
        #expect(savedLeg.id == leg.id)
        let track = try reopened.track(for: savedLeg)
        #expect(track.map(\.position.timestamp) == [101, 109, 121])
        #expect(track.compactMap(\.gapBefore) == [VoyageGap(start: 109, end: 121)])
        let nextLeg = try reopened.startLeg(in: voyage.id, at: 124)
        #expect(nextLeg.id != leg.id)
        #expect(reopened.activeVoyage?.id == voyage.id)
    }

    @Test func endingAnEmptyLegAfterAClockChangeKeepsTheIntervalValid() throws {
        let folder = try TempFolder()
        var store = try VoyageStore(root: folder.url)
        let voyage = try store.createVoyage(named: "Synthetic passage")
        let leg = try store.startLeg(in: voyage.id, at: 100)
        let finished = try store.endLeg(at: 90)
        #expect(finished.endedAt == leg.startedAt)
        #expect(try store.track(for: finished).isEmpty)
    }

    @Test func canEndAnInterruptedLegWithoutResuming() throws {
        let folder = try TempFolder()
        var store = try VoyageStore(root: folder.url)
        let voyage = try store.createVoyage(named: "Synthetic passage")
        let leg = try store.startLeg(in: voyage.id, at: 100)
        try store.record(fix(102))

        var recovered = try VoyageStore(root: folder.url)
        let finished = try recovered.endLeg(at: 120)
        #expect(finished.id == leg.id)
        #expect(try recovered.track(for: finished).map(\.position.timestamp) == [102])
        let reopened = try VoyageStore(root: folder.url)
        #expect(reopened.voyages.first?.legs.first?.endingGap == VoyageGap(start: 102, end: 120))
    }

    @Test func canRetryAfterAWriteFailure() throws {
        let folder = try TempFolder()
        var store = try VoyageStore(root: folder.url)
        let voyage = try store.createVoyage(named: "Synthetic passage")
        let leg = try store.startLeg(in: voyage.id, at: 100)
        let journal = folder.url.appendingPathComponent("\(leg.id.uuidString.lowercased()).ndjson")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)

        #expect(throws: CocoaError.self) { try store.record(fix(101)) }
        #expect(store.activeFixCount == 0)
        #expect(store.activeLeg?.id == leg.id)

        try FileManager.default.removeItem(at: journal)
        try store.resumeLeg(at: 108)
        try store.record(fix(109))
        let track = try store.track(for: leg)
        #expect(track.map(\.position.timestamp) == [109])
        #expect(track.compactMap(\.gapBefore) == [VoyageGap(start: 100, end: 109)])
    }

    @Test func storesUnderwayAndTurningSamplesAtDifferentCadences() {
        var sampling = VoyageSampling(startedAt: 100, acceptsFrom: 100, lastSaved: nil, interrupted: false)
        let points = (100...124).compactMap { second in
            // Crossing north by 2° is not a turn. The later 31° change is.
            sampling.ingest(fix(Double(second), course: second < 104 ? 359 : second < 113 ? 1 : 32))
        }
        #expect(points.map(\.position.timestamp) == [100, 108, 113, 121])
        #expect(points.compactMap(\.gapBefore).isEmpty)
    }

    @Test func reducesStationaryWritesAndPicksUpMovement() {
        var sampling = VoyageSampling(startedAt: 100, acceptsFrom: 100, lastSaved: nil, interrupted: false)
        let points = (100...233).compactMap { second in
            sampling.ingest(fix(Double(second), speed: second < 225 ? 0.1 : 3))
        }
        #expect(points.map(\.position.timestamp) == [100, 160, 220, 225, 233])
        #expect(points.compactMap(\.gapBefore).isEmpty)
    }

    @Test func separatesPositionOutagesFromKnownStationaryPauses() {
        var sampling = VoyageSampling(startedAt: 100, acceptsFrom: 100, lastSaved: nil, interrupted: false)
        #expect(sampling.ingest(fix(100, speed: 0)) != nil)
        #expect(sampling.ingest(fix(101, speed: 0)) == nil)
        sampling.stationaryPause = true
        #expect(sampling.ingest(fix(175))?.gapBefore == nil)
        #expect(sampling.ingest(fix(190, accuracy: 500)) == nil)
        #expect(sampling.ingest(fix(174)) == nil)
        #expect(sampling.ingest(fix(210))?.gapBefore == VoyageGap(start: 175, end: 210))
    }

    private func fix(_ time: Double, speed: Double? = 3, course: Double? = 90, accuracy: Double = 5) -> VoyagePosition {
        VoyagePosition(
            timestamp: time, latitude: 0, longitude: 0, horizontalAccuracy: accuracy, speed: speed, course: course)
    }
}
