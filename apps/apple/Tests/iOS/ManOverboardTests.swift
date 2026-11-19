import CoreLocation
import Foundation
import WaterKit
import XCTest

@testable import MadeGood

/// The iPhone's man-overboard rules: guidance geometry (shared with the watch), position
/// age, marking without a session, several marks, following the watch's marks by ID and
/// snapshot sequence, location problems, and the mirror and Live Activity formats.
@MainActor
final class ManOverboardTests: XCTestCase {
    // A fake position in open water, like the anonymized fixtures.
    private let origin = (lat: 10.0, lon: -30.0)
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let session = UUID()

    override func setUp() async throws {
        suiteName = "ManOverboardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeManOverboard() -> ManOverboard {
        let manOverboard = ManOverboard(defaults: defaults)
        manOverboard.lastKnownPosition = { nil }
        return manOverboard
    }

    private func mark(
        at offset: (bearing: Double, distance: Double), markedAt: Double = 1_000, id: UUID? = UUID()
    ) -> ManOverboard.Mark {
        let point = Geo.destination(
            lat: origin.lat, lon: origin.lon, bearing: offset.bearing, distance: offset.distance)
        let date = Date(timeIntervalSince1970: markedAt)
        return ManOverboard.Mark(
            id: id, latitude: point.lat, longitude: point.lon, markedAt: date, positionAt: date, positionAge: 0)
    }

    private func position(speed: Double?, course: Double?) -> ManOverboard.Position {
        let at = Date(timeIntervalSince1970: 1_010)
        return ManOverboard.Position(
            latitude: origin.lat, longitude: origin.lon, at: at, speed: speed, course: course, receivedAt: at)
    }

    private func freshFix() -> ManOverboard.Position {
        ManOverboard.Position(latitude: origin.lat, longitude: origin.lon, at: Date())
    }

    // MARK: Guidance

    func testArrowIsRelativeToCourseWhileMoving() {
        let guidance = ManOverboard.guidance(from: position(speed: 2, course: 90), to: mark(at: (0, 200)))
        XCTAssertEqual(guidance.distance, 200, accuracy: 1)
        XCTAssertEqual(guidance.bearing, 0, accuracy: 0.5)
        XCTAssertTrue(guidance.isCourseRelative)
        // Mark due north while heading east: 90° to port.
        XCTAssertEqual(guidance.arrow, -90, accuracy: 0.5)
    }

    func testArrowPointsFromNorthWhenSlowOrWithoutCourse() {
        let target = mark(at: (225, 150))
        let fixes = [
            position(speed: 0.4, course: 90), position(speed: 3, course: nil), position(speed: nil, course: 90),
        ]
        for fix in fixes {
            let guidance = ManOverboard.guidance(from: fix, to: target)
            XCTAssertFalse(guidance.isCourseRelative)
            XCTAssertEqual(guidance.bearing, 225, accuracy: 0.5)
            XCTAssertEqual(guidance.arrow, guidance.bearing)
        }
    }

    // MARK: Position age

    func testALateDeliveredFixIsOldFromItsOwnTimestamp() {
        // Measured 30 s before it arrived: stale on arrival, and marked with its real age.
        let now = Date(timeIntervalSince1970: 5_000)
        let late = ManOverboard.Position(
            latitude: origin.lat, longitude: origin.lon, at: now.addingTimeInterval(-30), receivedAt: now,
            receivedUptime: 100)
        XCTAssertEqual(late.age(atUptime: 100), 30, accuracy: 0.001)
        XCTAssertFalse(ManOverboard.isFresh(late, atUptime: 100))

        let marked = ManOverboard.makeMark(from: late, markedAt: now, uptime: 102)
        XCTAssertEqual(marked.positionAge, 32, accuracy: 0.001)
        XCTAssertTrue(marked.isFromStalePosition)
        XCTAssertEqual(ManOverboardNotes.markQuality(marked), "Marked from a position 32 s old")
    }

