#if os(tvOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Combine

// The Apple TV player, drawn like Netflix on the Apple TV: nothing on the picture while it plays, any key brings the
// title (top left), the progress bar and the row of options (bottom). Every panel (audio and subtitles, episodes,
// speed, source, channels) is drawn inside the player with its own focus, so BACK always closes just the top layer and
// never reaches the system (which would leave the app).

/// The panels the player draws over the picture.
enum TvPanel: String, Equatable {
    case tracks, episodes, speed, source, options, channels, quality
}

/// What has the remote's focus in the on-demand player.
enum TvVodFocus: Hashable {
    case surface
    case option(String)
    case credits(Int)
}

/// Netflix-like seeking: each click moves 10 s; clicks that keep coming within 400 ms move further and further
/// (10, 10, 20, 30, 60, 120 s). The model applies the target after 700 ms without input.
struct TvSeekRamp {
    static let steps: [Millis] = [10_000, 10_000, 20_000, 30_000, 60_000, 120_000]
    private var last: TimeInterval = 0
    private var dir = 0
    private var streak = 0

    mutating func step(_ d: Int) -> Millis {
        let now = Date().timeIntervalSince1970
        if d == dir && now - last < 0.4 { streak += 1 } else { streak = 0 }
        dir = d
        last = now
        let i = min(streak, TvSeekRamp.steps.count - 1)
        return Millis(d) * TvSeekRamp.steps[i]
    }
}

/// "S1:E3 Titolo episodio" for a series, the year for a film.
func tvEpisodeLine(_ r: PlayRequest, fallback: String? = nil) -> String {
    let d = r.details
    if d.isTv {
        let t = (r.episodeTitle ?? fallback ?? "").trimmingCharacters(in: .whitespaces)
        return "S\(r.season):E\(r.episode)" + (t.isEmpty ? "" : " \(t)")
    }
    return d.year > 0 ? String(d.year) : ""
}

// MARK: - on-demand layer

/// What sits over the picture while an on-demand title plays (phase `.playing`).
struct TvVodLayer: View {
    @ObservedObject var model: VodPlayerModel
    @ObservedObject var player: NxPlayer
    @ObservedObject var chrome: ChromeState
    /// The 5 s countdown of "Prossimo episodio" during the credits (owned by VodPlayerView).
    let countdown: NextCountdown
    @EnvironmentObject var app: AppModel
    @State private var panel: TvPanel? = nil
    @State private var ramp = TvSeekRamp()
    @State private var flash: String? = nil
    @State private var flashTask: Task<Void, Never>? = nil
    @State private var lastOption = "tracks"
    @State private var keys = PassthroughSubject<String, Never>()
    @State private var scrubBase: Millis = 0
    @State private var scrubApply: Task<Void, Never>? = nil
    /// A swipe moved the bar's knob: the target waits for a click (BACK drops it).
    @State private var scrubPending = false
    /// A held click on the left / right edge keeps seeking, faster and faster.
    @State private var holdTask: Task<Void, Never>? = nil
    @State private var input = TvInputTimes()
    /// The focus goes back to the bar because the controls left: that is not input, the controls stay hidden.
    @State private var quietFocus = false
    @FocusState private var focus: TvVodFocus?

    init(model: VodPlayerModel, player: NxPlayer, chrome: ChromeState, countdown: NextCountdown) {
        self.model = model
        self.player = player
        self.chrome = chrome
        self.countdown = countdown
    }

    private struct Option: Identifiable {
        let id: String
        let icon: String
        let title: String
        let action: () -> Void
    }

