import XCTest

/// Spec behaviour not covered by the first suite: the live player's Guida / Info programma / zap banner / Canali chips,
/// the on-demand panels (Episodi with a season switch, Velocità), the end-of-episode screen, the settings categories,
/// the profile entry of the side menu, play/pause on a card and pushed pages from the TV guide.

// MARK: - live player

final class LivePanelTests: NxUITestCase {

    private func openLive() {
        launch(["-nxLiveTest", NxUITestCase.testStream, "-nxDemoEpg", "-nxPlayFirst"], waitFor: "player.surface", timeout: 90, settle: 0)
        pause(10)
        snap("playing")
        assertAlive("opening the live player")
    }

    /// The option row of the info bar: select shows it, LEFT/RIGHT walk it to `id`.
    private func focusOption(_ id: String) -> Bool {
        if !focusedId.hasPrefix("player.option.") { press(.select, wait: 1.2) }
        let order = ["channels", "guide", "tracks", "info", "fav", "versions"]
        guard let target = order.firstIndex(of: id) else { return false }
        for _ in 0..<8 {
            let cur = focusedId
            guard cur.hasPrefix("player.option.") else { return false }
            guard let i = order.firstIndex(of: String(cur.dropFirst(14))) else { return false }
            if i == target { return true }
            press(i < target ? .right : .left, wait: 0.6)
        }
        return focusedId == "player.option.\(id)"
    }

    /// RIGHT opens Guida (the next programmes of the channel); select on the programme on now opens Info programma;
    /// BACK returns to Guida, BACK closes it and the player is still there.
    func testGuidePanelThenInfoAndBack() {
        openLive()
        press(.right, wait: 1.5)
        snap("guide")
        XCTAssertTrue(el("player.panel.guide").waitForExistence(timeout: 4), "RIGHT should open the Guida panel")
        XCTAssertFalse(focusedId == "player.surface", "the focus should be on a programme, \(focusInfo)")
        press(.right, wait: 0.8)
        snap("guide-moved")
        press(.left, wait: 0.8)
        press(.select, wait: 1.5)
        snap("info-from-guide")
        assertAlive("select on the programme on now")
        XCTAssertTrue(el("player.panel.info").waitForExistence(timeout: 4), "select on the programme on now should open Info programma, \(focusInfo)")
        back(wait: 1.2)
        snap("back-to-guide")
        XCTAssertTrue(el("player.panel.guide").waitForExistence(timeout: 4), "BACK on Info programma should return to Guida")
        back(wait: 1.2)
        snap("guide-closed")
        assertAlive("BACK on Guida")
        XCTAssertTrue(waitGone(el("player.panel.guide"), 4), "BACK should close Guida")
        XCTAssertTrue(playerShown, "closing Guida should not close the player")
    }

    /// "Info programma" from the option row; BACK puts the focus back on that option.
    func testInfoProgrammaFromOptionRow() {
        openLive()
        XCTAssertTrue(focusOption("info"), "could not focus 'Info programma', \(focusInfo)")
        snap("on-info")
        press(.select, wait: 1.5)
        snap("info-panel")
        XCTAssertTrue(el("player.panel.info").waitForExistence(timeout: 4), "'Info programma' did not open its panel")
        back(wait: 1.2)
        snap("info-closed")
        XCTAssertTrue(waitGone(el("player.panel.info"), 4), "BACK should close Info programma")
        XCTAssertTrue(waitFocus("player.option.info", 3), "the focus should return to 'Info programma', \(focusInfo)")
    }

    /// "Preferito" toggles; "Audio e sottotitoli" opens its two columns and BACK closes them.
    func testFavouriteToggleAndTracksPanel() {
        openLive()
        XCTAssertTrue(focusOption("tracks"), "could not focus 'Audio e sottotitoli', \(focusInfo)")
        press(.select, wait: 1.5)
        snap("tracks")
        XCTAssertTrue(el("player.panel.tracks").waitForExistence(timeout: 4), "'Audio e sottotitoli' did not open")
        back(wait: 1.2)
        XCTAssertTrue(waitGone(el("player.panel.tracks"), 4), "BACK should close Audio e sottotitoli")
        XCTAssertTrue(waitFocus("player.option.tracks", 3), "the focus should return to 'Audio e sottotitoli', \(focusInfo)")
        XCTAssertTrue(focusOption("fav"), "could not focus 'Preferito', \(focusInfo)")
        press(.select, wait: 1.2)
        snap("fav-toggled")
        assertAlive("Preferito")
        XCTAssertTrue(el("player.option.fav").exists, "'Preferito' should still be there after the toggle")
        press(.select, wait: 1.2)
        snap("fav-back")
    }