    func testAgeAdvancesOnTheMonotonicClockNotTheWallClock() {
        let now = Date(timeIntervalSince1970: 5_000)
        let fix = ManOverboard.Position(
            latitude: origin.lat, longitude: origin.lon, at: now, receivedAt: now, receivedUptime: 100)
        XCTAssertTrue(ManOverboard.isFresh(fix, atUptime: 110))
        XCTAssertFalse(ManOverboard.isFresh(fix, atUptime: 110.5))
        XCTAssertNil(ManOverboardNotes.markQuality(ManOverboard.makeMark(from: fix, markedAt: now, uptime: 101)))
    }

    func testAPressWithAStalePositionStillMarksAndSaysHowOld() {
        let manOverboard = makeManOverboard()
        manOverboard.update(
            ManOverboard.Position(latitude: origin.lat, longitude: origin.lon, at: Date().addingTimeInterval(-40)))
        guard case .marked(let marked) = manOverboard.press() else { return XCTFail("did not mark") }
        XCTAssertGreaterThanOrEqual(marked.positionAge, 40)
        XCTAssertNil(manOverboard.guidance(), "no guidance from a stale fix")
        XCTAssertTrue(ManOverboardNotes.markQuality(marked)?.hasPrefix("Marked from a position 4") == true)
    }

    // MARK: Marking without a session

    func testAPressWithNoPositionMarksTheFirstFix() throws {
        let manOverboard = makeManOverboard()
        let pressed = Date().addingTimeInterval(-5)
        XCTAssertEqual(manOverboard.press(at: pressed), .awaitingFix)
        XCTAssertTrue(manOverboard.isActive)
        XCTAssertNil(manOverboard.mark)
        manOverboard.stopOwnUpdates()

        // The press survives a relaunch while it waits.
        let relaunched = makeManOverboard()
        XCTAssertEqual(relaunched.awaitingFixSince, pressed)

        relaunched.update(freshFix())
        let marked = try XCTUnwrap(relaunched.mark)
        XCTAssertEqual(marked.markedAt, pressed)
        XCTAssertNil(marked.origin)
        XCTAssertNil(relaunched.awaitingFixSince)
        XCTAssertEqual(ManOverboardNotes.markQuality(marked), "Position from 5 s after MOB was pressed")
        XCTAssertNotNil(relaunched.guidance())
    }

    /// Re-check finding 1: a press that gets no fix falls back to the last known position,
    /// with its age, instead of waiting forever.
    func testAWaitingPressFallsBackToTheLastKnownPosition() throws {
        let manOverboard = makeManOverboard()
        XCTAssertEqual(manOverboard.press(), .awaitingFix)
        XCTAssertFalse(manOverboard.resolveAwaitingWithLastKnown(), "nothing known yet: keep waiting")
        XCTAssertNotNil(manOverboard.awaitingFixSince)

        manOverboard.lastKnownPosition = {
            ManOverboard.Position(
                latitude: 10.001, longitude: -30.0, at: Date().addingTimeInterval(-60), accuracy: 20)
        }
        XCTAssertTrue(manOverboard.resolveAwaitingWithLastKnown())
        let marked = try XCTUnwrap(manOverboard.mark)
        XCTAssertEqual(marked.latitude, 10.001)
        XCTAssertEqual(marked.isApproximate, true)
        XCTAssertGreaterThanOrEqual(marked.positionAge, 60)
        XCTAssertEqual(ManOverboardNotes.markQuality(marked), "Approximate mark — 1 min old")
        XCTAssertNil(manOverboard.awaitingFixSince)
        manOverboard.stopOwnUpdates()
    }