    private var optionFocused: Bool {
        if case .option = focus { return true }
        return false
    }
    private var showControls: Bool {
        panel == nil && (chrome.visible || model.paused || model.seekTarget != nil || optionFocused)
    }
    private var creditsShown: Bool {
        panel == nil && model.creditsVisible && model.nextRequest(auto: false) != nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                surface
                // the band of the options row stays out of the surface, so up / down move between them by geometry
                Color.clear.frame(height: 300).allowsHitTesting(false)
            }
            if player.state == .opening || player.state == .buffering { BrandLoader(size: 56) }
            // while a panel is open the bar and the option row stay drawn but cannot take the focus: a list that rebuilds its
            // lines (Cambia fonte while the sources are checked) must not lose the focus to the row behind it
            if showControls { controls.disabled(panel != nil).accessibilityElement(children: .contain).accessibilityIdentifier("player.controls").transition(.opacity) }
            if let f = flash { centreGlyph(f) }
            if creditsShown { credits }
            if let p = panel { panelView(p).accessibilityElement(children: .contain).accessibilityIdentifier("player.panel.\(p.rawValue)").transition(.opacity).zIndex(5) }
        }
        .animation(.easeOut(duration: 0.2), value: panel)
        .animation(.easeOut(duration: 0.2), value: showControls)
        .onPlayPauseCommand { if panel == nil { togglePlay() } }
        .onReceive(NotificationCenter.default.publisher(for: .nxRemoteKey)) { n in remoteKey(n.object as? String ?? "") }
        .background(TvRemotePresses(consumeArrows: panel == nil && focus == .surface && model.duration > 0,
                                    onArrow: arrowDown, onArrowUp: arrowUp, onAny: { countdown.cancel() }))
        .onAppear { focus = .surface }
        .onDisappear { holdTask?.cancel(); scrubApply?.cancel() }
        .onChange(of: focus) { _, f in
            if f == .surface { if quietFocus { quietFocus = false } else { chrome.show() } }
            if case .option(let id) = f { lastOption = id; chrome.show() }
            if f != .credits(1) && f != nil { countdown.cancel() }
            if f == nil && panel == nil { DispatchQueue.main.async { if focus == nil && panel == nil { focus = .surface } } }
        }
        // the controls left by themselves while the option row had the focus: the focus goes back to the bar, so the
        // next key acts on the video and nothing is focused out of sight
        .onChange(of: chrome.visible) { _, v in
            if !v && optionFocused && panel == nil && !model.paused { quietFocus = true; focus = .surface }
        }
        .onChange(of: creditsShown) { _, shown in
            if shown {
                focus = .credits(1)
                startCreditsCountdown(countdown, model: model, app: app)
            } else {
                countdown.reset()
                if case .credits = focus { focus = .surface }
            }
        }
        .onChange(of: panel) { _, p in if p != nil { countdown.cancel() } }
        .task { await demo() }
    }

    // MARK: surface

    /// An invisible button over the picture: it is what has the focus while the video plays, so select (the centre of
    /// the remote) reaches it as a button press.
    private var surface: some View {
        Button { select() } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(NxPlainStyle(scale: 1))
        .focused($focus, equals: .surface)
        .accessibilityIdentifier("player.surface")
        .disabled(panel != nil)
        .onMoveCommand { dir in move(dir) }
        .onExitCommand { back() }
        .background(TvTouchPan(enabled: panel == nil && focus == .surface && model.duration > 0, onBegin: panBegin, onChange: panChange, onEnd: panEnd,
                               onTouch: { input.touchAt = Date(); countdown.cancel() }))
    }

    // MARK: touch surface

    /// A swipe across the whole touch surface moves 10% of the length (at least 2 minutes); applied 500 ms after release.
    private var swipeSpan: Millis { max(120_000, model.duration / 10) }

    private func panBegin() {
        scrubApply?.cancel()
        holdTask?.cancel()
        // a second swipe carries on from where the first one left the knob (position = the pending target)
        scrubBase = model.position
        scrubPending = true
        chrome.show(auto: false)
    }

    private func panChange(_ x: CGFloat) {
        let d = Millis(Double(x) / Double(TvTouchPan.fullSwipe) * Double(swipeSpan))
        model.scrub(to: max(0, min(model.duration, scrubBase + d)))
    }

    /// Like the Apple TV app: the knob stays where the swipe left it, a click goes there; BACK (or 8 s without input)
    /// drops it and the video carries on from where it is.
    private func panEnd(_ x: CGFloat) {
        panChange(x)
        chrome.show(auto: false)
        scrubApply = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Task.isCancelled || !scrubPending { return }
            scrubPending = false
            model.seekTarget = nil
            chrome.show()
        }
    }

    private func select() {
        scrubApply?.cancel()
        scrubPending = false
        if model.seekTarget != nil { model.applySeek(); chrome.show() } else { togglePlay() }
    }

    private func togglePlay() {
        model.togglePlay()
        showFlash(model.paused ? "pause.fill" : "play.fill")
        chrome.show()
    }

    private func move(_ dir: MoveCommandDirection) {
        countdown.cancel()
        switch dir {
        case .left: moveSeek(-1)
        case .right: moveSeek(1)
        case .down: focusOptions()
        case .up: chrome.show()
        default: break
        }
    }

    /// A left / right move that did not come as a click (clicks are taken by `TvRemotePresses`): a swipe on the touch
    /// surface also produces one, and the swipe scrubs already, so it only seeks when no finger was on the surface.
    private func moveSeek(_ d: Int) {
        let now = Date()
        if now.timeIntervalSince(input.arrowAt) < 0.35 || now.timeIntervalSince(input.touchAt) < 0.5 || scrubPending { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let t = Date()
            if t.timeIntervalSince(input.touchAt) < 0.6 || t.timeIntervalSince(input.arrowAt) < 0.45 || scrubPending { return }
            seek(d)
        }
    }

    /// A click on the left / right edge: one step at once; held, a step every 0.22 s that grows (10 s up to 2 min).
    private func arrowDown(_ d: Int) {
        input.arrowAt = Date()
        countdown.cancel()
        holdTask?.cancel()
        seek(d)
        holdTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            while !Task.isCancelled {
                input.arrowAt = Date()
                seek(d)
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
        }
    }

    private func arrowUp() {
        input.arrowAt = Date()
        holdTask?.cancel()
        holdTask = nil
    }

    /// DOWN (or the phone's menu key): the controls come up with the focus on the option row.
    private func focusOptions() {
        chrome.show(auto: false)
        let id = options.contains(where: { $0.id == lastOption }) ? lastOption : (options.first?.id ?? "tracks")
        // the row is only there once the controls are drawn: ask again if the first request came too early
        DispatchQueue.main.async { focus = .option(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if panel == nil && !optionFocused { focus = .option(id) } }
    }

    private func seek(_ d: Int) {
        guard model.duration > 0 else { return }
        scrubApply?.cancel()
        scrubPending = false
        model.seekBy(ramp.step(d))
        chrome.show()
    }

    /// BACK: cancel a seek, then hide the controls, then leave the player.
    private func back() {
        holdTask?.cancel()
        if model.seekTarget != nil { scrubApply?.cancel(); scrubPending = false; model.seekTarget = nil; chrome.show(); return }
        if chrome.visible && !model.paused { chrome.hide(); return }
        app.closePlayer()
    }

    private func showFlash(_ icon: String) {
        flashTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { flash = icon }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.3)) { flash = nil }
        }
    }

    private func centreGlyph(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 64, weight: .bold)).foregroundStyle(.white)
            .frame(width: 150, height: 150).background(Color.black.opacity(0.55), in: Circle())
            .allowsHitTesting(false).transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock.padding(.horizontal, 80).padding(.top, 60)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 34) {
                TvSeekBar(position: model.position, actual: player.positionMs, duration: model.duration, seeking: model.seekTarget != nil, paused: model.paused,
                          hint: scrubPending ? "Clicca per andare qui" : nil)
                optionRow
            }
            .padding(.horizontal, 80).padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TvScrim().allowsHitTesting(false))
        .ignoresSafeArea()
    }

    private var plot: String? {
        let d = model.details
        if !d.isTv { return d.overview?.nilIfBlank }
        let ep: TmdbEpisode? = model.episodes.first(where: { $0.episodeNumber == model.request.episode })
        return ep?.overview?.nilIfBlank
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.paused { Text("Stai guardando").font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.textMuted) }
            Text(model.details.displayTitle).font(NxFont.display(model.paused ? 30 : 22, .bold)).foregroundStyle(.white).lineLimit(1)
            let line = tvEpisodeLine(model.request, fallback: model.episodes.first(where: { $0.episodeNumber == model.request.episode })?.name)
            if !line.isEmpty { Text(line).font(NxFont.ui(15, .semibold)).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1) }
            if model.paused, let p = plot {
                Text(p).font(NxFont.ui(13)).foregroundStyle(NxColor.textMuted).lineLimit(3).frame(maxWidth: 980, alignment: .leading).padding(.top, 6)
            }
        }
    }

    private var options: [Option] {
        var a = [Option]()
        if model.details.isTv && model.canBrowse { a.append(Option(id: "episodes", icon: "rectangle.stack", title: "Episodi") { open(.episodes, "episodes") }) }
        a.append(Option(id: "tracks", icon: "captions.bubble", title: "Audio e sottotitoli") { open(.tracks, "tracks") })
        a.append(Option(id: "speed", icon: "speedometer", title: model.speed == 1 ? "Velocità" : "Velocità " + Settings.speedLabel(model.speed)) { open(.speed, "speed") })
        if let s = model.stream, s.channel != "offline" { a.append(Option(id: "source", icon: "arrow.triangle.2.circlepath", title: "Cambia fonte") { open(.source, "source") }) }
        if let n = model.nextRequest(auto: false) { a.append(Option(id: "next", icon: "forward.end.fill", title: "Prossimo episodio") { app.play(n) }) }
        return a
    }

    private var optionRow: some View {
        HStack(spacing: 22) {
            ForEach(options) { o in
                TvOptionButton(icon: o.icon, title: o.title, action: o.action)
                    .focused($focus, equals: .option(o.id))
                    .accessibilityIdentifier("player.option.\(o.id)")
            }
            Spacer(minLength: 0)
        }
        .focusSection()
        // DOWN from the bar enters the row on the last option used (Audio e sottotitoli at first), not the nearest one
        .defaultFocus($focus, TvVodFocus.option(lastOption), priority: .userInitiated)
        .onExitCommand { focus = .surface }
    }

    private func open(_ p: TvPanel, _ from: String) {
        lastOption = from
        chrome.show(auto: false)
        panel = p
    }

    private func closePanel() {
        panel = nil
        chrome.show(auto: false)
        let back = lastOption
        DispatchQueue.main.async {
            if options.contains(where: { $0.id == back }) { focus = .option(back) } else { focus = .surface }
        }
    }

    // MARK: credits

    private var credits: some View {
        VStack {
            Spacer()
            HStack(spacing: 24) {
                Spacer()
                NxButton("Guarda i titoli di coda", kind: .secondary) { dismissCredits() }
                    .focused($focus, equals: .credits(0))
                    .accessibilityIdentifier("player.credits.watch")
                NextEpisodeButton(countdown: countdown) { countdown.reset(); if let n = model.nextRequest(auto: false) { app.play(n) } }
                    .focused($focus, equals: .credits(1))
            }
            .focusSection()
            .onExitCommand { dismissCredits() }
            .onMoveCommand { dir in
                countdown.cancel()
                if dir == .up || dir == .down { focus = .surface; chrome.show() }
            }
        }
        .padding(.horizontal, 80).padding(.bottom, showControls ? 300 : 90)
        .background(alignment: .bottom) {
            // keeps the two buttons readable on a bright picture
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 360).allowsHitTesting(false).opacity(showControls ? 0 : 1)
        }
        .ignoresSafeArea()
    }

    /// "Guarda i titoli di coda": the buttons leave, the episode plays to the end (the end screen still counts down).
    private func dismissCredits() {
        countdown.reset()
        model.creditsDismissed = true
        focus = .surface
    }

    // MARK: panels

    @ViewBuilder private func panelView(_ p: TvPanel) -> some View {
        switch p {
        case .tracks:
            let pid = app.pid
            TvTracksOverlay(player: model.player, keys: keys, onAudio: { name in app.core.settings.setAudioLang(pid, audioLangOf(name)) }, onClose: closePanel)
        case .episodes:
            TvEpisodesOverlay(model: model, keys: keys, onPlay: playEpisode, onClose: closePanel)
        case .speed:
            TvListOverlay(title: "Velocità", items: speedItems, keys: keys, onClose: closePanel)
        case .source:
            TvSourceOverlay(picker: model.sources, model: model, keys: keys, onPick: { row in closePanel(); model.pickSource(row, job: model.sources.job) }, onClose: closePanel)
        default:
            EmptyView()
        }
    }

    private func playEpisode(_ e: TmdbEpisode) {
        if e.seasonNumber == model.request.season && e.episodeNumber == model.request.episode { closePanel(); return }
        app.play(PlayRequest(details: model.details, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name))
    }

    private var speedItems: [TvListItem] {
        Settings.speedOptions.map { v in
            TvListItem(id: "\(v)", title: Settings.speedLabel(v), selected: v == model.speed) { model.setSpeed(v); closePanel() }
        }
    }

    // MARK: phone remote

    private func remoteKey(_ k: String) {
        guard model.phase == .playing else { return }
        if !(k == "ok" && focus == .credits(1)) { countdown.cancel() }
        if panel != nil {
            if k == "back" { closePanel() } else { keys.send(k) }
            return
        }
        if case .credits(let i) = focus {
            switch k {
            case "left": focus = .credits(0)
            case "right": focus = .credits(1)
            case "ok":
                if i == 1, let n = model.nextRequest(auto: false) { countdown.reset(); app.play(n) } else { dismissCredits() }
            case "back": dismissCredits()
            case "playpause": togglePlay()
            default: break
            }
            return
        }
        if case .option(let id) = focus {
            let opts = options
            let i = opts.firstIndex(where: { $0.id == id }) ?? 0
            switch k {
            case "left": if i > 0 { focus = .option(opts[i - 1].id) }
            case "right": if i + 1 < opts.count { focus = .option(opts[i + 1].id) }
            case "ok": if i < opts.count { opts[i].action() }
            case "up", "back": focus = .surface
            case "playpause": togglePlay()
            default: break
            }
            return
        }
        switch k {
        case "playpause": togglePlay()
        case "ok": select()
        case "left": seek(-1)
        case "right": seek(1)
        case "up": chrome.show()
        case "down", "menu": focusOptions()
        case "back": back()
        default: break
        }
    }

    // MARK: build pipeline

    /// Launch argument `-nxPlayerPanel paused|seek|scrub|options|tracks|episodes|speed|source|credits|ended|still|failed|hidden`: once the video plays, put the
    /// player in that state so the build pipeline can take its picture.
    private func demo() async {
        guard let what = Demo.value("-nxPlayerPanel"), !Demo.playerPanelDone else { return }
        Demo.playerPanelDone = true
        for _ in 0..<160 {
            if player.state == .playing && model.duration > 0 { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        NxLog.i("NxDebug", "player panel \(what)")
        switch what {
        case "paused":
            if !model.paused { togglePlay() }
        case "seek":
            for _ in 0..<5 { seek(1); try? await Task.sleep(nanoseconds: 150_000_000) }
            if let t = model.seekTarget { model.scrub(to: t) }
            chrome.show(auto: false)
        case "scrub":
            // a swipe to the right as the touch surface would report it: the knob waits for the click
            panBegin()
            panChange(TvTouchPan.fullSwipe * 0.4)
            panEnd(TvTouchPan.fullSwipe * 0.4)
        case "options":
            chrome.show(auto: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
            focus = .option("tracks")
        case "tracks": open(.tracks, "tracks")
        case "episodes": open(.episodes, "episodes")
        case "speed": open(.speed, "speed")
        case "source": open(.source, "source")
        case "credits":
            // the credits prompt: jump to 50 s from the end of an episode that has a next one
            model.seekTarget = max(0, model.duration - 50_000)
            model.applySeek()
        case "ended": model.phase = .ended
        case "still": model.phase = .stillWatching
        case "failed": model.phase = .failed("Ho provato tutte le fonti disponibili, ma nessuna riesce a riprodurre questo titolo adesso.")
        case "hidden": chrome.hide()
        default: break
        }
    }
}

// MARK: - pieces

/// The dark bands at the top and bottom that keep the controls readable.
struct TvScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.28), .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.9), location: 1)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// The thin progress bar: played part in red, a knob, elapsed and remaining time; while seeking, the target time over
/// the knob and how far it is from where the video is.
struct TvSeekBar: View {
    let position: Millis
    let actual: Millis
    let duration: Millis
    let seeking: Bool
    let paused: Bool
    /// Under the target time while a swipe waits for its click.
    var hint: String? = nil

