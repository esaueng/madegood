import XCTest

final class PhoneReplayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChartAndMapShareTheReplayCursor() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        let rows = app.buttons.matching(identifier: "session.row")
        let sailing = rows.containing(.staticText, identifier: "Sailing")
            .containing(.staticText, identifier: "48:00").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        scrollTo(sailing, in: app)
        sailing.tap()

        let chart = element("chart.speed", in: app)
        let elapsed = app.staticTexts["stat.Elapsed"]
        let speed = app.staticTexts["stat.GPS speed"]
        let distance = app.staticTexts["stat.Route distance"]
        let marker = element("replay.position", in: app)
        let map = element("replay.map", in: app)
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(chart.frame.width, 0)
        let initialTime = elapsed.label
        let initialSpeed = speed.label
        let initialDistance = distance.label
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        let startFrame = marker.frame
        let startMapFrame = map.frame
        XCTAssertGreaterThan(startMapFrame.width, 0)
        XCTAssertGreaterThan(startMapFrame.height, 0)
        // Scrubbing can scroll the list. Preserve the fix's position within the
        // map, so the tap follows the map instead of reusing a screen coordinate.
        let startOffset = CGVector(
            dx: (startFrame.midX - startMapFrame.minX) / startMapFrame.width,
            dy: (startFrame.midY - startMapFrame.minY) / startMapFrame.height)

        let from = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4))
        let to = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
        from.tap()
        let tappedTime = elapsed.label
        XCTAssertNotEqual(tappedTime, initialTime)
        XCTAssertEqual(marker.value as? String, tappedTime)

        from.press(forDuration: 0.05, thenDragTo: to)
        let scrubbedTime = elapsed.label
        XCTAssertNotEqual(scrubbedTime, tappedTime)
        XCTAssertNotEqual(speed.label, initialSpeed)
        XCTAssertNotEqual(distance.label, initialDistance)
        XCTAssertTrue((chart.value as? String)?.contains("\(scrubbedTime) elapsed") == true)
        XCTAssertEqual(marker.value as? String, elapsed.label)
        XCTAssertNotEqual(marker.frame, startFrame)

        map.coordinate(withNormalizedOffset: startOffset).tap()
        XCTAssertNotEqual(elapsed.label, scrubbedTime)
        XCTAssertTrue(elapsed.label.hasPrefix("0:"), "Route tap should return to the start of the sailing route")
        XCTAssertEqual(marker.value as? String, elapsed.label)

        // A vertical drag starting inside the plot still scrolls the detail list.
        to.press(forDuration: 0.05, thenDragTo: to.withOffset(CGVector(dx: 0, dy: -300)))
        let total = app.staticTexts["stat.Total time"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertTrue(total.isHittable)
        XCTAssertEqual(total.label, "48:00")
    }

    @MainActor
    func testHeartRateZonesRefreshAfterEditingSettings() {
        let app = launchDemoHistory()
        let history = app.tabBars.buttons["History"]
        history.tap()
        let sailing = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Sailing").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        sailing.tap()

        let maximum = app.staticTexts["session.heartRateZones.maximum"]
        scrollTo(maximum, in: app, column: 0.08)
        XCTAssertTrue(maximum.label.contains("190 bpm"))

        app.tabBars.buttons["Settings"].tap()
        let zones = app.buttons["Heart Rate Zones"]
        scrollTo(zones, in: app)
        zones.tap()
        let stepper = app.steppers["settings.heartRateZones.maximum"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.buttons["Increment"].tap()

        history.tap()
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "191 bpm"), object: maximum)
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 15), .completed)
    }

    @MainActor
    func testSelectWindowsAndSaveAndRestoreTrim() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        let sailingRows = app.buttons.matching(identifier: "session.row")
            .containing(.staticText, identifier: "Sailing")
        let sailing = sailingRows.containing(.staticText, identifier: "48:00").firstMatch
        let trimmedSailing = sailingRows.containing(.staticText, identifier: "Trimmed").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        let totals = app.staticTexts["history.totals"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", " km"), object: totals)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 15), .completed)
        let originalTotals = totals.label
        scrollTo(sailing, in: app)
        sailing.tap()

        let interval = app.staticTexts["replay.range"]
        let elapsed = app.staticTexts["stat.Elapsed"]
        let chart = element("chart.speed", in: app)
        let duration = app.staticTexts["stat.Total time"]

        for (title, seconds) in [("Max 2 s", 2.0), ("Max 10 s", 10.0)] {
            let tile = app.buttons["replay.\(title)"]
            scrollTo(tile, in: app)
            XCTAssertTrue(tile.label.hasSuffix(" kn"))
            tile.tap()
            XCTAssertTrue(interval.waitForExistence(timeout: 5))
            let label = interval.label
            XCTAssertTrue(label.hasPrefix("\(title) · "))
            let bounds = String(label.dropFirst(title.count + 3)).components(separatedBy: " to ")
            XCTAssertEqual(bounds.count, 2)
            XCTAssertEqual(elapsed.label, bounds[0])
            XCTAssertEqual(secondsInTime(bounds[1]) - secondsInTime(bounds[0]), seconds, accuracy: 0.001)
            scrollTo(chart, in: app)
            chart.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.4)).tap()
            XCTAssertFalse(interval.exists)
        }

        let play = app.buttons["replay.playPause"]
        XCTAssertTrue(play.isHittable)
        let beforePlaying = elapsed.label
        // Playback updates the chart continuously. Compare the settled snapshots
        // and allow another interval if the simulator hasn't published a tick yet.
        for interval in [1.5, 2.5] {
            play.tap()
            waitForLabel(play, "Pause")
            Thread.sleep(forTimeInterval: interval)
            play.tap()
            waitForLabel(play, "Play")
            if secondsInTime(elapsed.label) > secondsInTime(beforePlaying) { break }
        }
        XCTAssertGreaterThan(secondsInTime(elapsed.label), secondsInTime(beforePlaying))

        let lap = app.buttons["replay.lap.1"]
        scrollTo(lap, in: app)
        lap.tap()
        waitForLabel(interval, "Lap 1 · 0:00 to 24:00")
        XCTAssertEqual(elapsed.label, "0:00")

        let trim = app.buttons["session.trim"]
        scrollTo(trim, in: app)
        trim.tap()
        let start = app.sliders["trim.start"]
        let end = app.sliders["trim.end"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.adjust(toNormalizedSliderPosition: 0.25)
        end.adjust(toNormalizedSliderPosition: 0.65)
        let save = app.buttons["trim.save"]
        let previewReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter().wait(for: [previewReady], timeout: 10), .completed)
        save.tap()
        XCTAssertTrue(app.navigationBars["Sailing"].waitForExistence(timeout: 5))
        scrollTo(duration, in: app)
        let trimmedDuration = duration.label
        XCTAssertGreaterThan(secondsInTime(trimmedDuration), 0)
        XCTAssertLessThan(secondsInTime(trimmedDuration), 2_880)

        app.navigationBars.buttons["History"].tap()
        XCTAssertTrue(trimmedSailing.waitForExistence(timeout: 5))
        XCTAssertNotEqual(totals.label, originalTotals)

        // Relaunch with the same synthetic raw recording to exercise the saved sidecar.
        app.terminate()
        launchFresh(app)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(trimmedSailing.waitForExistence(timeout: 15))
        scrollTo(trimmedSailing, in: app)
        trimmedSailing.tap()
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, trimmedDuration)

        scrollTo(trim, in: app)
        trim.tap()
        let restore = app.buttons["trim.restore"]
        scrollTo(restore, in: app)
        restore.tap()
        // The sailing maneuver list is long, so the button can be below the visible rows.
        XCTAssertTrue(app.navigationBars["Sailing"].waitForExistence(timeout: 5))
        scrollTo(trim, in: app)
        waitForLabel(trim, "Trim Session")
        app.navigationBars.buttons["History"].tap()
        waitForLabel(totals, originalTotals)
        XCTAssertFalse(trimmedSailing.exists)
        scrollTo(sailing, in: app)
        sailing.tap()
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "48:00")
    }

    /// Drags in the trim sheet run down the list's side margin: once a cut is added, the
    /// replay map sits mid-screen and drags that start on it pan the map, not the form.
    private static let trimMargin: CGFloat = 0.025

    @MainActor
    func testRemoveMiddleSegmentAndRestoreOriginal() {
        let app = launchDemoHistory()
        app.tabBars.buttons["History"].tap()
        let sailingRows = app.buttons.matching(identifier: "session.row").containing(.staticText, identifier: "Sailing")
        let sailing = sailingRows.containing(.staticText, identifier: "48:00").firstMatch
        let trimmedSailing = sailingRows.containing(.staticText, identifier: "Trimmed").firstMatch
        XCTAssertTrue(sailing.waitForExistence(timeout: 15))
        scrollTo(sailing, in: app)
        sailing.tap()

        let trim = app.buttons["session.trim"]
        scrollTo(trim, in: app)
        trim.tap()
        let addCut = app.buttons["trim.addCut"]
        scrollTo(addCut, in: app, column: Self.trimMargin)
        addCut.tap()
        XCTAssertTrue(app.sliders["trim.cut.0.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["trim.cut.0.end"].exists)

        let kept = element("trim.preview.Kept", in: app)
        scrollTo(kept, in: app, column: Self.trimMargin)
        XCTAssertTrue(element("trim.preview.Original", in: app).exists)
        let save = app.buttons["trim.save"]
        let previewReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter().wait(for: [previewReady], timeout: 10), .completed)
        save.tap()

        XCTAssertTrue(app.navigationBars["Sailing"].waitForExistence(timeout: 5))
        app.terminate()
        launchFresh(app)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(trimmedSailing.waitForExistence(timeout: 15))
        scrollTo(trimmedSailing, in: app)
        trimmedSailing.tap()
        let cut = element("replay.removedInterval", in: app)
        scrollTo(cut, in: app)
        XCTAssertTrue(cut.exists)
        let duration = app.staticTexts["stat.Total time"]
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "32:00")

        scrollTo(trim, in: app)
        trim.tap()
        XCTAssertTrue(app.sliders["trim.cut.0.start"].waitForExistence(timeout: 5))
        let restore = app.buttons["trim.restore"]
        scrollTo(restore, in: app, column: Self.trimMargin)
        restore.tap()
        XCTAssertTrue(app.navigationBars["Sailing"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["History"].tap()
        XCTAssertTrue(sailing.waitForExistence(timeout: 10))
        XCTAssertFalse(trimmedSailing.exists)
        scrollTo(sailing, in: app)
        sailing.tap()
        scrollTo(duration, in: app)
        XCTAssertEqual(duration.label, "48:00")
    }

    private func secondsInTime(_ label: String) -> Double {
        label.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }
}
