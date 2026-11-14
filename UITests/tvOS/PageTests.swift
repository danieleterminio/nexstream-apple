import XCTest

/// Pushed pages (spec 2: BACK = the page before, focus restored) and the gates (BACK = the exit question).
final class PageTests: NxUITestCase {

    /// Film: select on the first card opens its title page; BACK returns to the Film root with the focus in the page.
    func testOpenTitleFromFilmAndBack() {
        launch(["-nxSection", "movies"], waitFor: "rail.movies", settle: 8)
        XCTAssertFalse(railFocused, "the focus should start on a card, \(focusInfo)")
        let card = focusedLabel
        press(.select, wait: 2.5)
        snap("title-page")
        assertAlive("select on a Film card")
        XCTAssertTrue(el("page.title").waitForExistence(timeout: 15), "no title page after select on '\(card)', \(focusInfo)")
        back(wait: 2.0)
        snap("after-back")
        assertAlive("BACK on the title page")
        XCTAssertTrue(waitGone(el("page.title"), 5), "the title page is still shown after BACK")
        XCTAssertTrue(el("section.movies").waitForExistence(timeout: 5), "not back on the Film root")
        XCTAssertFalse(railFocused, "BACK from a pushed page should restore the focus in the page, not the rail")
        XCTAssertTrue(wait(3) { focusInside("section.movies") }, "the focus is not back in the Film page, \(focusInfo)")
        XCTAssertEqual(focusedLabel, card, "the focus should be back on the card that opened the page")
    }

    /// Home: walk down the rows until a card opens a title page (live cards may open the player or a programme page:
    /// those are closed and skipped), then BACK returns to Home with the app alive.
    func testOpenTitleFromHomeAndBack() {
        launch(settle: 8)
        var opened = false
        var card = ""
        for row in 0..<7 {
            card = focusedLabel
            press(.select, wait: 3.0)
            assertAlive("select on Home row \(row)")
            if el("page.title").waitForExistence(timeout: 6) { opened = true; break }
            if playerShown { _ = closePlayerWithBack() } else if !el("section.home").exists { back(wait: 2.0) }
            assertAlive("closing what row \(row) opened")
            press(.down, wait: 1.0)
        }
        snap("title-page")
        XCTAssertTrue(opened, "no Home card opened a title page, \(focusInfo)")
        back(wait: 2.0)
        snap("after-back")
        assertAlive("BACK on the title page")
        XCTAssertTrue(waitGone(el("page.title"), 5), "the title page is still shown after BACK")
        XCTAssertTrue(el("section.home").waitForExistence(timeout: 5), "not back on Home")
        XCTAssertFalse(railFocused, "BACK from a pushed page should restore the focus in the page, not the rail")
        XCTAssertEqual(focusedLabel, card, "the focus should be back on the card that opened the page")
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