    private func frac(_ v: Millis) -> CGFloat {
        duration > 0 ? CGFloat(max(0, min(1, Double(v) / Double(duration)))) : 0
    }

    private var delta: String {
        let d = position - actual
        return (d >= 0 ? "+" : "-") + playerClock(abs(d))
    }

    var body: some View {
        HStack(spacing: 26) {
            Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(.white).frame(width: 40)
            Text(playerClock(position)).font(NxFont.ui(13, .heavy)).foregroundStyle(.white).monospacedDigit().frame(minWidth: 110, alignment: .leading)
            bar.frame(height: 30)
            Text(duration > 0 ? "-" + playerClock(max(0, duration - position)) : "--:--").font(NxFont.ui(13, .heavy)).foregroundStyle(NxColor.textMuted).monospacedDigit().frame(minWidth: 120, alignment: .trailing)
        }
    }

    private var bar: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = frac(position)
            let a = frac(actual)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(height: seeking ? 10 : 6)
                Capsule().fill(NxColor.accent).frame(width: max(0, w * f), height: seeking ? 10 : 6)
                if seeking {
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 4, height: 22).offset(x: w * a - 2)
                }
                Circle().fill(NxColor.accent).frame(width: seeking ? 30 : 22, height: seeking ? 30 : 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: seeking ? 3 : 0))
                    .offset(x: w * f - (seeking ? 15 : 11))
                if seeking {
                    VStack(spacing: 2) {
                        Text(playerClock(position)).font(NxFont.ui(16, .heavy)).foregroundStyle(.white).monospacedDigit()
                        Text(delta).font(NxFont.ui(11, .bold)).foregroundStyle(NxColor.textMuted).monospacedDigit()
                        if let h = hint { Text(h).font(NxFont.ui(10, .semibold)).foregroundStyle(NxColor.textDim).padding(.top, 2) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .fixedSize()
                    .frame(width: 300)
                    .offset(x: max(0, min(w - 300, w * f - 150)), y: hint == nil ? -78 : -100)
                }
            }
            .frame(height: 30)
        }
        .animation(.easeOut(duration: 0.12), value: seeking)
    }
}

