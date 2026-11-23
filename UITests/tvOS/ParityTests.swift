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
        // the demo Home order depends on what is on air: go down until a row is long enough for three moves right
        // (a short row keeps its cards where they are)
        var rowTries = 0
        repeat {
            press(.down, wait: 1.2)
            snap("home-row\(4 + rowTries)")
            press(.right, 3, wait: 0.9)
            pause(0.8)
            f = focusFrame
            rowTries += 1
        } while f.minX - rowLeft >= 170 && rowTries < 4
        snap("home-row4-right3")
        // a Top 10 poster has its big rank number before it (up to ~150 pt): the cell starts at the edge, the poster after
        XCTAssertLessThan(f.minX - rowLeft, 170, "the focused card should come to the row's left edge (x≈\(rowLeft)): \(f), \(focusInfo)")
        XCTAssertGreaterThan(f.minX, rowLeft - 40, "the focused card is cut on the left: \(f)")
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

    /// Guida TV with the guide written again every 10 s (-nxEpgRefresh, new rows for the same programmes): the focus
    /// stays on the same cell through two refreshes instead of falling back to the side menu.
    func testGuideFocusSurvivesRefresh() {
        launch(["-nxSection", "guide", "-nxDemoEpg", "-nxEpgRefresh"], waitFor: "rail.guide", settle: 6)
        press(.down, wait: 1.0)
        press(.down, wait: 1.0)
        press(.right, wait: 1.0)
        let cell = focusedLabel
        snap("guide-refresh-before")
        XCTAssertTrue(focusInside("section.guide"), "the focus should be in the guide, \(focusInfo)")
        // two refreshes (10 s apart) with the focus resting on the cell
        pause(22)
        snap("guide-refresh-after")
        XCTAssertFalse(railFocused, "a guide refresh moved the focus to the side menu, \(focusInfo)")
        XCTAssertTrue(focusInside("section.guide"), "a guide refresh took the focus out of the guide, \(focusInfo)")
        XCTAssertEqual(focusedLabel, cell, "the focus should still be on '\(cell)'")
        // and the remote still moves inside the grid
        press(.right, wait: 1.0)
        XCTAssertTrue(focusInside("section.guide"), "RIGHT after the refresh left the guide, \(focusInfo)")
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