    /// Final review finding 1: only a recent, accurate cached fix may stand in.
    func testTheFallbackRefusesOldOrInaccurateCachedFixes() {
        let uptime = ProcessInfo.processInfo.systemUptime
        func cached(age: TimeInterval, accuracy: Double?) -> ManOverboard.Position {
            ManOverboard.Position(
                latitude: origin.lat, longitude: origin.lon, at: Date().addingTimeInterval(-age), accuracy: accuracy,
                receivedUptime: uptime)
        }
        XCTAssertTrue(ManOverboard.isUsableFallback(cached(age: 90, accuracy: 30), atUptime: uptime))
        XCTAssertFalse(ManOverboard.isUsableFallback(cached(age: 180, accuracy: 30), atUptime: uptime))
        XCTAssertFalse(ManOverboard.isUsableFallback(cached(age: 30, accuracy: 80), atUptime: uptime))
        XCTAssertFalse(ManOverboard.isUsableFallback(cached(age: 30, accuracy: nil), atUptime: uptime))

        let manOverboard = makeManOverboard()
        XCTAssertEqual(manOverboard.press(), .awaitingFix)
        manOverboard.lastKnownPosition = { cached(age: 600, accuracy: 10) }
        XCTAssertFalse(manOverboard.resolveAwaitingWithLastKnown(), "a 10 min old fix keeps the press waiting")
        XCTAssertNotNil(manOverboard.awaitingFixSince)
        manOverboard.stopOwnUpdates()
    }

    /// Final review finding 1: an approximate mark takes the first fresh fix soon after
    /// the press, and never takes over from a mark made from a real fix.
    func testAnApproximateMarkIsRefinedAndNeverTakesOverARealMark() throws {
        let manOverboard = makeManOverboard()
        let watch = mark(at: (0, 100), markedAt: Date().timeIntervalSince1970 - 30)
        XCTAssertTrue(manOverboard.applyMirrored([watch], sessionID: session, sequence: 1))
        XCTAssertEqual(manOverboard.press(), .awaitingFix)
        manOverboard.lastKnownPosition = {
            ManOverboard.Position(latitude: 10.002, longitude: -30.0, at: Date().addingTimeInterval(-60), accuracy: 20)
        }
        XCTAssertTrue(manOverboard.resolveAwaitingWithLastKnown())
        XCTAssertEqual(manOverboard.mark?.identity, watch.identity, "the real watch mark stays the target")
        let approximate = try XCTUnwrap(manOverboard.otherMarks.first)
        XCTAssertEqual(approximate.isApproximate, true)

        manOverboard.update(freshFix())
        let refined = try XCTUnwrap(manOverboard.marks.first { $0.id == approximate.id })
        XCTAssertNil(refined.isApproximate)
        XCTAssertEqual(refined.latitude, origin.lat)
        XCTAssertEqual(refined.markedAt, approximate.markedAt)
        // Now from a real fix and pressed later, it is the target.
        XCTAssertEqual(manOverboard.mark?.id, approximate.id)
        manOverboard.stopOwnUpdates()
    }

    /// Re-check finding 1: denied, restricted and approximate location are named at once.
    func testLocationProblemsAreRecognizedFromTheAuthorization() {
        XCTAssertEqual(ManOverboard.issue(status: .denied, accuracy: .fullAccuracy), .denied)
        XCTAssertEqual(ManOverboard.issue(status: .restricted, accuracy: .fullAccuracy), .restricted)
        XCTAssertEqual(ManOverboard.issue(status: .authorizedWhenInUse, accuracy: .reducedAccuracy), .reducedAccuracy)
        XCTAssertNil(ManOverboard.issue(status: .authorizedWhenInUse, accuracy: .fullAccuracy))
        XCTAssertNil(ManOverboard.issue(status: .notDetermined, accuracy: .fullAccuracy))
        XCTAssertTrue(ManOverboardNotes.locationIssue(.denied).contains("Settings"))
        XCTAssertTrue(ManOverboardNotes.locationIssue(.reducedAccuracy).contains("Settings"))
    }

    func testClearCancelsAWaitingPress() {
        let manOverboard = makeManOverboard()
        _ = manOverboard.press()
        manOverboard.clear()
        XCTAssertFalse(manOverboard.isActive)
        manOverboard.update(freshFix())
        XCTAssertNil(manOverboard.mark)
    }

    // MARK: Several marks (re-check finding 3)