/// A button of the row under the progress bar: symbol and name, white on the picture, inverted under the focus.
struct TvOptionButton: View {
    let icon: String
    let title: String
    /// A toggle that is on (the live player's "Preferito"): its symbol turns gold.
    var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Focusable { f in
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(active && !f ? NxColor.gold : (f ? Color.black : Color.white))
                    Text(title).font(NxFont.ui(13, .bold)).lineLimit(1)
                }
                .foregroundStyle(f ? Color.black : Color.white)
                .padding(.horizontal, 26)
                .frame(height: 64)
                .background(f ? Color.white : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(f ? 1.05 : 1)
                .animation(.easeOut(duration: 0.15), value: f)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.96))
    }
}

/// One line of a player panel: a tick on the current one, white under the focus.
struct TvListItem: Identifiable {
    let id: String
    let title: String
    var sub: String? = nil
    var icon: String? = nil
    var selected: Bool = false
    var badge: String? = nil
    let action: () -> Void
}

struct TvRow: View {
    let item: TvListItem
    var body: some View {
        Button(action: item.action) {
            Focusable { f in
                HStack(spacing: 18) {
                    Image(systemName: "checkmark").font(.system(size: 24, weight: .heavy)).opacity(item.selected ? 1 : 0).frame(width: 30)
                    if let i = item.icon { Image(systemName: i).font(.system(size: 24, weight: .semibold)).frame(width: 36) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(NxFont.ui(16, .bold)).lineLimit(1)
                        if let s = item.sub { Text(s).font(NxFont.ui(11, .medium)).opacity(0.7).lineLimit(1) }
                    }
                    Spacer(minLength: 10)
                    if let b = item.badge {
                        Text(b).font(NxFont.ui(10, .heavy)).padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 2))
                    }
                }
                .foregroundStyle(f ? Color.black : (item.selected ? Color.white : NxColor.textMuted))
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(f ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(f ? 1.02 : 1)
                .animation(.easeOut(duration: 0.12), value: f)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.98))
    }
}

