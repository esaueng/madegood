import Foundation
import WaterKit
import XCTest

@testable import MadeGood

/// The iPhone's man-overboard rules: guidance geometry (shared with the watch), position
/// age, marking without a session, following the watch's mark by ID, and the mirror and
/// Live Activity formats.
@MainActor
final class ManOverboardTests: XCTestCase {
    // A fake position in open water, like the anonymized fixtures.
    private let origin = (lat: 10.0, lon: -30.0)
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        suiteName = "ManOverboardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
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
        let fixes = [position(speed: 0.4, course: 90), position(speed: 3, course: nil), position(speed: nil, course: 90)]
        for fix in fixes {
            let guidance = ManOverboard.guidance(from: fix, to: target)
            XCTAssertFalse(guidance.isCourseRelative)
            XCTAssertEqual(guidance.bearing, 225, accuracy: 0.5)
            XCTAssertEqual(guidance.arrow, guidance.bearing)
        }
    }

    // MARK: Position age (review finding 2)

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
        let manOverboard = ManOverboard(defaults: defaults)
        let uptime = ProcessInfo.processInfo.systemUptime
        manOverboard.update(
            ManOverboard.Position(
                latitude: origin.lat, longitude: origin.lon, at: Date().addingTimeInterval(-40),
                receivedUptime: uptime))
        guard case .marked(let marked) = manOverboard.press() else { return XCTFail("did not mark") }
        XCTAssertGreaterThanOrEqual(marked.positionAge, 40)
        XCTAssertNil(manOverboard.guidance(), "no guidance from a stale fix")
        XCTAssertTrue(ManOverboardNotes.markQuality(marked)?.hasPrefix("Marked from a position 4") == true)
    }

    // MARK: Marking without a session (review finding 1)

    func testAPressWithNoPositionMarksTheFirstFix() throws {
        let manOverboard = ManOverboard(defaults: defaults)
        let pressed = Date().addingTimeInterval(-5)
        XCTAssertEqual(manOverboard.press(at: pressed), .awaitingFix)
        XCTAssertTrue(manOverboard.isActive)
        XCTAssertNil(manOverboard.mark)
        manOverboard.stopOwnUpdates()

        // The press survives a relaunch while it waits.
        let relaunched = ManOverboard(defaults: defaults)
        XCTAssertEqual(relaunched.awaitingFixSince, pressed)

        relaunched.update(ManOverboard.Position(latitude: origin.lat, longitude: origin.lon, at: Date()))
        let marked = try XCTUnwrap(relaunched.mark)
        XCTAssertEqual(marked.markedAt, pressed)
        XCTAssertNil(relaunched.awaitingFixSince)
        XCTAssertEqual(ManOverboardNotes.markQuality(marked), "Position from 5 s after MOB was pressed")
        XCTAssertNotNil(relaunched.guidance())
    }

    func testClearCancelsAWaitingPress() {
        let manOverboard = ManOverboard(defaults: defaults)
        _ = manOverboard.press()
        manOverboard.clear()
        XCTAssertFalse(manOverboard.isActive)
        manOverboard.update(ManOverboard.Position(latitude: origin.lat, longitude: origin.lon, at: Date()))
        XCTAssertNil(manOverboard.mark)
    }

    // MARK: Following the watch by mark ID (review findings 3 and 5)

    private let session = UUID()

    func testANewWatchMarkIsAdopted() {
        let watch = mark(at: (0, 100))
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, sessionID: session, local: nil, adopted: nil, cleared: []),
            .adopt(watch))
        // It replaces the phone's own mark: a new emergency on the watch is news.
        let phone = mark(at: (90, 50), markedAt: 2_000)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, sessionID: session, local: phone, adopted: nil, cleared: []),
            .adopt(watch))
    }

    func testAClearedMarkStaysClearedWhateverItsTimestamp() {
        let cleared = mark(at: (0, 100))
        // The same mark decoded with a timestamp a rounding step away is still the same mark.
        var rounded = cleared
        rounded.markedAt = cleared.markedAt.addingTimeInterval(0.000_1)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(
                incoming: rounded, sessionID: session, local: nil, adopted: nil, cleared: [cleared.identity]),
            .keep)
    }

    func testANewWatchMarkIsAdoptedEvenIfTheWatchClockIsBehind() {
        let cleared = mark(at: (0, 100), markedAt: 2_000)
        let newer = mark(at: (45, 80), markedAt: 1_000)  // the watch clock went backward
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(
                incoming: newer, sessionID: session, local: nil, adopted: nil, cleared: [cleared.identity]),
            .adopt(newer))
    }

    func testAWatchMarkTakenOnceIsNotRetakenOverThePhonesOwn() {
        let watch = mark(at: (0, 100))
        let phone = mark(at: (90, 30))
        let adopted = ManOverboard.Adopted(markID: watch.identity, sessionID: session)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: watch, sessionID: session, local: phone, adopted: adopted, cleared: []),
            .keep)
    }

    func testClearingOnTheWatchClearsOnlyTheMarkItGave() {
        let watch = mark(at: (0, 100))
        let adopted = ManOverboard.Adopted(markID: watch.identity, sessionID: session)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, sessionID: session, local: watch, adopted: adopted, cleared: []),
            .clear)
        // The phone's own mark stays, and so does one from another recording.
        let phone = mark(at: (90, 30))
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, sessionID: session, local: phone, adopted: adopted, cleared: []),
            .keep)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, sessionID: UUID(), local: watch, adopted: adopted, cleared: []),
            .keep)
        // An older watch app never sends the field, so it never gave a mark to clear.
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(incoming: nil, sessionID: session, local: phone, adopted: nil, cleared: []),
            .keep)
    }

    func testAMarkWithoutAnIDHasAStableIdentity() throws {
        let legacy = mark(at: (0, 100), id: nil)
        let decoded = try JSONDecoder().decode(ManOverboard.Mark.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.id)
        XCTAssertEqual(decoded.identity, legacy.identity)
        XCTAssertNotEqual(mark(at: (0, 101), id: nil).identity, legacy.identity)
        XCTAssertEqual(
            ManOverboard.mirrorUpdate(
                incoming: decoded, sessionID: session, local: nil, adopted: nil, cleared: [legacy.identity]),
            .keep)
    }

    func testAPhoneClearOutlivesARelaunch() {
        let watch = mark(at: (0, 100))
        let first = ManOverboard(defaults: defaults)
        XCTAssertTrue(first.applyMirrored(watch, sessionID: session))
        first.clear()

        let relaunched = ManOverboard(defaults: defaults)
        XCTAssertFalse(relaunched.applyMirrored(watch, sessionID: session))
        XCTAssertNil(relaunched.mark)
    }

    func testAWatchClearWhileThePhoneWasClosedClearsOnRelaunch() {
        let watch = mark(at: (0, 100))
        let first = ManOverboard(defaults: defaults)
        XCTAssertTrue(first.applyMirrored(watch, sessionID: session))

        // Relaunched: the first snapshot from the same recording has no mark.
        let relaunched = ManOverboard(defaults: defaults)
        XCTAssertEqual(relaunched.mark, watch)
        relaunched.applyMirrored(nil, sessionID: session)
        XCTAssertNil(relaunched.mark)
        // And it does not come back.
        XCTAssertFalse(ManOverboard(defaults: defaults).applyMirrored(watch, sessionID: session))
    }

    func testASnapshotFromAnotherRecordingDoesNotClearAfterRelaunch() {
        let watch = mark(at: (0, 100))
        XCTAssertTrue(ManOverboard(defaults: defaults).applyMirrored(watch, sessionID: session))
        let relaunched = ManOverboard(defaults: defaults)
        relaunched.applyMirrored(nil, sessionID: UUID())
        XCTAssertEqual(relaunched.mark, watch)
    }

    // MARK: Formats

    func testMirrorSnapshotsWithAndWithoutTheMarkDecode() throws {
        var readings = LiveReadings(nil)
        readings.speed = 2
        let old = WorkoutMirrorSnapshot(
            sessionID: UUID(), sequence: 1, sport: .sailing, sentAt: Date(timeIntervalSince1970: 1_000),
            readings: readings)
        let oldJSON = try JSONEncoder().encode(old)
        // An older watch app's snapshot has no such key at all.
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("manOverboard"))
        XCTAssertNil(try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: oldJSON).manOverboard)

        var new = old
        new.manOverboard = mark(at: (0, 100))
        let decoded = try JSONDecoder().decode(WorkoutMirrorSnapshot.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded, new)
        XCTAssertEqual(decoded.manOverboard?.id, new.manOverboard?.id)
        XCTAssertEqual(decoded.version, WorkoutMirrorSnapshot.currentVersion)
    }

    func testLiveActivityStateFromAnEarlierBuildDecodes() throws {
        let json = #"{"speed":"5.0 kn","speedNumber":"5.0","distance":"1.2 nm","movingTime":"0:12:00"}"#
        let state = try JSONDecoder().decode(SessionActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.manOverboard)
        XCTAssertEqual(state.manOverboardKind, 0)
    }

    // MARK: Live Activity (review finding 4)

    private func activityState() -> SessionActivityAttributes.ContentState {
        SessionActivityAttributes.ContentState(
            speed: "5.0 kn", speedNumber: "5.0", distance: "1.2 nm", movingTime: "0:12:00", pauseLabel: nil)
    }

    func testManOverboardChangesBypassTheThrottle() {
        let display = UserSettings.display(for: .sailing)
        let plain = activityState()
        let guided = plain.withManOverboard(
            isActive: true,
            guidance: ManOverboard.Guidance(distance: 120, bearing: 245, arrow: 245, isCourseRelative: false),
            display: display)
        let waiting = plain.withManOverboard(isActive: true, guidance: nil, display: display)
        XCTAssertEqual(waiting.manOverboard, "Waiting for GPS")
        XCTAssertEqual(guided.manOverboardHasGuidance, true)

        let sent = Date(timeIntervalSince1970: 1_000)
        let soon = sent.addingTimeInterval(1)
        // Marked, guidance lost, cleared: each goes out at once.
        XCTAssertTrue(SessionActivityController.shouldSend(guided, after: plain, lastUpdate: sent, now: soon))
        XCTAssertTrue(SessionActivityController.shouldSend(waiting, after: guided, lastUpdate: sent, now: soon))
        XCTAssertTrue(SessionActivityController.shouldSend(plain, after: waiting, lastUpdate: sent, now: soon))
        // A new distance waits for the throttle.
        var closer = guided
        closer.manOverboard = "100 m · 245°"
        XCTAssertFalse(SessionActivityController.shouldSend(closer, after: guided, lastUpdate: sent, now: soon))
        let later = sent.addingTimeInterval(SessionActivityController.minimumUpdateInterval)
        XCTAssertTrue(SessionActivityController.shouldSend(closer, after: guided, lastUpdate: sent, now: later))
        // Unchanged guidance is resent to move its stale date on; plain content is not.
        XCTAssertTrue(SessionActivityController.shouldSend(guided, after: guided, lastUpdate: sent, now: later))
        XCTAssertFalse(SessionActivityController.shouldSend(plain, after: plain, lastUpdate: sent, now: later))
    }

    func testManOverboardContentGoesStaleAndIsStrippedAtTheEnd() {
        let display = UserSettings.display(for: .sailing)
        let now = Date(timeIntervalSince1970: 1_000)
        let guided = activityState().withManOverboard(
            isActive: true,
            guidance: ManOverboard.Guidance(distance: 120, bearing: 245, arrow: 245, isCourseRelative: false),
            display: display)
        XCTAssertEqual(SessionActivityController.staleDate(for: guided, now: now), now.addingTimeInterval(10))
        XCTAssertNil(SessionActivityController.staleDate(for: activityState(), now: now))

        let final = SessionActivityController.finalState(guided)
        XCTAssertNil(final.manOverboard)
        XCTAssertEqual(final.manOverboardKind, 0)
        XCTAssertEqual(final.distance, guided.distance)
    }
}