    func testAWatchMarkNeverDiscardsAWaitingPhonePress() throws {
        let manOverboard = makeManOverboard()
        XCTAssertEqual(manOverboard.press(), .awaitingFix)
        let watch = mark(at: (0, 100))
        XCTAssertTrue(manOverboard.applyMirrored([watch], sessionID: session, sequence: 1))
        XCTAssertNotNil(manOverboard.awaitingFixSince, "the phone press still waits")
        XCTAssertEqual(manOverboard.mark?.origin, .watch)
        XCTAssertEqual(ManOverboardNotes.origin(try XCTUnwrap(manOverboard.mark)), "Marked on Apple Watch")

        // The phone press resolves at its first fix as its own mark, now the target.
        manOverboard.update(freshFix())
        XCTAssertEqual(manOverboard.marks.count, 2)
        XCTAssertNil(manOverboard.mark?.origin)
        XCTAssertEqual(manOverboard.otherMarks.map(\.identity), [watch.identity])
        manOverboard.stopOwnUpdates()
    }

    /// Final review finding 4: the target is the newest press, not the latest arrival.
    func testADelayedOlderWatchMarkDoesNotTakeOverTheTarget() throws {
        let manOverboard = makeManOverboard()
        manOverboard.update(freshFix())
        let phone = try XCTUnwrap(manOverboard.markNow())
        let olderWatch = mark(at: (0, 100), markedAt: phone.markedAt.timeIntervalSince1970 - 60)
        XCTAssertTrue(manOverboard.applyMirrored([olderWatch], sessionID: session, sequence: 1))
        XCTAssertEqual(manOverboard.mark?.identity, phone.identity)
        XCTAssertEqual(manOverboard.notice, "Another mark arrived from Apple Watch.")
        manOverboard.dismissNotice()
        XCTAssertNil(manOverboard.notice)

        // A newer watch press does become the target.
        let newerWatch = mark(at: (90, 100), markedAt: phone.markedAt.timeIntervalSince1970 + 60)
        XCTAssertTrue(manOverboard.applyMirrored([olderWatch, newerWatch], sessionID: session, sequence: 2))
        XCTAssertEqual(manOverboard.mark?.identity, newerWatch.identity)
    }

    func testPressesAFewSecondsApartPreferThisDevicesMark() {
        let local = mark(at: (0, 50), markedAt: 1_000)
        var watch = mark(at: (90, 50), markedAt: 1_003)
        watch.origin = .watch
        XCTAssertEqual(ManOverboard.targetIndex(in: [local, watch], pinned: nil), 0)
        XCTAssertEqual(ManOverboard.targetIndex(in: [watch, local], pinned: nil), 1)
        // Further apart, the newer press wins whichever device made it.
        var later = watch
        later.markedAt = Date(timeIntervalSince1970: 1_010)
        XCTAssertEqual(ManOverboard.targetIndex(in: [local, later], pinned: nil), 1)
        // A pinned choice wins.
        XCTAssertEqual(ManOverboard.targetIndex(in: [local, later], pinned: local.identity), 0)
    }

    /// Final review finding 5: at the limit a new mark is refused, never evicting one.
    func testTheMarkLimitRefusesRatherThanEvicts() {
        let manOverboard = makeManOverboard()
        let watchMarks = (0..<ManOverboard.markLimit).map { mark(at: (Double($0), 100), markedAt: 1_000 + Double($0)) }
        XCTAssertTrue(manOverboard.applyMirrored(watchMarks, sessionID: session, sequence: 1))
        XCTAssertEqual(manOverboard.marks.count, ManOverboard.markLimit)
        manOverboard.update(freshFix())
        XCTAssertEqual(manOverboard.press(), .full)
        XCTAssertEqual(manOverboard.marks.count, ManOverboard.markLimit)
        XCTAssertTrue(manOverboard.notice?.contains("Clear one") == true)
        let extra = mark(at: (200, 100))
        XCTAssertFalse(manOverboard.applyMirrored(watchMarks + [extra], sessionID: session, sequence: 2))
        XCTAssertEqual(Set(manOverboard.marks.map(\.identity)), Set(watchMarks.map(\.identity)))
    }