/// A list panel (Velocità, Fonte, Canali, Qualità, the live options): a column on the left of a darkened picture.
struct TvListOverlay: View {
    let title: String
    var subtitle: String? = nil
    let items: [TvListItem]
    var keys: PassthroughSubject<String, Never>? = nil
    var width: CGFloat = 820
    let onClose: () -> Void
    @FocusState private var focus: String?

    init(title: String, subtitle: String? = nil, items: [TvListItem], keys: PassthroughSubject<String, Never>? = nil, width: CGFloat = 820, onClose: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.keys = keys
        self.width = width
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.86).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(NxFont.display(24, .bold)).foregroundStyle(.white)
                if let s = subtitle { Text(s).font(NxFont.ui(12, .medium)).foregroundStyle(NxColor.textDim).padding(.top, 6) }
                list.padding(.top, 26)
            }
            .frame(width: width, alignment: .leading)
            .padding(.leading, 140).padding(.top, 80)
        }
        .onExitCommand(perform: onClose)
        .onReceive(keys ?? PassthroughSubject<String, Never>()) { k in key(k) }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { it in
                        TvRow(item: it).focused($focus, equals: it.id).id(it.id)
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 12)
            }
            .focusSection()
            .onAppear {
                let start = items.first(where: { $0.selected })?.id ?? items.first?.id
                if let s = start { proxy.scrollTo(s, anchor: .center) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = start }
            }
            .onChange(of: focus) { _, f in if let f = f { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: .center) } } }
        }
    }

    private func key(_ k: String) {
        let i = items.firstIndex(where: { $0.id == focus }) ?? 0
        switch k {
        case "up": if i > 0 { focus = items[i - 1].id }
        case "down": if i + 1 < items.count { focus = items[i + 1].id }
        case "ok": if i < items.count { items[i].action() }
        case "back": onClose()
        default: break
        }
    }
}

/// "Audio e sottotitoli": two columns side by side; a pick applies at once, BACK closes.
struct TvTracksOverlay: View {
    @ObservedObject var player: NxPlayer
    var keys: PassthroughSubject<String, Never>? = nil
    var onAudio: ((String) -> Void)? = nil
    let onClose: () -> Void
    @FocusState private var focus: String?

    init(player: NxPlayer, keys: PassthroughSubject<String, Never>? = nil, onAudio: ((String) -> Void)? = nil, onClose: @escaping () -> Void) {
        self.player = player
        self.keys = keys
        self.onAudio = onAudio
        self.onClose = onClose
    }

    private var audioItems: [TvListItem] {
        let tracks = player.audioTracks
        if tracks.isEmpty { return [TvListItem(id: "a-none", title: "Traccia predefinita", selected: true) {}] }
        return tracks.map { t in
            TvListItem(id: "a\(t.id)", title: t.name.isBlank ? "Traccia \(t.id + 1)" : t.name, selected: t.id == player.currentAudio) {
                player.currentAudio = t.id
                onAudio?(t.name)
            }
        }
    }

    private var subItems: [TvListItem] {
        let subs = player.subtitleTracks
        if subs.count <= 1 { return [TvListItem(id: "s-none", title: "Spenti", sub: "Nessun sottotitolo disponibile", selected: true) {}] }
        return subs.map { t in
            TvListItem(id: "s\(t.id)", title: t.id < 0 ? "Spenti" : (t.name.isBlank ? "Sottotitoli \(t.id)" : t.name), selected: t.id == player.currentSubtitle) {
                player.currentSubtitle = t.id
            }
        }
    }

