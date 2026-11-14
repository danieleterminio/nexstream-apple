import XCTest

/// On-demand player (spec 3): -nxPlayVod opens Breaking Bad S4:E5 a moment after launch, -nxVodTest makes it play
/// Apple's HLS sample instead of searching the sources.
final class VodPlayerTests: NxUITestCase {

    private func openVod() {
        launch(["-nxPlayVod", "tv:1396:4:5", "-nxVodTest", NxUITestCase.testStream], waitFor: "player.surface", timeout: 90, settle: 0)
        // let the stream start (controls auto-hide 5 s after it plays)
        pause(12)
        snap("playing")
        assertAlive("opening the player")
    }

    /// Select toggles pause: paused = the bar and "Stai guardando" stay; select again plays.
    func testSelectTogglesPause() {
        openVod()
        press(.select, wait: 1.5)
        snap("paused")
        XCTAssertTrue(el("player.controls").exists, "the controls should be visible while paused")
        XCTAssertTrue(text("Stai guardando").exists, "paused: 'Stai guardando' should be shown")
        pause(6)
        XCTAssertTrue(el("player.controls").exists, "the controls should stay while paused")
        press(.select, wait: 1.5)
        snap("playing-again")
        XCTAssertFalse(text("Stai guardando").exists, "select again should resume")
        XCTAssertTrue(wait(9) { !self.el("player.controls").exists }, "the controls should hide about 5 s after resuming")
        snap("controls-hidden")
        assertAlive("pause / play")
    }

    /// Play/pause key toggles pause too.
    func testPlayPauseKeyTogglesPause() {
        openVod()
        press(.playPause, wait: 1.5)
        snap("paused")
        XCTAssertTrue(text("Stai guardando").exists, "play/pause should pause")
        press(.playPause, wait: 1.5)
        XCTAssertFalse(text("Stai guardando").exists, "play/pause again should resume")
    }

    /// LEFT / RIGHT seek: the times on the bar move (paused, so only the seek moves them).
    func testLeftRightSeek() {
        openVod()
        press(.select, wait: 1.5)
        let before = timeTexts
        snap("paused-before-seek")
        XCTAssertFalse(before.isEmpty, "no times on the bar")
        press(.right, 3, wait: 0.3)
        pause(1.5)
        let after = timeTexts
        snap("after-right")
        XCTAssertNotEqual(before, after, "RIGHT ×3 did not move the times (\(before) → \(after))")
        press(.left, 3, wait: 0.3)
        pause(1.5)
        let rewound = timeTexts
        snap("after-left")
        XCTAssertNotEqual(after, rewound, "LEFT ×3 did not move the times (\(after) → \(rewound))")
        assertAlive("seeking")
    }

    /// With the controls up, DOWN focuses the option row; UP goes back to the bar.
    func testDownFocusesOptionRow() {
        openVod()
        press(.up, wait: 1.0)          // any key shows the controls
        XCTAssertTrue(el("player.controls").waitForExistence(timeout: 3), "UP should show the controls")
        press(.down, wait: 1.0)
        snap("option-row")
        XCTAssertTrue(focusedId.hasPrefix("player.option."), "DOWN should focus the option row, \(focusInfo)")
        XCTAssertTrue(labelled("Audio e sottotitoli").exists || el("player.option.tracks").exists, "no 'Audio e sottotitoli' in the option row")
        press(.up, wait: 1.0)
        snap("back-to-bar")
        XCTAssertEqual(focusedId, "player.surface", "UP from the option row should return to the bar")
    }

    /// DOWN straight from playing (controls hidden) also reaches the option row (spec: keys with controls hidden).
    func testDownFromHiddenControlsFocusesOptionRow() {
        openVod()
        XCTAssertFalse(el("player.controls").exists, "the controls should be hidden while playing")
        press(.down, wait: 1.0)
        snap("after-down")
        XCTAssertTrue(focusedId.hasPrefix("player.option."), "DOWN with the controls hidden should focus the option row, \(focusInfo)")
    }

    /// "Audio e sottotitoli": select opens the panel (Audio | Sottotitoli), BACK closes it back to the option, then
    /// BACK walks out of the player without leaving the app.
    func testTracksPanelOpensClosesThenBackClosesPlayer() {
        openVod()
        press(.up, wait: 1.0)
        press(.down, wait: 1.0)
        var found = false
        for _ in 0..<6 {
            if focusedId == "player.option.tracks" || focusedLabel == "Audio e sottotitoli" { found = true; break }
            press(.right, wait: 0.6)
        }
        snap("on-tracks")
        XCTAssertTrue(found, "could not focus 'Audio e sottotitoli', \(focusInfo)")
        press(.select, wait: 1.5)
        snap("tracks-panel")
        assertAlive("select on Audio e sottotitoli")
        let panel = el("player.panel.tracks")
        XCTAssertTrue(panel.waitForExistence(timeout: 4) || text("Sottotitoli").exists, "the Audio e sottotitoli panel did not open")
        XCTAssertTrue(text("Audio").exists && text("Sottotitoli").exists, "the panel should have the Audio and Sottotitoli columns")
        press(.right, wait: 0.8)
        snap("tracks-right-column")
        back(wait: 1.2)
        snap("panel-closed")
        assertAlive("BACK on the panel")
        XCTAssertTrue(waitGone(panel, 4), "BACK should close the panel")
        XCTAssertTrue(wait(3) { self.focusedId == "player.option.tracks" || self.focusedLabel == "Audio e sottotitoli" }, "the focus should return to 'Audio e sottotitoli', \(focusInfo)")
        let presses = closePlayerWithBack(max: 4)
        snap("player-closed")
        XCTAssertNotNil(presses, "4 BACKs did not close the player")
        assertAlive("closing the player")
        XCTAssertTrue(el("rail.home").waitForExistence(timeout: 5), "after the player the app should be back on its page")
    }