    /// Final review finding 3: a recording's location problems reach the MOB surfaces.
    func testARecordingsLocationProblemIsShown() {
        let manOverboard = makeManOverboard()
        XCTAssertNil(manOverboard.locationIssue)
        manOverboard.setRecorderLocationIssue(.unavailable)
        XCTAssertEqual(manOverboard.locationIssue, .unavailable)
        manOverboard.setRecorderLocationIssue(nil)
        XCTAssertNil(manOverboard.locationIssue)
        XCTAssertEqual(ManOverboardNotes.waiting(positionAge: 42, hasMark: true), "No GPS — last fix 42 s ago")
    }

    func testTheTargetCanBeChangedAndClearingMovesToTheNext() throws {
        let manOverboard = makeManOverboard()
        manOverboard.update(freshFix())
        let first = try XCTUnwrap(manOverboard.markNow())
        let second = try XCTUnwrap(manOverboard.markNow())
        XCTAssertEqual(manOverboard.mark, second)
        manOverboard.target(first.identity)
        XCTAssertEqual(manOverboard.mark, first)
        manOverboard.clear()
        XCTAssertEqual(manOverboard.marks, [second])
        // And the list outlives a relaunch.
        XCTAssertEqual(makeManOverboard().marks, [second])
    }

    // MARK: Following the watch by mark ID and sequence

    private func update(
        _ incoming: [ManOverboard.Mark]?, clearedByWatch: [UUID]? = nil, sequence: UInt64 = 5,
        held: [ManOverboard.Mark] = [], adopted: [ManOverboard.Adopted] = [], cleared: [ManOverboard.Cleared] = [],
        sessionID: UUID? = nil
    ) -> ManOverboard.MirrorUpdate {
        ManOverboard.mirrorUpdate(
            incoming: incoming, clearedByWatch: clearedByWatch, sessionID: sessionID ?? session, sequence: sequence,
            held: held, adopted: adopted, cleared: cleared)
    }

    func testANewWatchMarkIsAdopted() {
        let watch = mark(at: (0, 100))
        XCTAssertEqual(update([watch]).adopt, [watch])
        // Alongside the phone's own mark, not instead of it.
        let phone = mark(at: (90, 50), markedAt: 2_000)
        XCTAssertEqual(update([watch], held: [phone]).adopt, [watch])
        XCTAssertEqual(update([watch], held: [phone]).clear, [])
    }

    func testAClearedMarkStaysClearedWhateverItsTimestamp() {
        let cleared = mark(at: (0, 100))
        var rounded = cleared
        rounded.markedAt = cleared.markedAt.addingTimeInterval(0.000_1)
        XCTAssertTrue(update([rounded], cleared: [.init(markID: cleared.identity)]).isEmpty)
    }

    func testANewWatchMarkIsAdoptedEvenIfTheWatchClockIsBehind() {
        let cleared = mark(at: (0, 100), markedAt: 2_000)
        let newer = mark(at: (45, 80), markedAt: 1_000)  // the watch clock went backward
        XCTAssertEqual(update([newer], cleared: [.init(markID: cleared.identity)]).adopt, [newer])
    }

    func testAWatchMarkTakenOnceIsNotRetaken() {
        let watch = mark(at: (0, 100))
        let adopted = [ManOverboard.Adopted(markID: watch.identity, sessionID: session, sequence: 3)]
        XCTAssertTrue(update([watch], sequence: 9, adopted: adopted).isEmpty)
    }