    var body: some View {
        let _ = player.tracksVersion
        let audio = audioItems, subs = subItems
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.86).ignoresSafeArea()
            HStack(alignment: .top, spacing: 90) {
                column("Audio", audio)
                column("Sottotitoli", subs)
            }
            .padding(.leading, 180).padding(.top, 110)
        }
        .onExitCommand(perform: onClose)
        .onAppear {
            let start = audio.first(where: { $0.selected })?.id ?? audio.first?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = start }
        }
        .onReceive(keys ?? PassthroughSubject<String, Never>()) { k in key(k, audio, subs) }
    }

    private func column(_ title: String, _ items: [TvListItem]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(NxFont.display(22, .bold)).foregroundStyle(.white).padding(.leading, 34)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { it in TvRow(item: it).focused($focus, equals: it.id) }
                }
                .padding(.vertical, 12).padding(.horizontal, 12)
            }
        }
        .frame(width: 640, alignment: .leading)
        .focusSection()
    }

    private func key(_ k: String, _ audio: [TvListItem], _ subs: [TvListItem]) {
        let inAudio = (focus ?? "a").hasPrefix("a")
        let col = inAudio ? audio : subs
        let i = col.firstIndex(where: { $0.id == focus }) ?? 0
        switch k {
        case "up": if i > 0 { focus = col[i - 1].id }
        case "down": if i + 1 < col.count { focus = col[i + 1].id }
        case "left": if !inAudio { focus = (audio.first(where: { $0.selected }) ?? audio.first)?.id }
        case "right": if inAudio { focus = (subs.first(where: { $0.selected }) ?? subs.first)?.id }
        case "ok": if i < col.count { col[i].action() }
        case "back": onClose()
        default: break
        }
    }
}

/// "Episodi": the seasons on the left (when there are several), the episodes of the season in focus on the right with
/// their still, number, title, length and plot; the one playing is marked.
struct TvEpisodesOverlay: View {
    @ObservedObject var model: VodPlayerModel
    var keys: PassthroughSubject<String, Never>? = nil
    let onPlay: (TmdbEpisode) -> Void
    let onClose: () -> Void
    @EnvironmentObject var app: AppModel
    @State private var season: Int
    @State private var eps: [TmdbEpisode]
    @State private var loading = false
    @FocusState private var focus: String?

    init(model: VodPlayerModel, keys: PassthroughSubject<String, Never>? = nil, onPlay: @escaping (TmdbEpisode) -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.keys = keys
        self.onPlay = onPlay
        self.onClose = onClose
        _season = State(initialValue: model.request.season)
        _eps = State(initialValue: model.episodes)
    }

    private var seasons: [Int] {
        let all: [TmdbSeasonSummary] = model.details.seasons
        let usable: [TmdbSeasonSummary] = all.filter { $0.seasonNumber > 0 && ($0.episodeCount ?? 0) > 0 }
        var nums: [Int] = usable.map { $0.seasonNumber }
        if !nums.contains(model.request.season) { nums.append(model.request.season) }
        return nums.sorted()
    }

    private func isCurrent(_ e: TmdbEpisode) -> Bool {
        e.seasonNumber == model.request.season && e.episodeNumber == model.request.episode
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.9).ignoresSafeArea()
            HStack(alignment: .top, spacing: 60) {
                if seasons.count > 1 { seasonColumn }
                episodeColumn
            }
            .padding(.leading, 110).padding(.trailing, 90).padding(.top, 70)
        }
        .onExitCommand(perform: onClose)
        .onChange(of: focus) { _, f in
            if let f = f, f.hasPrefix("s"), let n = Int(f.dropFirst()), n != season { load(n) }
        }
        .onAppear { if eps.isEmpty { load(season) } }
        .onReceive(keys ?? PassthroughSubject<String, Never>()) { k in key(k) }
    }

    private var seasonColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stagioni").font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.textDim).padding(.leading, 34)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(seasons, id: \.self) { n in
                        TvRow(item: TvListItem(id: "s\(n)", title: "Stagione \(n)", selected: n == season) { focusFirstEpisode() })
                            .focused($focus, equals: "s\(n)")
                    }
                }
                .padding(.vertical, 12).padding(.horizontal, 12)
            }
        }
        .frame(width: 400, alignment: .leading)
        .focusSection()
    }

    private var episodeColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.details.displayTitle).font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.textDim)
            Text("Stagione \(season)").font(NxFont.display(24, .bold)).foregroundStyle(.white)
            if eps.isEmpty {
                HStack(spacing: 14) {
                    if loading { NxSpinner(size: 22) }
                    Text(loading ? "Carico gli episodi…" : "Nessun episodio disponibile").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                }
                .padding(.top, 30)
            }
            episodeList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var episodeList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(eps) { e in
                        TvEpisodeCard(episode: e, current: isCurrent(e)) { onPlay(e) }
                            .focused($focus, equals: "e\(e.id)")
                            .id("e\(e.id)")
                    }
                }
                .padding(.vertical, 24).padding(.horizontal, 26)
            }
            .onAppear {
                guard let start = startEpisode() else { return }
                proxy.scrollTo(start, anchor: .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = start }
            }
            .onChange(of: focus) { _, f in
                if let f = f, f.hasPrefix("e") { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: .center) } }
            }
        }
    }

    private func startEpisode() -> String? {
        if let c = eps.first(where: { isCurrent($0) }) { return "e\(c.id)" }
        if let f = eps.first { return "e\(f.id)" }
        return seasons.count > 1 ? "s\(season)" : nil
    }

    private func focusFirstEpisode() {
        if let s = startEpisode(), s.hasPrefix("e") { focus = s }
    }

    private func load(_ n: Int) {
        season = n
        if n == model.request.season && !model.episodes.isEmpty { eps = model.episodes; return }
        eps = []
        loading = true
        let id = model.details.id
        Task {
            let s = try? await app.core.catalog.season(id, n)
            if season == n { eps = s?.episodes ?? []; loading = false }
        }
    }

    private func key(_ k: String) {
        let f = focus ?? ""
        if f.hasPrefix("s") {
            let list = seasons
            let i = list.firstIndex(where: { "s\($0)" == f }) ?? 0
            switch k {
            case "up": if i > 0 { focus = "s\(list[i - 1])" }
            case "down": if i + 1 < list.count { focus = "s\(list[i + 1])" }
            case "right", "ok": focusFirstEpisode()
            case "back": onClose()
            default: break
            }
            return
        }
        let i = eps.firstIndex(where: { "e\($0.id)" == f }) ?? 0
        switch k {
        case "up": if i > 0 { focus = "e\(eps[i - 1].id)" }
        case "down": if i + 1 < eps.count { focus = "e\(eps[i + 1].id)" }
        case "left": if seasons.count > 1 { focus = "s\(season)" }
        case "ok": if i < eps.count { onPlay(eps[i]) }
        case "back": onClose()
        default: break
        }
    }
}

