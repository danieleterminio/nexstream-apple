import XCTest

/// Pushed pages (spec 2: BACK = the page before, focus restored) and the gates (BACK = the exit question).
final class PageTests: NxUITestCase {

    /// Film: the first focus is the first genre chip. Select → the genre page (pushed); select on its first card → the
    /// title page (pushed); BACK → the genre page; BACK → the Film root with the focus back on the chip.
    func testGenreThenTitleFromFilmAndBackChain() {
        launch(["-nxSection", "movies"], waitFor: "rail.movies", settle: 8)
        wakeFocus()
        let chip = focusedLabel
        press(.select, wait: 4.0)
        snap("genre-page")
        assertAlive("select on '\(chip)'")
        XCTAssertFalse(playerShown, "a genre chip should not play anything")
        XCTAssertTrue(wait(5) { focused.exists && !focusInside("section.movies") }, "select on '\(chip)' did not push a page, \(focusInfo)")
        let card = focusedLabel
        press(.select, wait: 4.0)
        snap("title-page")
        assertAlive("select on '\(card)' in the genre page")
        XCTAssertTrue(el("page.title").waitForExistence(timeout: 10), "select on '\(card)' did not open the title page, \(focusInfo)")
        back(wait: 2.0)
        snap("back-to-genre")
        assertAlive("BACK on the title page")
        XCTAssertTrue(waitGone(el("page.title"), 5), "the title page is still shown after BACK")
        XCTAssertEqual(focusedLabel, card, "BACK should restore the focus on the card that opened the title")
        back(wait: 2.0)
        snap("back-to-film")
        assertAlive("BACK on the genre page")
        XCTAssertTrue(wait(5) { focusInside("section.movies") }, "BACK on the genre page should return to the Film root, \(focusInfo)")
        XCTAssertEqual(focusedLabel, chip, "the focus should be back on the chip '\(chip)'")
    }

    /// Home: the first card is an "in onda" programme; select pushes its programme page, BACK returns to Home with the
    /// focus on that card.
    func testProgrammeFromHomeAndBack() {
        launch(settle: 8)
        wakeFocus()
        let card = focusedLabel
        press(.select, wait: 4.0)
        snap("pushed")
        assertAlive("select on '\(card)'")
        XCTAssertFalse(playerShown, "the first Home card should open its page, not play")
        XCTAssertTrue(wait(5) { focused.exists && !focusInside("section.home") }, "select on '\(card)' did not push a page, \(focusInfo)")
        back(wait: 2.0)
        snap("after-back")
        assertAlive("BACK on the pushed page")
        XCTAssertFalse(text("Vuoi uscire da NexStream?").exists, "BACK on a pushed page must not ask to exit")
        XCTAssertTrue(wait(5) { focusInside("section.home") }, "BACK should return to Home, \(focusInfo)")
        XCTAssertEqual(focusedLabel, card, "the focus should be back on the card that opened the page")
    }

    /// The page sometimes starts with nothing focused (then BACK leaves the app, see
    /// RailTests.testBackOnSectionRootFocusesRail): a move wakes the focus up so the BACK chain can still be checked.
    private func wakeFocus() {
        if !wait(3, { focused.exists }) { snap("no-focus-at-start"); press(.down, wait: 1.0); press(.up, wait: 1.0) }
        XCTAssertTrue(focused.exists && !railFocused, "no focus in the page, \(focusInfo)")
    }

    /// "Chi guarda?" gate (-nxPicker): BACK shows the exit question with Resta focused; BACK again stays.
    func testProfilePickerBackAsksToExit() {
        launch(["-nxPicker"], waitFor: nil, settle: 0)
        XCTAssertTrue(text("Chi guarda?").waitForExistence(timeout: 60), "no profile picker with -nxPicker")
        pause(3)
        snap("picker")
        back(wait: 1.5)
        snap("exit-dialog")
        assertAlive("BACK on the profile picker")
        XCTAssertTrue(text("Vuoi uscire da NexStream?").waitForExistence(timeout: 4), "no exit question after BACK on the picker")
        let stay = el("exit.stay").exists ? el("exit.stay") : labelled("Resta")
        XCTAssertTrue(wait(3) { stay.hasFocus }, "Resta should be focused, \(focusInfo)")
        back(wait: 1.5)
        snap("after-second-back")
        assertAlive("second BACK on the exit question")
        XCTAssertTrue(waitGone(text("Vuoi uscire da NexStream?"), 4), "the exit question is still shown")
        XCTAssertTrue(text("Chi guarda?").exists, "the picker should still be there")
    }

    /// Picking a profile in the picker enters Home.
    func testProfilePickerSelectEntersHome() {
        launch(["-nxPicker"], waitFor: nil, settle: 0)
        XCTAssertTrue(text("Chi guarda?").waitForExistence(timeout: 60), "no profile picker with -nxPicker")
        pause(3)
        XCTAssertTrue(focused.exists, "nothing focused on the picker")
        press(.select, wait: 3.0)
        snap("after-pick")
        assertAlive("select on a profile")
        XCTAssertTrue(el("rail.home").waitForExistence(timeout: 15), "picking a profile did not open the app")
    }
}