    /// UP zaps with the compact banner (number, logo, name, programme), which goes away by itself after ~3 s.
    func testZapBannerShowsAndHides() {
        openLive()
        press(.up, wait: 0.8)
        snap("zap-banner")
        XCTAssertTrue(el("player.zap").waitForExistence(timeout: 2), "UP should show the zap banner")
        XCTAssertTrue(wait(6) { !self.el("player.zap").exists }, "the zap banner should hide after about 3 s")
        snap("banner-gone")
        // fast presses only move the cursor; BACK drops the banner without closing the player
        press(.down, wait: 0.2)
        press(.down, wait: 0.2)
        snap("zap-fast")
        back(wait: 1.0)
        assertAlive("BACK on the zap banner")
        XCTAssertTrue(playerShown, "BACK on the banner should not close the player")
    }

    /// Canali: UP from the list reaches the category chips; RIGHT walks them and the row scrolls with the focus so the
    /// focused chip is always fully on screen.
    func testCanaliChipsScrollWithFocus() {
        openLive()
        press(.left, wait: 1.5)
        XCTAssertTrue(el("player.panel.channels").waitForExistence(timeout: 4), "LEFT should open Canali")
        for _ in 0..<12 where !focusedId.hasPrefix("player.chip.") { press(.up, wait: 0.5) }
        snap("on-chips")
        XCTAssertTrue(focusedId.hasPrefix("player.chip."), "UP from the channel list should reach the chips, \(focusInfo)")
        // from the first chip
        for _ in 0..<12 where focusedId != "player.chip.fav" { press(.left, wait: 0.4) }
        var offscreen = [String]()
        for i in 0..<8 {
            press(.right, wait: 0.7)
            let f = focused
            guard f.exists else { continue }
            let r = f.frame
            let screen = app.frame
            if r.minX < screen.minX - 1 || r.maxX > screen.maxX + 1 { offscreen.append("\(i):\(f.label) \(r)") }
        }
        snap("chips-walked")
        XCTAssertTrue(offscreen.isEmpty, "focused chips off screen: \(offscreen)")
        back(wait: 1.2)
        XCTAssertTrue(waitGone(el("player.panel.channels"), 4), "BACK should close Canali")
    }
}

// MARK: - on-demand player

final class VodPanelTests: NxUITestCase {

    private func openVod(_ extra: [String] = [], wait w: Double = 12) {
        launch(["-nxPlayVod", "tv:1396:4:5", "-nxVodTest", NxUITestCase.testStream] + extra, waitFor: "player.surface", timeout: 90, settle: 0)
        pause(w)
        snap("playing")
        assertAlive("opening the player")
    }

    private func focusOption(_ id: String) -> Bool {
        if !focusedId.hasPrefix("player.option.") { press(.down, wait: 1.0) }
        for dir in [XCUIRemote.Button.left, .right] {
            for _ in 0..<6 {
                if focusedId == "player.option.\(id)" { return true }
                let before = focusedId
                press(dir, wait: 0.6)
                if focusedId == before { break }
            }
        }
        return focusedId == "player.option.\(id)"
    }

    /// Episodi: the focus starts on the episode playing; LEFT reaches the seasons, DOWN switches season (the list on the
    /// right follows), BACK closes the panel back on "Episodi".
    func testEpisodesPanelSeasonSwitch() {
        openVod()
        XCTAssertTrue(focusOption("episodes"), "could not focus 'Episodi', \(focusInfo)")
        press(.select, wait: 2.0)
        snap("episodes")
        XCTAssertTrue(el("player.panel.episodes").waitForExistence(timeout: 5), "'Episodi' did not open")
        XCTAssertTrue(text("Stagione 4").exists, "the panel should show season 4 (the one playing)")
        press(.left, wait: 1.0)
        snap("seasons")
        XCTAssertTrue(focusedLabel.hasPrefix("Stagione"), "LEFT should reach the seasons, \(focusInfo)")
        press(.down, wait: 2.5)
        snap("season-5")
        XCTAssertTrue(wait(5) { self.text("Stagione 5").exists }, "DOWN on the seasons should show season 5")
        press(.right, wait: 1.0)
        snap("season-5-episodes")
        assertAlive("moving in Episodi")
        back(wait: 1.2)
        snap("closed")
        XCTAssertTrue(waitGone(el("player.panel.episodes"), 4), "BACK should close Episodi")
        XCTAssertTrue(waitFocus("player.option.episodes", 3), "the focus should return to 'Episodi', \(focusInfo)")
    }