    /// BACK while playing (controls hidden) closes the player at once; the app stays.
    func testBackWhilePlayingClosesPlayer() {
        openVod()
        XCTAssertFalse(el("player.controls").exists, "the controls should be hidden while playing")
        back(wait: 2.0)
        snap("after-back")
        assertAlive("BACK while playing")
        XCTAssertFalse(playerShown, "BACK with the controls hidden should close the player")
    }

    /// Paused, BACK must not leave the app: option row → bar → hide controls → close (at most 3 BACKs).
    func testBackChainWhenPausedStaysInApp() {
        openVod()
        press(.select, wait: 1.5)
        press(.down, wait: 1.0)
        snap("paused-option-row")
        let presses = closePlayerWithBack(max: 4)
        snap("closed")
        XCTAssertNotNil(presses, "4 BACKs did not close the player")
        assertAlive("BACK chain when paused")
    }
}

/// Live player (spec 4): -nxLiveTest plays Apple's HLS sample for every channel, -nxPlayFirst opens the first channel.
final class LivePlayerTests: NxUITestCase {

    private func openLive() {
        launch(["-nxLiveTest", NxUITestCase.testStream, "-nxPlayFirst"], waitFor: "player.surface", timeout: 90, settle: 0)
        pause(10)
        snap("playing")
        assertAlive("opening the live player")
    }

    /// The channel playing, read from the Canali panel (the focus starts on the channel playing).
    private func channelFromPanel(_ tag: String) -> String {
        press(.left, wait: 1.5)
        let shown = el("player.panel.channels").waitForExistence(timeout: 4) || text("Canali").exists
        XCTAssertTrue(shown, "LEFT should open Canali")
        _ = wait(3) { !self.focusedLabel.isEmpty && self.focusedId != "player.surface" }
        let l = focusedLabel
        snap("canali-\(tag)")
        back(wait: 1.2)
        XCTAssertTrue(waitGone(el("player.panel.channels"), 4), "BACK should close Canali")
        return l
    }

    /// UP / DOWN zap to the next / previous channel.
    func testUpDownZap() {
        openLive()
        let first = channelFromPanel("start")
        XCTAssertFalse(first.isEmpty, "no channel focused in Canali")
        press(.up, wait: 4.0)
        snap("after-up")
        assertAlive("UP zap")
        let second = channelFromPanel("after-up")
        XCTAssertNotEqual(first, second, "UP did not change the channel")
        press(.down, wait: 4.0)
        snap("after-down")
        assertAlive("DOWN zap")
        let third = channelFromPanel("after-down")
        XCTAssertEqual(first, third, "DOWN after UP should return to the first channel")
    }

    /// LEFT opens Canali, BACK closes it, BACK (≤ 2) closes the player; the app stays.
    func testLeftOpensCanaliBackClosesThenBackClosesPlayer() {
        openLive()
        press(.left, wait: 1.5)
        snap("canali")
        assertAlive("LEFT")
        XCTAssertTrue(el("player.panel.channels").waitForExistence(timeout: 4) || text("Canali").exists, "LEFT should open Canali")
        XCTAssertFalse(focusedId == "player.surface", "the focus should be in the channel list, \(focusInfo)")
        press(.down, wait: 0.6)
        snap("canali-moved")
        back(wait: 1.2)
        snap("canali-closed")
        assertAlive("BACK on Canali")
        XCTAssertTrue(waitGone(el("player.panel.channels"), 4), "BACK should close Canali")
        XCTAssertTrue(playerShown, "closing Canali should not close the player")
        let presses = closePlayerWithBack(max: 3)
        snap("player-closed")
        XCTAssertNotNil(presses, "3 BACKs did not close the live player")
        assertAlive("closing the live player")
    }

    /// RIGHT opens the programme guide of the channel (spec: "Guida"); today the options panel.
    func testRightOpensGuideOrOptions() {
        openLive()
        press(.right, wait: 1.5)
        snap("right-panel")
        assertAlive("RIGHT")
        let guide = el("player.panel.guide").exists || text("Guida").exists
        XCTAssertTrue(guide, "RIGHT should open the Guida panel (spec 4)")
        back(wait: 1.2)
        assertAlive("BACK on the panel")
    }

    /// Select shows the info bar with the option row ("Canali", "Guida", "Audio e sottotitoli"…).
    func testSelectShowsInfoBarWithOptions() {
        openLive()
        press(.select, wait: 1.5)
        snap("info-bar")
        XCTAssertTrue(el("player.controls").exists, "select should show the info bar")
        XCTAssertTrue(labelled("Canali").exists, "the option row should have 'Canali'")
        XCTAssertTrue(labelled("Audio e sottotitoli").exists, "the option row should have 'Audio e sottotitoli'")
        back(wait: 1.2)
        XCTAssertTrue(playerShown, "BACK with the info bar up should only hide it")
        assertAlive("BACK on the info bar")
    }
}
