import XCTest

/// Apple TV against the Android TV reference (v1.4 parity pass): a screenshot of every main screen in the state the
/// remote leaves it, and the focus rules fixed in that pass —
/// - Home / Film / Serie TV: the row under the remote comes up under the billboard whole (no row cut half way), and
///   the focused card comes to the row's left edge (the page margin), Netflix-style;
/// - Guida TV: the focused cell is framed inside its slot (no zoom over the neighbours), slivers are skipped, BACK
///   from a programme page returns to that cell;
/// - live player: the info bar with the logo, the times, the progress and "Dopo:" inside the safe area.
final class ParityTests: NxUITestCase {

    /// Left edge of the page content: the collapsed side menu (168 pt) plus the page margin (60 pt).
    private let rowLeft: CGFloat = 228
    /// Bottom of the billboard on browsing pages.
    private let billboard: CGFloat = 470

    private var focusFrame: CGRect { let f = focused; return f.exists ? f.frame : .zero }

    /// Home: down two rows and three cards right; the focused card must sit whole below the billboard, at the row's
    /// left edge, and go back there after a programme page.
    func testHomeRowsKeepFocusedCardWholeAndAtLeftEdge() {
        launch(["-nxDemoEpg"], settle: 8)
        XCTAssertTrue(wait(4) { self.focused.exists && !self.railFocused }, "no focus in Home, \(focusInfo)")
        snap("home")
        press(.down, wait: 1.2)
        snap("home-row2")
        press(.down, wait: 1.2)
        snap("home-row3")
        var f = focusFrame
        XCTAssertGreaterThanOrEqual(f.minY, billboard - 30, "the focused card is under the billboard: \(f), \(focusInfo)")
        XCTAssertLessThanOrEqual(f.maxY, 1080, "the focused card is below the screen: \(f), \(focusInfo)")
        // the next row down is a long one (Top 10): there the card can travel to the left edge
        press(.down, wait: 1.2)
        snap("home-row4")
        press(.right, 3, wait: 0.9)
        pause(0.8)
        snap("home-row4-right3")
        f = focusFrame
        XCTAssertLessThan(abs(f.minX - rowLeft), 70, "the focused card should come to the row's left edge (x≈\(rowLeft)): \(f), \(focusInfo)")
        let card = focusedLabel
        press(.select, wait: 4.0)
        snap("pushed")
        if playerShown { _ = closePlayerWithBack(max: 3) } else { back(wait: 2.0) }
        snap("back")
        XCTAssertTrue(wait(5) { self.focusedLabel == card }, "the focus should be back on '\(card)', \(focusInfo)")
        f = focusFrame
        XCTAssertGreaterThanOrEqual(f.minY, billboard - 30, "back on Home the card is under the billboard: \(f)")
        press(.up, wait: 1.2)
        snap("home-up")
        f = focusFrame
        XCTAssertGreaterThanOrEqual(f.minY, billboard - 30, "after UP the focused card is under the billboard: \(f), \(focusInfo)")
    }

    /// Film and Serie TV: the same rows (first focus, then down and right).
    func testFilmAndSeriesRows() {
        for s in ["movies", "series"] {
            launch(["-nxSection", s], waitFor: "rail.\(s)", settle: 8)
            snap("\(s)")
            press(.down, wait: 1.2)
            press(.down, wait: 1.2)
            press(.right, 2, wait: 0.9)
            pause(0.8)
            snap("\(s)-down2-right2")
            let f = focusFrame
            XCTAssertTrue(focusInside("section.\(s)"), "\(s): the focus left the page, \(focusInfo)")
            XCTAssertGreaterThanOrEqual(f.minY, billboard - 30, "\(s): the focused card is under the billboard: \(f), \(focusInfo)")
            XCTAssertLessThanOrEqual(f.maxY, 1080, "\(s): the focused card is below the screen: \(f)")
            app.terminate()
        }
    }

