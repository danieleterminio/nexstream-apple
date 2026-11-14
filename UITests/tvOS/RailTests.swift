import XCTest

/// Side rail and the BACK chain around it (docs/tv-experience.md sections 1, 2 and checklist items 1–2).
final class RailTests: NxUITestCase {

    /// LEFT from the Home page opens the rail with the focus on Home (the section in view), not on the first entry.
    func testLeftFromHomeOpensRailOnHome() {
        launch()
        XCTAssertFalse(railFocused, "the focus should start in the page, \(focusInfo)")
        XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
        snap("rail-open")
        XCTAssertEqual(focusedId, "rail.home", "the rail should open on the section in view")
        assertAlive("LEFT into the rail")
    }

    /// LEFT from another section (Film) opens the rail on that section.
    func testLeftFromFilmOpensRailOnFilm() {
        launch(["-nxSection", "movies"], waitFor: "rail.movies")
        XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
        snap("rail-open")
        XCTAssertEqual(focusedId, "rail.movies", "the rail should open on the section in view")
    }

    // One small test per section: select on the rail entry shows the section and puts the focus in its page; entering
    // the rail again (LEFT, or BACK on the section root) lands on that same entry.
    func testRailSelectSearch() { railSelect("search") }
    func testRailSelectHome() { railSelect("home") }
    func testRailSelectLive() { railSelect("live") }
    func testRailSelectGuide() { railSelect("guide") }
    func testRailSelectMovies() { railSelect("movies") }
    func testRailSelectSeries() { railSelect("series") }
    func testRailSelectMine() { railSelect("mine") }
    func testRailSelectSettings() { railSelect("settings") }

    private func railSelect(_ s: String) {
        launch()
        XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
        XCTAssertTrue(moveRail(to: s), "could not walk the rail to \(s), \(focusInfo)")
        snap("rail-on-\(s)")
        press(.select, wait: 2.0)
        snap("after-select-\(s)")
        assertAlive("select on rail.\(s)")
        XCTAssertTrue(el("section.\(s)").waitForExistence(timeout: 8), "section.\(s) is not shown after select")
        XCTAssertTrue(wait(5) { !railFocused && focusedId != "" }, "the focus did not move into the page of \(s), \(focusInfo)")
        XCTAssertTrue(focusInside("section.\(s)"), "the focus is not inside the page of \(s), \(focusInfo)")
        // back into the rail: BACK on a section root (spec 2), else LEFT
        back(wait: 1.2)
        if !railFocused { _ = openRailWithLeft() }
        snap("rail-again-\(s)")
        XCTAssertEqual(focusedId, "rail.\(s)", "re-entering the rail should focus the section in view")
        assertAlive("back into the rail from \(s)")
    }

    /// RIGHT from every rail entry lands in the page (the page is one focus group, also with a billboard on top).
    func testRightFromEveryRailItemLandsInPage() {
        launch()
        var failures = [String]()
        for s in NxUITestCase.sections {
            XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
            guard moveRail(to: s) else { failures.append("\(s): could not focus the entry"); continue }
            press(.right, wait: 1.2)
            snap("right-from-\(s)")
            assertAlive("RIGHT from rail.\(s)")
            if railFocused || focusedId == "" && !focused.exists {
                failures.append("\(s): RIGHT did not leave the rail (\(focusInfo))")
            } else if !NxUITestCase.sections.contains(where: { focusInside("section.\($0)") }) {
                failures.append("\(s): focus left the rail but is not in a section page (\(focusInfo))")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// BACK on a section root puts the focus on the rail, on the section in view.
    func testBackOnSectionRootFocusesRail() {
        launch(["-nxSection", "series"], waitFor: "rail.series")
        XCTAssertFalse(railFocused, "the focus should start in the page, \(focusInfo)")
        back()
        snap("after-back")
        assertAlive("BACK on the Serie TV root")
        XCTAssertTrue(waitFocus("rail.series", 3), "BACK on a section root should focus rail.series, \(focusInfo)")
    }

    /// BACK on the rail asks "Vuoi uscire da NexStream?" with Resta focused; select on Resta closes it.
    func testBackOnRailShowsExitDialogAndRestaCloses() {
        launch()
        XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
        back()
        snap("exit-dialog")
        assertAlive("BACK on the rail")
        XCTAssertTrue(text("Vuoi uscire da NexStream?").waitForExistence(timeout: 4), "no exit question after BACK on the rail")
        let stay = el("exit.stay").exists ? el("exit.stay") : labelled("Resta")
        XCTAssertTrue(stay.exists, "no Resta button")
        XCTAssertTrue(labelled("Esci").exists || el("exit.leave").exists, "no Esci button")
        XCTAssertTrue(wait(3) { stay.hasFocus }, "Resta should be focused, \(focusInfo)")
        press(.select, wait: 1.2)
        snap("after-resta")
        assertAlive("select on Resta")
        XCTAssertTrue(waitGone(text("Vuoi uscire da NexStream?"), 4), "the exit question is still shown after Resta")
        XCTAssertTrue(wait(3) { railFocused }, "after Resta the focus should be back on the rail, \(focusInfo)")
    }

    /// A second BACK on the exit dialog means Resta: the dialog closes and the app stays.
    func testSecondBackOnExitDialogStays() {
        launch()
        XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
        back()
        XCTAssertTrue(text("Vuoi uscire da NexStream?").waitForExistence(timeout: 4), "no exit question after BACK on the rail")
        back(wait: 1.5)
        snap("after-second-back")
        assertAlive("second BACK on the exit dialog")
        XCTAssertTrue(waitGone(text("Vuoi uscire da NexStream?"), 4), "the exit question is still shown after the second BACK")
        XCTAssertTrue(wait(3) { railFocused }, "the focus should be back on the rail, \(focusInfo)")
    }

    /// A long BACK chain from a page never leaves the app without the exit question.
    func testRepeatedBackNeverLeavesTheApp() {
        launch(["-nxSection", "movies"], waitFor: "rail.movies")
        // page → rail → exit question → (BACK = Resta) rail → question → … : the only way out is "Esci"
        for i in 1...6 {
            back(wait: 1.2)
            snap("back-\(i)")
            assertAlive("BACK #\(i)")
        }
    }
}
