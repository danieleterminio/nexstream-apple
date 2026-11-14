import XCTest

/// Base of the Apple TV UI tests: launches the app with the build pipeline's demo arguments, drives it with the Siri
/// Remote (`XCUIRemote`) and attaches a screenshot after every important step.
///
/// Identifiers the app sets for these tests (keep them when the views change):
/// `rail.<section>` (side menu entries: search, home, live, guide, movies, series, mine, settings),
/// `section.<section>` (root of each section page), `page.title` (title page),
/// `exit.stay` / `exit.leave` ("Vuoi uscire da NexStream?"),
/// `settings.cat.<category>`, `settings.rows`, `settings.choice`,
/// `player.surface`, `player.controls`, `player.option.<id>` (episodes, tracks, speed, source, next), `player.panel.<panel>`.
/// Where an identifier is missing the tests fall back to the spec's Italian labels (docs/tv-experience.md).
class NxUITestCase: XCTestCase {
    var app: XCUIApplication!
    let remote = XCUIRemote.shared
    private var shot = 0

    static let sections = ["search", "home", "live", "guide", "movies", "series", "mine", "settings"]
    /// Apple's public HLS sample, also used by the screenshot pipeline (build.yml shots).
    static let testStream = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        if let a = app, a.state != .notRunning { snap("end") }
        super.tearDown()
    }

    // MARK: launch

    /// Starts the app with `-nxDemo -nxSeed` plus `extra`, then waits for `waitFor` (an identifier) to exist.
    func launch(_ extra: [String] = [], waitFor id: String? = "rail.home", timeout: TimeInterval = 60, settle: Double = 3) {
        app = XCUIApplication()
        app.launchArguments = ["-nxDemo", "-nxSeed"] + extra
        app.launch()
        if let id = id {
            let ok = el(id).waitForExistence(timeout: timeout)
            if !ok { snap("launch-timeout-\(id)") }
            XCTAssertTrue(ok, "\(id) did not appear within \(Int(timeout)) s after launch")
        }
        pause(settle)
        snap("launched")
    }

    // MARK: queries

    /// Any element with this accessibility identifier.
    func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }
    /// Any element whose label is exactly `label` (the spec's texts).
    func labelled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    func text(_ t: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", t, t)).firstMatch
    }

    var focused: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }
    var focusedId: String { let f = focused; return f.exists ? f.identifier : "" }
    var focusedLabel: String { let f = focused; return f.exists ? f.label : "" }
    /// Short description of the focus for failure messages.
    var focusInfo: String {
        let f = focused
        return f.exists ? "focus id='\(f.identifier)' label='\(f.label)' type=\(f.elementType.rawValue)" : "no focused element"
    }
    var railFocused: Bool { focusedId.hasPrefix("rail.") }

    /// The focused element is inside the container with this identifier.
    func focusInside(_ container: String) -> Bool {
        let c = el(container)
        guard c.exists else { return false }
        return c.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).count > 0
    }

    /// Polls `cond` until it holds or `timeout` passes.
    @discardableResult
    func wait(_ timeout: TimeInterval = 6, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if cond() { return true }
            pause(0.4)
        } while Date() < end
        return cond()
    }
    func waitFocus(_ id: String, _ timeout: TimeInterval = 6) -> Bool { wait(timeout) { focusedId == id } }
    func waitGone(_ e: XCUIElement, _ timeout: TimeInterval = 6) -> Bool { wait(timeout) { !e.exists } }

    // MARK: remote

    func press(_ b: XCUIRemote.Button, _ times: Int = 1, wait w: Double = 0.7) {
        for _ in 0..<times {
            remote.press(b)
            pause(w)
        }
    }
    func back(wait w: Double = 1.0) { press(.menu, wait: w) }
    func longPress(_ b: XCUIRemote.Button, _ secs: TimeInterval = 1.2) {
        remote.press(b, forDuration: secs)
        pause(0.8)
    }
    func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    // MARK: checks

    func snap(_ name: String) {
        shot += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-%@", shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    func assertAlive(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app left the foreground after: \(step)", file: file, line: line)
    }

    // MARK: rail

    /// LEFT until the side menu has the focus (spec 1: LEFT from the page's left edge opens the rail).
    @discardableResult
    func openRailWithLeft(max: Int = 8) -> Bool {
        for _ in 0..<max {
            if railFocused { return true }
            press(.left, wait: 0.6)
        }
        return wait(2) { railFocused }
    }

    /// Moves the focus inside the rail onto `rail.<section>` with UP/DOWN.
    @discardableResult
    func moveRail(to section: String) -> Bool {
        guard let target = NxUITestCase.sections.firstIndex(of: section) else { return false }
        for _ in 0..<12 {
            let cur = focusedId
            guard cur.hasPrefix("rail.") else { return false }
            let name = String(cur.dropFirst(5))
            guard let i = NxUITestCase.sections.firstIndex(of: name) else { return false }
            if i == target { return true }
            press(i < target ? .down : .up, wait: 0.5)
        }
        return focusedId == "rail.\(section)"
    }

    // MARK: player

    /// The "-12:34" style texts of the seek bar (elapsed and remaining).
    var timeTexts: [String] {
        app.staticTexts.allElementsBoundByIndex.compactMap { t -> String? in
            let l = t.label
            return l.range(of: #"^-?\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil ? l : nil
        }
    }

    var playerShown: Bool { el("player.surface").exists }

    /// BACK until the player is gone (at most `max` presses); the app must stay in the foreground after each.
    func closePlayerWithBack(max: Int = 4) -> Int? {
        for i in 1...max {
            back(wait: 1.5)
            assertAlive("BACK #\(i) in the player")
            if !playerShown { return i }
        }
        return nil
    }
}