    /// Velocità: a compact list; picking a value applies it, closes the panel and the option shows the new speed.
    func testSpeedPanelAppliesValue() {
        openVod()
        XCTAssertTrue(focusOption("speed"), "could not focus 'Velocità', \(focusInfo)")
        let before = focusedLabel
        press(.select, wait: 1.5)
        snap("speed")
        XCTAssertTrue(el("player.panel.speed").waitForExistence(timeout: 4), "'Velocità' did not open")
        press(.down, wait: 0.8)
        press(.select, wait: 1.5)
        snap("speed-picked")
        XCTAssertTrue(waitGone(el("player.panel.speed"), 4), "picking a speed should close the panel")
        XCTAssertTrue(waitFocus("player.option.speed", 3), "the focus should return to 'Velocità', \(focusInfo)")
        XCTAssertNotEqual(focusedLabel, before, "the option should show the new speed")
    }

    /// End of an episode with autoplay off: the next episode, "Guarda ora" focused, BACK closes the player.
    func testEndOfEpisodeWithoutAutoplay() {
        openVod(["-nxPlayerPanel", "ended", "-nxNoAutoplay"])
        XCTAssertTrue(labelled("Guarda ora").waitForExistence(timeout: 15), "no end-of-episode screen")
        pause(1)
        snap("ended")
        XCTAssertTrue(text("Prossimo episodio").exists, "the end screen should announce the next episode")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Parte tra")).firstMatch.exists, "no countdown with autoplay off")
        XCTAssertTrue(wait(3) { self.focusedLabel == "Guarda ora" }, "'Guarda ora' should be focused, \(focusInfo)")
        pause(11)
        snap("ended-after-11s")
        XCTAssertTrue(labelled("Guarda ora").exists, "with autoplay off the end screen must wait")
        back(wait: 2.0)
        snap("closed")
        assertAlive("BACK on the end screen")
        XCTAssertFalse(playerShown, "BACK on the end screen should close the player")
    }

    /// End of an episode with autoplay on: the countdown runs ("Parte tra N secondi").
    func testEndOfEpisodeCountdown() {
        // the countdown lasts 10 s: no long wait after the start
        openVod(["-nxPlayerPanel", "ended"], wait: 0)
        XCTAssertTrue(labelled("Guarda ora").waitForExistence(timeout: 30), "no end-of-episode screen")
        snap("ended-countdown")
        let countdown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Parte tra")).firstMatch
        XCTAssertTrue(countdown.exists, "autoplay on: the countdown should be shown")
        let first = countdown.label
        pause(2.5)
        snap("ended-countdown-later")
        XCTAssertNotEqual(countdown.exists ? countdown.label : "", first, "the countdown should run")
        // at zero the next episode starts by itself (S4:E6)
        XCTAssertTrue(wait(14) { !self.labelled("Guarda ora").exists && self.playerShown }, "the next episode should start at the end of the countdown")
        snap("next-episode")
        assertAlive("countdown")
    }
}

// MARK: - pages

final class NavigationExtraTests: NxUITestCase {

    /// Every settings category is reachable with DOWN and shows its rows on the right at once.
    func testSettingsCategoriesWalk() {
        launch(["-nxSection", "settings"], waitFor: "rail.settings", settle: 3)
        XCTAssertTrue(wait(5) { self.focusedId.hasPrefix("settings.cat.") }, "the focus should start on a category, \(focusInfo)")
        for c in ["profile", "playback", "live", "home", "line", "help"] {
            XCTAssertEqual(focusedId, "settings.cat.\(c)", "walking the categories")
            XCTAssertTrue(el("settings.rows").exists, "no rows shown for \(c)")
            snap("cat-\(c)")
            press(.down, wait: 0.8)
        }
        XCTAssertEqual(focusedId, "settings.cat.help", "DOWN on the last category should stay there")
        assertAlive("categories walk")
    }