    /// Guida TV: into the grid, along a row with RIGHT; the focused cell stays inside the grid, is never a sliver, and
    /// a programme page returns to it.
    func testGuideCellsFramedAndBack() {
        launch(["-nxSection", "guide", "-nxDemoEpg"], waitFor: "rail.guide", settle: 8)
        snap("guide")
        press(.down, wait: 1.0)
        press(.down, wait: 1.0)
        press(.down, wait: 1.0)
        snap("guide-row")
        var labels = [String]()
        for i in 0..<5 {
            press(.right, wait: 0.9)
            let l = focusedLabel
            labels.append(l)
            snap("guide-right-\(i + 1)")
            let f = focusFrame
            XCTAssertTrue(focusInside("section.guide"), "RIGHT #\(i + 1) left the guide, \(focusInfo)")
            XCTAssertGreaterThan(f.width, 40, "RIGHT #\(i + 1) landed on a sliver: \(f), \(focusInfo)")
            XCTAssertLessThanOrEqual(f.maxX, 1920 - 40, "the focused cell runs off the screen: \(f)")
        }
        XCTAssertFalse(labels.contains("Tg flash"), "the 2-minute 'Tg flash' slivers should be skipped: \(labels)")
        let cell = focusedLabel
        press(.select, wait: 3.0)
        snap("guide-pushed")
        if playerShown { _ = closePlayerWithBack(max: 3) } else { back(wait: 2.0) }
        snap("guide-back")
        XCTAssertTrue(wait(5) { self.focusInside("section.guide") }, "BACK should return to the guide, \(focusInfo)")
        XCTAssertEqual(focusedLabel, cell, "the focus should be back on '\(cell)'")
    }

    /// Diretta (Canali), Cerca, Impostazioni, I miei: how they open; DOWN/RIGHT keep a visible focus in the page.
    func testOtherSectionsOpenWithVisibleFocus() {
        for s in ["live", "search", "settings", "mine"] {
            launch(["-nxSection", s, "-nxDemoEpg"], waitFor: "rail.\(s)", settle: 7)
            snap("\(s)")
            XCTAssertTrue(wait(4) { self.focused.exists && !self.railFocused }, "\(s): no focus in the page at start, \(focusInfo)")
            press(.down, wait: 1.0)
            press(.right, wait: 1.0)
            snap("\(s)-moved")
            let f = focusFrame
            XCTAssertTrue(focused.exists, "\(s): the focus vanished after DOWN/RIGHT")
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1920, height: 1080).intersects(f), "\(s): the focus is off screen: \(f)")
            app.terminate()
        }
    }

    /// The title page of a film (from Film, first card of the first row) and BACK.
    func testTitlePage() {
        launch(["-nxSection", "movies"], waitFor: "rail.movies", settle: 8)
        press(.down, wait: 1.2)
        let card = focusedLabel
        press(.select, wait: 4.0)
        snap("title-page")
        if el("page.title").waitForExistence(timeout: 8) {
            press(.down, wait: 1.0)
            snap("title-page-down")
            press(.down, wait: 1.0)
            snap("title-page-down2")
            back(wait: 2.0)
            XCTAssertTrue(wait(5) { self.focusedLabel == card }, "BACK should restore the focus on '\(card)', \(focusInfo)")
        }
        snap("title-back")
    }

    /// Live player: select shows the info bar; logo, title, times, progress and "Dopo:" all inside the safe area.
    func testLiveInfoBar() {
        launch(["-nxLiveTest", NxUITestCase.testStream, "-nxDemoEpg", "-nxPlayFirst"], waitFor: "player.surface", timeout: 90, settle: 0)
        pause(10)
        press(.select, wait: 1.5)
        snap("live-info-bar")
        let bar = el("player.infobar")
        XCTAssertTrue(bar.waitForExistence(timeout: 4), "select should show the info bar")
        if bar.exists {
            XCTAssertLessThanOrEqual(bar.frame.maxX, 1920 - 60, "the info bar runs past the safe area: \(bar.frame)")
        }
        let dopo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Dopo:'")).firstMatch
        XCTAssertTrue(dopo.exists, "the info bar should say what comes next ('Dopo: …')")
        if dopo.exists { XCTAssertLessThanOrEqual(dopo.frame.maxX, 1920 - 60, "'Dopo:' runs past the safe area: \(dopo.frame)") }
        // tune the channel with the doubled rows (the second of the list) from Canali: "Dopo:" must still be there
        back(wait: 1.2)
        press(.left, wait: 1.5)
        press(.down, wait: 0.8)
        press(.select, wait: 4.0)
        if el("player.panel.channels").exists { back(wait: 1.2) }
        press(.select, wait: 1.5)
        snap("live-info-bar-ch2")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Dopo:'")).firstMatch.exists, "'Dopo:' vanished on a channel whose guide lists a programme twice")
        back(wait: 1.2)
    }
}