/// One episode in the "Episodi" panel.
struct TvEpisodeCard: View {
    let episode: TmdbEpisode
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focusable { f in
                HStack(alignment: .top, spacing: 30) {
                    still
                    text(f)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(f ? Color.white : (current ? Color.white.opacity(0.1) : Color.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(f ? 1.02 : 1)
                .animation(.easeOut(duration: 0.14), value: f)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.98))
    }

    private var still: some View {
        ZStack(alignment: .bottomLeading) {
            NxImage(url: Img.tmdb(episode.stillPath, "w300"), maxPixel: 600) { NxColor.ink3 }
                .frame(width: 340, height: 191)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if current {
                Image(systemName: "play.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Color.black.opacity(0.6), in: Circle())
                    .frame(width: 340, height: 191)
            }
        }
    }

    private func text(_ f: Bool) -> some View {
        let name = episode.name ?? "Episodio \(episode.episodeNumber)"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("\(episode.episodeNumber). \(name)").font(NxFont.ui(16, .heavy)).lineLimit(1)
                if let r = episode.runtime { Text("\(r) min").font(NxFont.ui(12, .semibold)).opacity(0.7) }
            }
            if current {
                Text("IN RIPRODUZIONE").font(NxFont.ui(10, .heavy)).tracking(1).foregroundStyle(f ? NxColor.accentDeep : NxColor.accentBright)
            }
            if let o = episode.overview?.nilIfBlank {
                Text(o).font(NxFont.ui(12)).lineLimit(3).opacity(0.85).multilineTextAlignment(.leading)
            }
        }
        .foregroundStyle(f ? Color.black : Color.white)
        .frame(maxWidth: 1000, alignment: .leading)
    }
}

// MARK: - remote clicks

/// When the last click on an edge and the last finger movement on the touch surface happened (a reference, so updating
/// it does not redraw the player).
final class TvInputTimes {
    var arrowAt = Date.distantPast
    var touchAt = Date.distantPast
}

/// The Siri Remote's clicks. Left / right on the clickpad edge (and the arrow keys of other remotes) arrive as press down
/// and press up, so a held click can keep seeking; while `consumeArrows` is on the press is cancelled for the focused view
/// (the move command it may already have sent is ignored by the player). Every other press is only reported (`onAny`) and goes on as usual. Swipes on the touch
/// surface are not presses: `TvTouchPan` gets those.
struct TvRemotePresses: UIViewRepresentable {
    let consumeArrows: Bool
    let onArrow: (Int) -> Void
    let onArrowUp: () -> Void
    let onAny: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        context.coordinator.parent = self
        return v
    }

    func updateUIView(_ v: HostView, context: Context) { context.coordinator.parent = self }

    static func dismantleUIView(_ v: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TvRemotePresses?
        lazy var arrows: TvArrowPressRecognizer = {
            let r = TvArrowPressRecognizer(target: nil, action: nil)
            r.owner = self
            r.allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
            r.allowedTouchTypes = []
            r.cancelsTouchesInView = false
            r.delegate = self
            return r
        }()
        lazy var watcher: TvAnyPressRecognizer = {
            let r = TvAnyPressRecognizer(target: nil, action: nil)
            r.owner = self
            r.allowedTouchTypes = []
            r.cancelsTouchesInView = false
            r.delegate = self
            return r
        }()

        func attach(to w: UIWindow) {
            detach()
            w.addGestureRecognizer(arrows)
            w.addGestureRecognizer(watcher)
        }
        func detach() {
            arrows.view?.removeGestureRecognizer(arrows)
            watcher.view?.removeGestureRecognizer(watcher)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class HostView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let c = coordinator else { return }
            if let w = window { c.attach(to: w) } else { c.detach() }
        }
    }
}

/// Left / right clicks: recognised at once (so the press never reaches the focused view) while the player wants them,
/// failed at once otherwise (so the press goes on to the focus engine without delay).
final class TvArrowPressRecognizer: UIGestureRecognizer {
    weak var owner: TvRemotePresses.Coordinator?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard state == .possible,
              let p = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }),
              let o = owner?.parent, o.consumeArrows else { state = .failed; return }
        state = .began
        o.onArrow(p.type == .leftArrow ? -1 : 1)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {}

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        if state == .began || state == .changed { state = .ended; owner?.parent?.onArrowUp() } else { state = .failed }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        if state == .began || state == .changed { state = .cancelled; owner?.parent?.onArrowUp() } else { state = .failed }
    }
}