    /// The profile entry of the side menu opens "Chi guarda?"; picking a profile goes back into the app.
    func testRailProfileOpensPicker() {
        launch()
        XCTAssertTrue(openRailWithLeft(), "LEFT never reached the rail, \(focusInfo)")
        for _ in 0..<10 where focusedId != "rail.profile" { press(.up, wait: 0.5) }
        snap("on-profile")
        XCTAssertEqual(focusedId, "rail.profile", "UP should reach the profile entry")
        press(.select, wait: 2.0)
        snap("picker")
        assertAlive("select on the profile entry")
        XCTAssertTrue(text("Chi guarda?").waitForExistence(timeout: 8), "the profile entry should open 'Chi guarda?'")
        XCTAssertTrue(wait(4) { self.focused.exists }, "nothing focused on the picker")
        press(.select, wait: 3.0)
        snap("after-pick")
        XCTAssertTrue(el("rail.home").waitForExistence(timeout: 15), "picking a profile did not open the app")
    }

    /// Play/pause on the first Home card (a programme on now) plays its channel at once; BACK returns to the card.
    func testPlayPauseOnCardPlaysAndBackRestoresFocus() {
        launch(["-nxLiveTest", NxUITestCase.testStream, "-nxVodTest", NxUITestCase.testStream, "-nxDemoEpg"], settle: 8)
        XCTAssertTrue(wait(4) { self.focused.exists && !self.railFocused }, "no focus in the page, \(focusInfo)")
        let card = focusedLabel
        press(.playPause, wait: 3.0)
        snap("playing")
        assertAlive("play/pause on '\(card)'")
        XCTAssertTrue(wait(8) { self.playerShown }, "play/pause on a card on now should play it, \(focusInfo)")
        pause(4)
        let n = closePlayerWithBack(max: 3)
        snap("closed")
        XCTAssertNotNil(n, "BACK did not close the player")
        XCTAssertTrue(wait(5) { self.focusedLabel == card }, "the focus should be back on '\(card)', \(focusInfo)")
    }

    /// Guida TV: select on a programme pushes its page; BACK returns to the guide with the focus on that programme.
    func testGuideProgrammePageAndBack() {
        launch(["-nxSection", "guide", "-nxDemoEpg"], waitFor: "rail.guide", settle: 8)
        XCTAssertTrue(wait(4) { self.focused.exists && !self.railFocused }, "no focus in the guide, \(focusInfo)")
        // from the chips down into the grid
        press(.down, wait: 1.0)
        press(.down, wait: 1.0)
        let cell = focusedLabel
        snap("on-cell")
        XCTAssertTrue(focusInside("section.guide"), "the focus should be in the guide, \(focusInfo)")
        press(.select, wait: 3.0)
        snap("pushed")
        assertAlive("select on '\(cell)'")
        if playerShown {
            // a channel cell plays: then BACK must come back to it
            _ = closePlayerWithBack(max: 3)
        } else {
            XCTAssertTrue(wait(5) { self.focused.exists && !self.focusInside("section.guide") }, "select on '\(cell)' did not push a page, \(focusInfo)")
            back(wait: 2.0)
        }
        snap("back")
        assertAlive("BACK to the guide")
        XCTAssertFalse(text("Vuoi uscire da NexStream?").exists, "BACK on a pushed page must not ask to exit")
        XCTAssertTrue(wait(5) { self.focusInside("section.guide") }, "BACK should return to the guide, \(focusInfo)")
        XCTAssertEqual(focusedLabel, cell, "the focus should be back on '\(cell)'")
    }

    /// Diretta: the first focus is in the page (the genre chip or a channel); BACK goes to the rail on Diretta.
    func testLiveSectionStartsFocusedAndBackToRail() {
        launch(["-nxSection", "live"], waitFor: "rail.live", settle: 6)
        XCTAssertTrue(wait(4) { self.focused.exists && self.focusInside("section.live") }, "Diretta should start with the focus in the page, \(focusInfo)")
        back(wait: 1.2)
        snap("rail")
        assertAlive("BACK on Diretta")
        XCTAssertTrue(waitFocus("rail.live", 3), "BACK on Diretta should focus rail.live, \(focusInfo)")
    }
}
