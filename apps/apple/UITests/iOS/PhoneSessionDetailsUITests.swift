import XCTest

/// Naming a session and keeping notes on it, from the detail's ⋯ menu: the name replaces
/// the sport as the title in the detail and in History, survives a relaunch, and clearing
/// both brings the sport back.
final class PhoneSessionDetailsUITests: XCTestCase {
    @MainActor
    func testNameAndNotes() {
        let app = launchDemoHistory(extraArguments: ["-demoOmitMapKit"])
        openSailing(in: app, title: "Sailing")

        openSessionMenu("session.more", in: app)
        let add = app.buttons["session.editDetails"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "Add Name & Notes")
        add.tap()

        let name = element("details.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["details.save"]
        XCTAssertFalse(save.isEnabled, "nothing to save yet")
        // The name field has focus when the sheet opens with nothing saved.
        name.typeText("  Evening race ")
        let notes = element("details.notes", in: app)
        notes.tap()
        notes.typeText("Gusty at the mark.")
        attachScreenshot("name and notes editor")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        // The detail takes the name, trimmed, and shows the notes in the panel.
        XCTAssertTrue(app.navigationBars["Evening race"].waitForExistence(timeout: 5))
        let shownNotes = element("session.notes", in: app)
        XCTAssertTrue(shownNotes.waitForExistence(timeout: 5))
        XCTAssertEqual(shownNotes.label, "Gusty at the mark.")
        attachScreenshot("named session")

        // History lists it by name, with its sport beside it; so it does after a relaunch.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(historyCard("Evening race", in: app).waitForExistence(timeout: 10))
        attachScreenshot("named session in History")
        terminateAndSettle(app)
        launchFresh(app)
        openSailing(in: app, title: "Evening race")

        // Clearing both brings back the sport's name and removes the notes.
        openSessionMenu("session.more", in: app)
        let edit = app.buttons["session.editDetails"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "Edit Name & Notes")
        edit.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Evening race")
        clear(name)
        clear(notes)
        save.tap()
        XCTAssertTrue(app.navigationBars["Sailing"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("session.notes", in: app).exists)
    }

    /// The same session open from Recent and from History: a name saved in one detail shows
    /// in the other, and once one deletes the session the other can't edit it.
    @MainActor
    func testTwoOpenDetailsOfOneSession() {
        let app = launchDemoHistory(extraArguments: ["-demoOmitMapKit"])
        XCTAssertTrue(app.buttons["sport.sailing"].waitForExistence(timeout: 15))
        let recent = app.buttons.matching(identifier: "recent.session")
            .containing(.staticText, identifier: "Sailing").firstMatch
        scrollTo(recent, in: app)
        recent.tap()
        XCTAssertTrue(app.buttons["session.panel.handle"].waitForExistence(timeout: 20))

        openSailing(in: app, title: "Sailing")
        openSessionMenu("session.more", in: app)
        app.buttons["session.editDetails"].tap()
        let name = element("details.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Evening race")
        app.buttons["details.save"].tap()
        XCTAssertTrue(app.navigationBars["Evening race"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Record"].tap()
        XCTAssertTrue(
            app.navigationBars["Evening race"].waitForExistence(timeout: 5), "Recent's detail kept the old title")

        // Delete it from History, with its detail still open in Recent.
        app.tabBars.buttons["History"].tap()
        openSessionMenu("session.more", in: app)
        app.buttons["session.delete"].tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["history.statistics"].waitForExistence(timeout: 10))

        // Recent's detail reloads on return and no longer offers edits for the deleted
        // recording (the library refuses a save for it in any case).
        app.tabBars.buttons["Record"].tap()
        XCTAssertTrue(app.staticTexts["Can't read this recording"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["session.more"].exists)
    }

    /// Opens History's sailing session, found by the title its card shows.
    @MainActor
    private func openSailing(in app: XCUIApplication, title: String) {
        app.tabBars.buttons["History"].tap()
        let card = historyCard(title, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.buttons["session.panel.handle"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func historyCard(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "session.row")
            .containing(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Empties a text field: a tap in its bottom trailing corner, past the text, puts the
    /// cursor at the end.
    @MainActor
    private func clear(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.9)).tap()
        let text = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        XCTAssertEqual(field.value as? String ?? "", "", file: file, line: line)
    }
}
