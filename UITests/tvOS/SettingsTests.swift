import XCTest

/// Impostazioni on the TV (docs/settings-layout.md): categories → rows → a choice in place, and the BACK chain
/// choice → rows → categories → rail.
final class SettingsTests: NxUITestCase {

    private func openSettings() {
        launch(["-nxSection", "settings"], waitFor: "rail.settings", settle: 3)
        XCTAssertTrue(wait(5) { focusedId.hasPrefix("settings.cat.") }, "the focus should start on a category, \(focusInfo)")
    }

    /// Moving onto a category shows its rows at once; RIGHT enters the rows.
    func testCategoriesThenRightIntoRows() {
        openSettings()
        XCTAssertEqual(focusedId, "settings.cat.profile", "the first category should be focused")
        press(.down, wait: 1.0)
        snap("on-playback")
        XCTAssertEqual(focusedId, "settings.cat.playback")
        XCTAssertTrue(wait(3) { self.labelBegins("Episodio successivo automatico").exists }, "the Riproduzione rows are not shown on the right")
        press(.right, wait: 1.0)
        snap("in-rows")
        XCTAssertTrue(focusInside("settings.rows"), "RIGHT should enter the rows, \(focusInfo)")
        assertAlive("RIGHT into the rows")
    }

    /// Select on a category enters its rows too.
    func testSelectOnCategoryEntersRows() {
        openSettings()
        press(.down, wait: 1.0)
        press(.select, wait: 1.2)
        snap("in-rows")
        XCTAssertTrue(focusInside("settings.rows"), "select on a category should enter the rows, \(focusInfo)")
    }

    /// The whole chain: Riproduzione → "Lingua dell'audio" → the choice list in place → BACK → the rows (focus on that
    /// row) → BACK → the categories (on Riproduzione) → BACK → the rail (on Impostazioni).
    func testChoiceInPlaceAndBackChain() {
        openSettings()
        press(.down, wait: 1.0)
        press(.right, wait: 1.0)
        XCTAssertTrue(focusInside("settings.rows"), "RIGHT should enter the rows, \(focusInfo)")
        var found = false
        for _ in 0..<8 {
            if focusedLabel.hasPrefix("Lingua dell'audio") { found = true; break }
            press(.down, wait: 0.7)
        }
        snap("on-audio-row")
        XCTAssertTrue(found, "could not reach the row Lingua dell'audio, \(focusInfo)")
        press(.select, wait: 1.5)
        snap("choice")
        assertAlive("select on Lingua dell'audio")
        XCTAssertTrue(el("settings.choice").waitForExistence(timeout: 4), "the choice did not open in place")
        XCTAssertTrue(wait(3) { focusInside("settings.choice") }, "the focus is not in the choice list, \(focusInfo)")
        press(.down, wait: 0.7)
        snap("choice-moved")

        back(wait: 1.2)
        snap("back-to-rows")
        assertAlive("BACK on the choice")
        XCTAssertTrue(waitGone(el("settings.choice"), 4), "BACK should close the choice")
        XCTAssertTrue(wait(3) { focusInside("settings.rows") }, "BACK on a choice should return to the rows, \(focusInfo)")
        XCTAssertTrue(focusedLabel.hasPrefix("Lingua dell'audio"), "the focus should be on the row that opened the choice, \(focusInfo)")

        back(wait: 1.2)
        snap("back-to-categories")
        assertAlive("BACK on the rows")
        XCTAssertEqual(focusedId, "settings.cat.playback", "BACK on the rows should return to the category")

        back(wait: 1.2)
        snap("back-to-rail")
        assertAlive("BACK on the categories")
        XCTAssertTrue(waitFocus("rail.settings", 3), "BACK on the categories should focus the rail on Impostazioni, \(focusInfo)")
    }

    /// Picking a value applies it and returns to the rows with the focus on that row.
    func testPickingAValueReturnsToTheRow() {
        launch(["-nxSection", "settings", "-nxSettingsCat", "live"], waitFor: "rail.settings", settle: 3)
        press(.right, wait: 1.0)
        XCTAssertTrue(wait(3) { focusInside("settings.rows") }, "RIGHT should enter the rows, \(focusInfo)")
        XCTAssertTrue(focusedLabel.hasPrefix("Qualità video"), "first row should be Qualità video, \(focusInfo)")
        press(.select, wait: 1.5)
        XCTAssertTrue(el("settings.choice").waitForExistence(timeout: 4), "the choice did not open in place")
        snap("quality-choice")
        press(.select, wait: 1.5)
        snap("after-pick")
        XCTAssertTrue(waitGone(el("settings.choice"), 4), "picking a value should close the choice")
        XCTAssertTrue(focusedLabel.hasPrefix("Qualità video"), "the focus should be back on Qualità video, \(focusInfo)")
    }

    private func labelBegins(_ p: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", p)).firstMatch
    }
}