    func testClearingOnTheWatchClearsOnlyTheMarkItGave() {
        let watch = mark(at: (0, 100))
        let phone = mark(at: (90, 30))
        let adopted = [ManOverboard.Adopted(markID: watch.identity, sessionID: session, sequence: 3)]
        let clearedA = [watch.identity]
        XCTAssertEqual(
            update([], clearedByWatch: clearedA, sequence: 4, held: [phone, watch], adopted: adopted).clear,
            [watch.identity])
        // Another recording, or an older watch app (no fields), clears nothing.
        XCTAssertTrue(
            update([], clearedByWatch: clearedA, sequence: 4, held: [watch], adopted: adopted, sessionID: UUID())
                .isEmpty)
        XCTAssertTrue(update(nil, sequence: 4, held: [watch], adopted: adopted).isEmpty)
    }

    /// Final review finding 5: a mark missing from a snapshot (a watch at its limit, or
    /// any other omission) is not a clear; only an explicit cleared ID is.
    func testAnOmittedMarkIsNotAClear() {
        let watch = mark(at: (0, 100))
        let adopted = [ManOverboard.Adopted(markID: watch.identity, sessionID: session, sequence: 3)]
        XCTAssertTrue(update([], clearedByWatch: [], sequence: 9, held: [watch], adopted: adopted).isEmpty)
        XCTAssertTrue(update([mark(at: (5, 5))], sequence: 9, held: [watch], adopted: adopted).clear.isEmpty)
    }

    /// Re-check finding 2: a snapshot older than the one that delivered the mark cannot
    /// clear it, even after a relaunch lost the in-memory sequence.
    func testAnOlderCachedSnapshotCannotClearAMarkAfterRelaunch() {
        let watch = mark(at: (0, 100))
        XCTAssertTrue(makeManOverboard().applyMirrored([watch], sessionID: session, sequence: 12))

        let relaunched = makeManOverboard()
        let clearedA = [watch.identity]
        // A cached snapshot from before the mark, even one claiming it cleared, cannot.
        relaunched.applyMirrored([], clearedByWatch: clearedA, sessionID: session, sequence: 11)
        XCTAssertEqual(relaunched.marks.map(\.identity), [watch.identity])
        relaunched.applyMirrored([], clearedByWatch: clearedA, sessionID: session, sequence: 12)
        XCTAssertEqual(relaunched.marks.map(\.identity), [watch.identity])

        // Nor did the old snapshot mark it cleared: it is still held, and a newer
        // snapshot that clears it does.
        relaunched.applyMirrored([], clearedByWatch: clearedA, sessionID: session, sequence: 13)
        XCTAssertTrue(relaunched.marks.isEmpty)
        XCTAssertFalse(makeManOverboard().applyMirrored([watch], sessionID: session, sequence: 14))
    }

    func testAPhoneClearOutlivesARelaunch() {
        let watch = mark(at: (0, 100))
        let first = makeManOverboard()
        XCTAssertTrue(first.applyMirrored([watch], sessionID: session, sequence: 1))
        first.clear()
        let relaunched = makeManOverboard()
        XCTAssertFalse(relaunched.applyMirrored([watch], sessionID: session, sequence: 2))
        XCTAssertTrue(relaunched.marks.isEmpty)
    }

    func testAWatchClearWhileThePhoneWasClosedClearsOnRelaunch() {
        let watch = mark(at: (0, 100))
        XCTAssertTrue(makeManOverboard().applyMirrored([watch], sessionID: session, sequence: 7))
        let relaunched = makeManOverboard()
        XCTAssertEqual(relaunched.mark?.identity, watch.identity)
        relaunched.applyMirrored([], clearedByWatch: [watch.identity], sessionID: session, sequence: 30)
        XCTAssertTrue(relaunched.marks.isEmpty)
        XCTAssertFalse(makeManOverboard().applyMirrored([watch], sessionID: session, sequence: 31))
    }

    // MARK: Legacy marks without an ID (re-check finding 5)

