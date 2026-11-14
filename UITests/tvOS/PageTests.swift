import XCTest

/// Pushed pages (spec 2: BACK = the page before, focus restored) and the gates (BACK = the exit question).
final class PageTests: NxUITestCase {

    /// Film: walk down the rows until a card opens its title page (genre chips open a genre page: closed and skipped);
    /// BACK returns to the Film root with the focus on that card.
    func testOpenTitleFromFilmAndBack() { openTitleAndBack("movies", extra: ["-nxSection", "movies"]) }

    /// Home: the same from Home (live cards may open the player or a programme page: closed and skipped).
    func testOpenTitleFromHomeAndBack() { openTitleAndBack("home", extra: []) }

    private func openTitleAndBack(_ s: String, extra: [String]) {
        launch(extra, waitFor: "rail.\(s)", settle: 8)
        XCTAssertFalse(railFocused, "the focus should start in the page, \(focusInfo)")
        var card = ""
        var opened = false
        var tried = [String]()
        for row in 0..<8 {
            card = focusedLabel
            tried.append(card)
            press(.select, wait: 3.0)
            assertAlive("select on '\(card)' (row \(row))")
            if el("page.title").waitForExistence(timeout: 6) { opened = true; break }
            snap("not-a-title-\(row)")
            // something else opened (player, programme or genre page): close it; if nothing opened, just go on
            if playerShown { _ = closePlayerWithBack() } else if !focusInside("section.\(s)") { back(wait: 2.0) }
            assertAlive("closing what '\(card)' opened")
            if railFocused { press(.right, wait: 1.0) }
            press(.down, wait: 1.2)
        }
        snap("title-page")
        XCTAssertTrue(opened, "no card opened a title page; tried: \(tried), \(focusInfo)")
        back(wait: 2.0)
        snap("after-back")
        assertAlive("BACK on the title page")
        XCTAssertTrue(waitGone(el("page.title"), 5), "the title page is still shown after BACK")
        XCTAssertTrue(el("section.\(s)").waitForExistence(timeout: 5), "not back on the \(s) root")
        XCTAssertFalse(railFocused, "BACK from a pushed page should restore the focus in the page, not the rail")
        XCTAssertTrue(wait(3) { focusInside("section.\(s)") }, "the focus is not back in the page, \(focusInfo)")
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