/// Every press, only reported: it fails at once and the press goes on untouched.
final class TvAnyPressRecognizer: UIGestureRecognizer {
    weak var owner: TvRemotePresses.Coordinator?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        owner?.parent?.onAny()
        state = .failed
    }
}

// MARK: - touch surface

/// The Siri Remote's touch surface: a horizontal swipe, reported as the distance travelled (points). The recogniser sits
/// on the window, because the touches of the remote go to the focused view and its ancestors; it never cancels them,
/// so the focus engine keeps working as usual.
struct TvTouchPan: UIViewRepresentable {
    /// The distance of a swipe across the whole surface.
    static let fullSwipe: CGFloat = 1000
    let enabled: Bool
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    /// Any finger movement on the surface, even one too small to scrub (stops the credits countdown).
    var onTouch: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        context.coordinator.parent = self
        return v
    }

    func updateUIView(_ v: HostView, context: Context) { context.coordinator.parent = self }

    static func dismantleUIView(_ v: HostView, coordinator: Coordinator) {
        coordinator.pan.view?.removeGestureRecognizer(coordinator.pan)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TvTouchPan?
        private var started = false
        lazy var pan: UIPanGestureRecognizer = {
            let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            p.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            p.cancelsTouchesInView = false
            p.delaysTouchesBegan = false
            p.delaysTouchesEnded = false
            p.delegate = self
            return p
        }()

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let p = parent, let v = g.view else { return }
            let t = g.translation(in: v)
            if g.state == .began || g.state == .changed { p.onTouch?() }
            switch g.state {
            case .began:
                started = false
            case .changed:
                if !started {
                    guard p.enabled, abs(t.x) > 50, abs(t.x) > abs(t.y) * 1.5 else { return }
                    started = true
                    p.onBegin()
                }
                p.onChange(t.x)
            case .ended, .cancelled, .failed:
                if started { p.onEnd(t.x) }
                started = false
            default:
                break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class HostView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let c = coordinator else { return }
            c.pan.view?.removeGestureRecognizer(c.pan)
            window?.addGestureRecognizer(c.pan)
        }
    }
}

// MARK: - clicks and touches of the Siri Remote

/// Tells a physical click on the edge of the Siri Remote's clickpad from a swipe or a resting finger. SwiftUI reports
/// both as the same move command (`onMoveCommand`); UIKit does not: a click arrives as a press of the arrow type, a
/// swipe only as touches that the focus engine turns into focus moves. The recognisers sit on the window, because the
/// presses and touches of the remote go to the focused view and its ancestors; they never cancel anything, so the focus
/// engine and the move commands keep working as usual. The live player uses it: click up / down = zap, swipe or touch =
/// only the info bar.
///
/// `XCUIRemote.press(.up)` in the UI tests is a press, as a click is. There is no way to send a swipe or a touch from
/// a UI test: that half can only be tried on a real remote.
struct TvRemoteCatcher: UIViewRepresentable {
    let enabled: Bool
    /// A click on the top (+1) or bottom (-1) edge, at the moment it goes down.
    let onClick: (Int) -> Void
    /// A finger resting on (or moving over) the surface for a moment without a click.
    let onTouch: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        context.coordinator.parent = self
        return v
    }

    func updateUIView(_ v: HostView, context: Context) { context.coordinator.parent = self }

    static func dismantleUIView(_ v: HostView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TvRemoteCatcher?
        /// When the last click went down (a touch right before or after it is part of the click, not a touch).
        private(set) var lastClick = Date.distantPast

        private func pressRecogniser(_ type: UIPress.PressType, _ action: Selector) -> UILongPressGestureRecognizer {
            let g = UILongPressGestureRecognizer(target: self, action: action)
            g.minimumPressDuration = 0
            g.allowedPressTypes = [NSNumber(value: type.rawValue)]
            g.allowedTouchTypes = []
            g.cancelsTouchesInView = false
            g.delaysTouchesBegan = false
            g.delaysTouchesEnded = false
            g.delegate = self
            return g
        }
        lazy var up: UILongPressGestureRecognizer = self.pressRecogniser(.upArrow, #selector(Coordinator.clickUp(_:)))
        lazy var down: UILongPressGestureRecognizer = self.pressRecogniser(.downArrow, #selector(Coordinator.clickDown(_:)))
        lazy var touch: UILongPressGestureRecognizer = {
            let g = UILongPressGestureRecognizer(target: self, action: #selector(Coordinator.touched(_:)))
            g.minimumPressDuration = 0.25
            g.allowableMovement = .greatestFiniteMagnitude
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            g.allowedPressTypes = []
            g.cancelsTouchesInView = false
            g.delaysTouchesBegan = false
            g.delaysTouchesEnded = false
            g.delegate = self
            return g
        }()
        var all: [UIGestureRecognizer] { [up, down, touch] }

        func attach(_ w: UIWindow) {
            detach()
            all.forEach { w.addGestureRecognizer($0) }
        }
        func detach() { all.forEach { $0.view?.removeGestureRecognizer($0) } }

        @objc func clickUp(_ g: UILongPressGestureRecognizer) { click(g, 1) }
        @objc func clickDown(_ g: UILongPressGestureRecognizer) { click(g, -1) }
        private func click(_ g: UILongPressGestureRecognizer, _ d: Int) {
            guard g.state == .began else { return }
            lastClick = Date()
            guard let p = parent, p.enabled else { return }
            p.onClick(d)
        }

        @objc func touched(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, Date().timeIntervalSince(lastClick) > 0.6, let p = parent, p.enabled else { return }
            p.onTouch()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class HostView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let c = coordinator else { return }
            if let w = window { c.attach(w) } else { c.detach() }
        }
    }
}
#endif