    func testALegacyIdentityIsStableAndUsesTheFixTimeAndAge() throws {
        let legacy = mark(at: (0, 100), id: nil)
        let decoded = try JSONDecoder().decode(ManOverboard.Mark.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.id)
        XCTAssertEqual(decoded.identity, legacy.identity)
        // Same place and press time, a different fix: a different mark.
        var otherFix = legacy
        otherFix.positionAt = legacy.positionAt.addingTimeInterval(-3)
        XCTAssertNotEqual(otherFix.identity, legacy.identity)
        var otherAge = legacy
        otherAge.positionAge = 12
        XCTAssertNotEqual(otherAge.identity, legacy.identity)
    }

    func testAClearedLegacyMarkIsScopedToItsRecording() {
        let legacy = mark(at: (0, 100), id: nil)
        let clearedHere = [ManOverboard.Cleared(markID: legacy.identity, recordingID: session)]
        XCTAssertTrue(update([legacy], cleared: clearedHere).isEmpty)
        // The same values from another recording are another mark.
        XCTAssertEqual(update([legacy], cleared: clearedHere, sessionID: UUID()).adopt, [legacy])
        // A real ID clears everywhere.
        let real = mark(at: (0, 100))
        XCTAssertTrue(update([real], cleared: [.init(markID: real.identity)], sessionID: UUID()).isEmpty)
    }

    func testClearingAnAdoptedLegacyMarkRecordsItsRecording() {
        let legacy = mark(at: (0, 100), id: nil)
        let manOverboard = makeManOverboard()
        XCTAssertTrue(manOverboard.applyMirrored([legacy], sessionID: session, sequence: 1))
        manOverboard.clear()
        let other = UUID()
        XCTAssertTrue(makeManOverboard().applyMirrored([legacy], sessionID: other, sequence: 1))
    }

    // MARK: Formats

    func testMirrorSnapshotsWithAndWithoutTheMarksDecode() throws {
        var readings = LiveReadings(nil)
        readings.speed = 2
        let old = WorkoutMirrorSnapshot(
            sessionID: UUID(), sequence: 1, sport: .sailing, sentAt: Date(timeIntervalSince1970: 1_000),
            readings: readings)
        let oldJSON = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("manOverboard"))
        XCTAssertNil(try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: oldJSON).manOverboardMarks)

        var new = old
        new.manOverboardMarks = [mark(at: (0, 100))]
        let decoded = try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded, new)
        XCTAssertEqual(decoded.manOverboardMarks?.first?.id, new.manOverboardMarks?.first?.id)
    }

    /// The snapshot as builds before the mark list encoded it: only the single target.
    private struct SingleMarkSnapshot: Codable {
        var version = WorkoutMirrorSnapshot.currentVersion
        let sessionID: UUID
        let sequence: UInt64
        let sport: Sport
        let sentAt: Date
        let readings: LiveReadings
        var manOverboard: ManOverboard.Mark?
    }

    /// Final review finding 2: MOB survives a phone and watch on either side of the change.
    func testMarksTravelBetweenOldAndNewSnapshotFormats() throws {
        let target = mark(at: (0, 100))
        let other = mark(at: (90, 50), markedAt: 900)
        // An older watch sends only the single field; a new phone reads it as one mark.
        let old = SingleMarkSnapshot(
            sessionID: session, sequence: 3, sport: .sailing, sentAt: Date(timeIntervalSince1970: 1_000),
            readings: LiveReadings(nil), manOverboard: target)
        let fromOldWatch = try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(fromOldWatch.watchMarks, [target])
        XCTAssertNil(fromOldWatch.manOverboardCleared)

        // A new watch sends both; an older phone still finds its single target.
        let new = WorkoutMirrorSnapshot(
            sessionID: session, sequence: 4, sport: .sailing, sentAt: Date(timeIntervalSince1970: 1_000),
            readings: LiveReadings(nil), manOverboard: target, manOverboardMarks: [other, target],
            manOverboardCleared: [])
        let onOldPhone = try JSONDecoder().decode(SingleMarkSnapshot.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(onOldPhone.manOverboard, target)
        XCTAssertEqual(new.watchMarks, [other, target])
    }

    func testAMarkSavedAsTheSingleEarlierFormatStillLoads() throws {
        let saved = mark(at: (0, 100))
        defaults.set(try JSONEncoder().encode(saved), forKey: "manOverboard.mark")
        XCTAssertEqual(makeManOverboard().marks, [saved])
    }

    func testLiveActivityStateFromAnEarlierBuildDecodes() throws {
        let json = #"{"speed":"5.0 kn","speedNumber":"5.0","distance":"1.2 nm","movingTime":"0:12:00"}"#
        let state = try JSONDecoder().decode(SessionActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.manOverboard)
        XCTAssertEqual(state.manOverboardKind, 0)
    }

    // MARK: Live Activity

    private func activityState() -> SessionActivityAttributes.ContentState {
        SessionActivityAttributes.ContentState(
            speed: "5.0 kn", speedNumber: "5.0", distance: "1.2 nm", movingTime: "0:12:00", pauseLabel: nil)
    }

    private let guidance = ManOverboard.Guidance(distance: 120, bearing: 245, arrow: 245, isCourseRelative: false)

    func testManOverboardChangesBypassTheThrottle() {
        let display = UserSettings.display(for: .sailing)
        let fixAt = Date(timeIntervalSince1970: 999)
        let plain = activityState()
        let guided = plain.withManOverboard(
            isActive: true, guidance: guidance, fixAt: fixAt, mark: mark(at: (0, 100)), locationIssue: nil,
            display: display)
        let waiting = plain.withManOverboard(
            isActive: true, guidance: nil, fixAt: nil, mark: mark(at: (0, 100)), locationIssue: nil, display: display)
        let denied = plain.withManOverboard(
            isActive: true, guidance: nil, fixAt: nil, mark: nil, locationIssue: .denied, display: display)
        XCTAssertEqual(waiting.manOverboard, "Waiting for GPS")
        XCTAssertEqual(denied.manOverboard, ManOverboardNotes.locationIssue(.denied))

        let sent = Date(timeIntervalSince1970: 1_000)
        let soon = sent.addingTimeInterval(1)
        // Marked, guidance lost, location denied, cleared: each goes out at once.
        for (state, last) in [(guided, plain), (waiting, guided), (denied, waiting), (plain, denied)] {
            XCTAssertTrue(SessionActivityController.shouldSend(state, after: last, lastUpdate: sent, now: soon))
        }
        // A new distance waits for the throttle.
        var closer = guided
        closer.manOverboard = "100 m · 245°"
        XCTAssertFalse(SessionActivityController.shouldSend(closer, after: guided, lastUpdate: sent, now: soon))
        let later = sent.addingTimeInterval(SessionActivityController.minimumUpdateInterval)
        XCTAssertTrue(SessionActivityController.shouldSend(closer, after: guided, lastUpdate: sent, now: later))
        XCTAssertFalse(SessionActivityController.shouldSend(plain, after: plain, lastUpdate: sent, now: later))
    }

    /// Re-check finding 4: the stale date follows the fix, and the Lock Screen keeps the
    /// warning about a mark from an old position.
    func testLiveActivityStalenessFollowsTheFixAndCarriesTheMarkWarning() {
        let display = UserSettings.display(for: .sailing)
        let fixAt = Date(timeIntervalSince1970: 1_000)
        var stale = mark(at: (0, 100))
        stale.positionAge = 32
        let guided = activityState().withManOverboard(
            isActive: true, guidance: guidance, fixAt: fixAt, mark: stale, locationIssue: nil, display: display)
        XCTAssertEqual(SessionActivityController.staleDate(for: guided), fixAt.addingTimeInterval(10))
        XCTAssertEqual(guided.manOverboardNote, "Marked from a position 32 s old")
        XCTAssertNil(SessionActivityController.staleDate(for: activityState()))

        let final = SessionActivityController.finalState(guided)
        XCTAssertNil(final.manOverboard)
        XCTAssertNil(final.manOverboardNote)
        XCTAssertEqual(final.manOverboardKind, 0)
        XCTAssertEqual(final.distance, guided.distance)
    }
}
