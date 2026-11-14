import SwiftUI

/// The on-demand player. Phone upright: the video on top, the title, the options and the episodes under it. Phone on
/// its side: full screen with the controls over the picture. Apple TV: drawn by `TvVodLayer` (TvPlayerChrome.swift),
/// Netflix-like: select / play-pause pause, left / right seek (faster while the clicks keep coming), down reaches the
/// options, every panel inside the player.
struct VodPlayerView: View {
    @ObservedObject var model: VodPlayerModel
    @ObservedObject var player: NxPlayer
    let full: Bool
    let width: CGFloat
    @EnvironmentObject var app: AppModel
    @StateObject private var chrome = ChromeState()
    @State private var countdown = 10
    /// Apple TV: the button of the resolving / failed / ended / still-watching screens that takes the focus.
    @FocusState private var phaseFocus: Int?
    #if os(iOS)
    @StateObject private var feedback = GestureFeedback()
    /// The drag under way: 0 undecided, 1 vertical (brightness / volume), 2 horizontal (ignored).
    @State private var dragAxis = 0
    @State private var dragLeft = true
    @State private var dragStart: Double = 0
    #endif

    init(model: VodPlayerModel, full: Bool, width: CGFloat) {
        self.model = model
        self.player = model.player
        self.full = full
        self.width = width
    }

    private var request: PlayRequest { model.request }

    var body: some View {
        VStack(spacing: 0) {
            video
                .frame(maxWidth: .infinity)
                .frame(height: full ? nil : width * 9 / 16)
                .frame(maxHeight: full ? .infinity : nil)
            #if os(iOS)
            if !full { below }
            #endif
        }
        .onAppear { chrome.show() }
        .onReceive(NotificationCenter.default.publisher(for: .nxRemoteKey)) { n in
            #if os(tvOS)
            // while the video plays TvVodLayer takes the keys; the other screens are two buttons at most
            if model.phase != .playing { phaseKey(n.object as? String ?? "") }
            #else
            switch n.object as? String {
            case "playpause", "ok": model.togglePlay(); chrome.show()
            case "left": model.seekBy(-10_000); chrome.show()
            case "right": model.seekBy(10_000); chrome.show()
            case "back": app.closePlayer()
            case "menu", "up": options()
            default: break
            }
            #endif
        }
    }

    private var video: some View {
        ZStack {
            PlayerSurface(player: model.player).ignoresSafeArea(.container, edges: full ? .all : [])
            if player.external { ElsewhereNotice(icon: "airplayvideo", text: "In riproduzione su AirPlay") }
            else if player.pipActive { ElsewhereNotice(icon: "pip", text: "In riproduzione in una finestra") }
            #if os(iOS)
            gestureLayer
            #endif
            switch model.phase {
            case .resolving(let status): resolving(status)
            case .playing: playingOverlay
            case .failed(let message): failed(message)
            case .ended: ended
            case .stillWatching: stillWatching
            }
            #if os(iOS)
            GestureBubble(feedback: feedback).animation(.easeOut(duration: 0.15), value: feedback.kind)
            #endif
        }
        .clipped()
        #if os(tvOS)
        .onChange(of: model.phase) { _, p in if p != .playing { DispatchQueue.main.async { phaseFocus = 0 } } }
        #else
        .background(VolumeHook().frame(width: 1, height: 1).opacity(0.02))
        #endif
    }

    #if os(tvOS)
    /// Phone remote on the resolving / failed / ended / still-watching screens: left / right between the two buttons,
    /// ok presses the one in focus, BACK leaves the player.
    private var twoButtons: Bool {
        switch model.phase {
        case .failed, .stillWatching: return true
        case .ended: return model.nextRequest(auto: true) != nil
        default: return false
        }
    }

    private func phaseKey(_ k: String) {
        let second = (phaseFocus ?? 0) == 1
        switch k {
        case "left": phaseFocus = 0
        case "right": if twoButtons { phaseFocus = 1 }
        case "back": app.closePlayer()
        case "ok", "playpause":
            switch model.phase {
            case .resolving: app.closePlayer()
            case .failed: if second { app.closePlayer() } else { model.start(retry: true) }
            case .ended:
                if !second, var n = model.nextRequest(auto: true) { n.auto = false; app.core.watchSession.touch(); app.play(n) } else { app.closePlayer() }
            case .stillWatching:
                if second { app.closePlayer() } else { continueWatching() }
            case .playing: break
            }
        default: break
        }
    }
    #endif

    private func continueWatching() {
        app.core.watchSession.touch()
        if let n = model.nextRequest(auto: false) { app.play(n) } else { app.closePlayer() }
    }

    #if os(iOS)
    /// Touch: tap = controls on / off; double tap on the left / right half = 10 s back / forward; full screen, a vertical
    /// drag on the left = brightness, on the right = volume. Under the controls, so their buttons come first.
    private var gestureLayer: some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { v in doubleTap(left: v.location.x < g.size.width / 2) }
                        .exclusively(before: TapGesture().onEnded { if model.phase == .playing { chrome.toggle() } })
                )
                .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { v in drag(v, g.size) }.onEnded { _ in dragAxis = 0 })
        }
    }

    private func doubleTap(left: Bool) {
        guard model.phase == .playing, model.duration > 0 else { return }
        model.seekBy(left ? -10_000 : 10_000)
        feedback.show(left ? .back : .forward)
    }

    private func drag(_ v: DragGesture.Value, _ size: CGSize) {
        guard full, model.phase == .playing, size.height > 0 else { return }
        if dragAxis == 0 {
            dragAxis = abs(v.translation.height) > abs(v.translation.width) ? 1 : 2
            dragLeft = v.startLocation.x < size.width / 2
            dragStart = dragLeft ? SystemLevels.brightness : SystemLevels.volume
        }
        guard dragAxis == 1 else { return }
        let level = max(0, min(1, dragStart - Double(v.translation.height) / Double(size.height * 0.8)))
        if dragLeft { SystemLevels.brightness = level; feedback.show(.brightness, level) }
        else { SystemLevels.volume = level; feedback.show(.volume, level) }
    }
    #endif

    // MARK: states

    @ViewBuilder private func backdrop(_ opacity: Double) -> some View {
        #if os(tvOS)
        // the TV hides the paused picture behind these screens
        Color.black.ignoresSafeArea().allowsHitTesting(false)
        #endif
        NxImage(url: Img.tmdb(model.details.bestBackdrop ?? model.details.backdropPath, "w1280"), maxPixel: 1600) { Color.black }
            .opacity(opacity).ignoresSafeArea(.container, edges: full ? .all : []).allowsHitTesting(false)
    }

    private var closeCorner: some View {
        #if os(iOS)
        VStack { HStack { PlayerKey(icon: "chevron.down", label: "Chiudi", size: 20) { app.closePlayer() }; Spacer() }; Spacer() }.padding(.horizontal, full ? 6 : 2).padding(.top, full ? 6 : 0)
        #else
        EmptyView()
        #endif
    }

    private func resolving(_ status: String) -> some View {
        ZStack {
            backdrop(0.4)
            VStack(spacing: Metrics.u(full ? 12 : 8)) {
                BrandLoader(size: full ? 60 : 40)
                if full { Text(model.details.displayTitle).font(NxFont.titleL).foregroundStyle(NxColor.text).multilineTextAlignment(.center) }
                Text(status).font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                #if os(tvOS)
                NxButton("Annulla", kind: .secondary) { app.closePlayer() }.padding(.top, 10)
                    .tvPhaseFocus($phaseFocus, 0)
                #endif
            }
            .padding(Metrics.u(16))
            closeCorner
        }
        #if os(tvOS)
        .onExitCommand { app.closePlayer() }
        .onAppear { DispatchQueue.main.async { phaseFocus = 0 } }
        #endif
    }

    private func failed(_ message: String) -> some View {
        ZStack {
            backdrop(0.25)
            VStack(spacing: Metrics.u(8)) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: (full ? 34 : 22) * Metrics.unit)).foregroundStyle(NxColor.textDim)
                Text(message).font(full ? NxFont.body : NxFont.caption).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).lineLimit(3)
                HStack(spacing: Metrics.u(10)) {
                    NxButton("Riprova", icon: "arrow.clockwise", kind: .primary) { model.start(retry: true) }
                        .tvPhaseFocus($phaseFocus, 0)
                    NxButton("Chiudi", kind: .secondary) { app.closePlayer() }
                        .tvPhaseFocus($phaseFocus, 1)
                }
                .padding(.top, 4)
                #if os(tvOS)
                .focusSection()
                #endif
            }
            .padding(Metrics.u(14)).frame(maxWidth: Metrics.u(460))
        }
        #if os(tvOS)
        .onExitCommand { app.closePlayer() }
        .onAppear { DispatchQueue.main.async { phaseFocus = 0 } }
        #endif
    }

    @ViewBuilder private var playingOverlay: some View {
        #if os(tvOS)
        TvVodLayer(model: model, player: player, chrome: chrome)
        #else
        if player.state == .opening || player.state == .buffering { BrandLoader(size: full ? 56 : 40) }
        if chrome.visible || model.paused || model.seekTarget != nil { controlsView.transition(.opacity) }
        if model.creditsVisible, let n = model.nextRequest(auto: false) {
            VStack {
                Spacer()
                HStack(spacing: Metrics.u(8)) {
                    Spacer()
                    NxButton("Titoli di coda", kind: .secondary) { model.creditsDismissed = true }
                    NxButton("Prossimo episodio", icon: "forward.end.fill", kind: .primary) { app.play(n) }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(Metrics.tv ? 110 : (full ? 96 : 44)))
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var controlsView: some View {
        ZStack {
            PlayerScrim()
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    PlayerKey(icon: "chevron.down", label: "Chiudi", size: 20) { app.closePlayer() }
                    if full {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.details.displayTitle).font(NxFont.ui(15, .bold)).foregroundStyle(.white).lineLimit(1)
                            if !model.subtitle.isEmpty { Text(model.subtitle).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1) }
                        }
                    }
                    Spacer(minLength: 0)
                    if app.castBody() != nil { PlayerKey(icon: "tv", label: "Riproduci su…", size: 19) { app.presentCast() } }
                    if player.engine == .system { AirPlayButton().frame(width: 42, height: 42) }
                    if player.pipPossible { PlayerKey(icon: "pip.enter", label: "Finestra", size: 19) { player.togglePip() } }
                }
                .padding(.horizontal, full ? 6 : 2).padding(.top, full ? 6 : 0)
                Spacer(minLength: 0)
                HStack(spacing: full ? 64 : 40) {
                    PlayerKey(icon: "gobackward.10", label: "Indietro 10 secondi", size: full ? 32 : 26) { model.seekBy(-10_000); model.applySeek(); chrome.show() }
                    PlayerKey(icon: model.paused ? "play.fill" : "pause.fill", label: "Pausa", size: full ? 46 : 36) { model.togglePlay(); chrome.show() }
                    PlayerKey(icon: "goforward.10", label: "Avanti 10 secondi", size: full ? 32 : 26) { model.seekBy(10_000); model.applySeek(); chrome.show() }
                }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(playerClock(model.position)).font(NxFont.ui(12, .bold)).foregroundStyle(.white).monospacedDigit()
                        Scrubber(position: model.position, duration: model.duration, onScrub: { model.scrub(to: $0); chrome.show(auto: false) }, onEnd: { model.applySeek(); chrome.show() })
                        Text(model.duration > 0 ? "-" + playerClock(model.duration - model.position) : "--:--").font(NxFont.ui(12, .bold)).foregroundStyle(.white).monospacedDigit()
                        if !Metrics.isPad {
                            PlayerKey(icon: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: "Schermo intero", size: 18) {
                                PlatformServices.shared.rotate(landscape: !full)
                            }
                        }
                    }
                    if full {
                        HStack(spacing: 14) {
                            PlayerOption(icon: "speedometer", title: model.speed == 1 ? "Velocità" : Settings.speedLabel(model.speed)) { speed() }
                            if model.details.isTv && model.canBrowse { PlayerOption(icon: "rectangle.stack", title: "Episodi") { episodes() } }
                            PlayerOption(icon: "captions.bubble", title: "Audio e sottotitoli") { tracks() }
                            PlayerOption(icon: player.fill ? "arrow.down.right.and.arrow.up.left.rectangle" : "arrow.up.left.and.arrow.down.right.rectangle", title: player.fill ? "Adatta" : "Riempi") { player.fill.toggle() }
                            Spacer(minLength: 0)
                            if let n = model.nextRequest(auto: false) { PlayerOption(icon: "forward.end.fill", title: "Prossimo episodio") { app.play(n) } }
                        }
                    }
                }
                .padding(.leading, full ? 16 : 10).padding(.trailing, full ? 10 : 2).padding(.bottom, full ? 4 : 0)
            }
        }
    }
    #endif

    private var ended: some View {
        let next = model.nextRequest(auto: true)
        let autoplay = next != nil && app.core.settings.autoplay(app.pid)
        return ZStack {
            backdrop(0.3)
            VStack(spacing: Metrics.u(full ? 12 : 6)) {
                if let n = next {
                    #if os(tvOS)
                    nextStill(n)
                    #endif
                    Text("Prossimo episodio").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    Text("S\(n.season) E\(n.episode)" + (n.episodeTitle.map { " · \($0)" } ?? "")).font(full ? NxFont.titleL : NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center).lineLimit(2)
                    if autoplay { Text("Parte tra \(countdown) secondi").font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                    HStack(spacing: Metrics.u(10)) {
                        NxButton("Guarda ora", icon: "play.fill", kind: .primary) { var x = n; x.auto = false; app.core.watchSession.touch(); app.play(x) }
                            .tvPhaseFocus($phaseFocus, 0)
                        NxButton("Chiudi", kind: .secondary) { app.closePlayer() }
                            .tvPhaseFocus($phaseFocus, 1)
                    }
                } else {
                    Text(model.details.displayTitle).font(NxFont.titleL).foregroundStyle(NxColor.text).lineLimit(2)
                    Text("Fine").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                    NxButton("Chiudi", kind: .primary) { app.closePlayer() }
                        .tvPhaseFocus($phaseFocus, 0)
                }
            }
            .padding(Metrics.u(14))
            #if os(tvOS)
            .focusSection()
            #endif
        }
        #if os(tvOS)
        .onExitCommand { app.closePlayer() }
        .onAppear { DispatchQueue.main.async { phaseFocus = 0 } }
        #endif
        .task {
            guard autoplay, let n = next else { return }
            countdown = 10
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
            app.core.watchSession.autoplayed += 1
            app.play(n)
        }
    }

    #if os(tvOS)
    /// The next episode's picture on the end screen, with the seconds left before it starts.
    @ViewBuilder private func nextStill(_ n: PlayRequest) -> some View {
        let ep = model.episodes.first(where: { $0.seasonNumber == n.season && $0.episodeNumber == n.episode })
        let autoplay = app.core.settings.autoplay(app.pid)
        ZStack {
            NxImage(url: Img.tmdb(ep?.stillPath ?? model.details.bestBackdrop ?? model.details.backdropPath, "w780"), maxPixel: 900) { NxColor.ink3 }
                .frame(width: 560, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if autoplay {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 6)
                    Circle().trim(from: 0, to: CGFloat(countdown) / 10).stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(countdown)").font(NxFont.display(22, .bold)).foregroundStyle(.white).monospacedDigit()
                }
                .frame(width: 110, height: 110)
                .background(Color.black.opacity(0.55), in: Circle())
                .animation(.linear(duration: 1), value: countdown)
            }
        }
        .padding(.bottom, 10)
    }
    #endif

    /// "Stai ancora guardando?": playback stays stopped until the viewer answers.
    private var stillWatching: some View {
        ZStack {
            backdrop(0.25)
            VStack(spacing: Metrics.u(full ? 12 : 8)) {
                Text("Stai ancora guardando?").font(full ? NxFont.titleXL : NxFont.titleM).foregroundStyle(NxColor.text)
                HStack(spacing: Metrics.u(10)) {
                    NxButton("Continua", icon: "play.fill", kind: .primary) { continueWatching() }
                    .tvPhaseFocus($phaseFocus, 0)
                    NxButton("Esci", kind: .secondary) { app.closePlayer() }
                        .tvPhaseFocus($phaseFocus, 1)
                }
            }
            .padding(Metrics.u(14))
            #if os(tvOS)
            .focusSection()
            #endif
        }
        #if os(tvOS)
        .onExitCommand { app.closePlayer() }
        .onAppear { DispatchQueue.main.async { phaseFocus = 0 } }
        #endif
    }

    // MARK: panels

    private func speed() {
        app.choose("Velocità", Settings.speedOptions.map { ($0, Settings.speedLabel($0)) }, current: model.speed) { model.setSpeed($0) }
    }

    /// "Audio e sottotitoli": the audio track chosen becomes the profile's language.
    private func tracks() {
        let pid = app.pid
        app.presentTracks(model.player) { name in app.core.settings.setAudioLang(pid, audioLangOf(name)) }
    }

    private func episodes() {
        let m = model
        app.present("Stagione \(request.season)") {
            LazyVStack(spacing: 0) {
                ForEach(m.episodes) { e in
                    OptionRow(title: "\(e.episodeNumber). \(e.name ?? "Episodio \(e.episodeNumber)")", sub: e.runtime.map { "\($0) min" }, selected: e.episodeNumber == m.request.episode) {
                        app.dismissSheet()
                        if e.episodeNumber != m.request.episode { app.play(PlayRequest(details: m.details, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name)) }
                    }
                }
            }
        }
    }

    private func source() {
        guard let s = model.stream, s.channel != "offline" else { return }
        if s.alternates.count > 1 {
            var a = [NxAction]()
            for (i, alt) in s.alternates.enumerated() {
                let label = (alt.label ?? "").isBlank ? "Versione \(i + 1)" : (alt.label ?? "")
                a.append(NxAction(label, selected: alt.url == s.url, badge: VodPlayerView.qualityOf(label)) { model.useAlternate(alt) })
            }
            a.append(NxAction("Cerca un'altra fonte", sub: "Adesso: \(s.channel) · \(s.server)", icon: "arrow.triangle.2.circlepath") { model.otherSource() })
            app.menu("Fonte", a)
        } else {
            app.confirm("Cercare un'altra fonte?", message: "Adesso: \(s.channel) · \(s.server). La riproduzione riparte da dove sei.", confirm: "Cerca un'altra fonte") { model.otherSource() }
        }
    }

    /// "1080p" in a version's name → FHD; 2160 → 4K, 720 → HD, 480 → SD.
    static func qualityOf(_ label: String) -> String? {
        guard let m = VodPlayerView.qualityRx.find(label) else { return nil }
        switch m[1] { case "2160": return "4K"; case "1080": return "FHD"; case "720": return "HD"; default: return "SD" }
    }
    private static let qualityRx = Rx(#"\b(2160|1080|720|480)p?\b"#)

    private func options() {
        var a = [NxAction]()
        a.append(NxAction("Audio e sottotitoli", icon: "captions.bubble") { tracks() })
        a.append(NxAction("Velocità", sub: Settings.speedLabel(model.speed), icon: "speedometer") { speed() })
        if model.details.isTv && model.canBrowse { a.append(NxAction("Episodi", icon: "rectangle.stack") { episodes() }) }
        if let n = model.nextRequest(auto: false) { a.append(NxAction("Prossimo episodio", icon: "forward.end.fill") { app.play(n) }) }
        if let s = model.stream, s.channel != "offline" { a.append(NxAction("Cambia fonte", sub: "\(s.channel) · \(s.server)", icon: "arrow.triangle.2.circlepath") { source() }) }
        a.append(NxAction("Esci dal video", icon: "xmark") { app.closePlayer() })
        app.menu(model.details.displayTitle, a)
    }

    // MARK: portrait page

    #if os(iOS)
    private func plot(_ d: TmdbDetails) -> String? {
        if !d.isTv { return d.overview?.nilIfBlank }
        let ep: TmdbEpisode? = model.episodes.first(where: { $0.episodeNumber == request.episode })
        return ep?.overview?.nilIfBlank
    }

    private var below: some View {
        let d = model.details
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.displayTitle).font(NxFont.display(20, .bold)).foregroundStyle(.white).lineLimit(2)
                    if !model.subtitle.isEmpty { Text(model.subtitle).font(NxFont.ui(14, .bold)).foregroundStyle(NxColor.textMuted).lineLimit(2) }
                    HStack(alignment: .top, spacing: 4) {
                        if !model.isOffline { NxIconAction(icon: "tv", label: "Sulla TV") { app.presentCast() } }
                        NxIconAction(icon: "captions.bubble", label: "Audio") { tracks() }
                        NxIconAction(icon: "speedometer", label: model.speed == 1 ? "Velocità" : Settings.speedLabel(model.speed)) { speed() }
                        if let s = model.stream, s.channel != "offline" { NxIconAction(icon: "arrow.triangle.2.circlepath", label: "Fonte") { source() } }
                        if model.nextReq != nil { NxIconAction(icon: "forward.end.fill", label: "Prossimo") { if let n = model.nextRequest(auto: false) { app.play(n) } } }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, -10)
                    if let o = plot(d) {
                        Text(o).font(NxFont.ui(13)).foregroundStyle(NxColor.textMuted).lineLimit(5)
                    }
                }
                .padding(.horizontal, Metrics.gutter).padding(.top, 12)
                if d.isTv && model.canBrowse && !model.episodes.isEmpty {
                    Text("Stagione \(request.season)").font(NxFont.rowTitle).foregroundStyle(.white).padding(.horizontal, Metrics.gutter).padding(.top, 6)
                    ForEach(model.episodes) { e in
                        let current = e.episodeNumber == request.episode
                        CardButton(action: {
                            if !current { app.play(PlayRequest(details: d, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name)) }
                        }, radius: 0) {
                            HStack(spacing: 12) {
                                NxImage(url: Img.tmdb(e.stillPath, "w300"), maxPixel: 500) { NxColor.ink3 }
                                    .frame(width: 124, height: 70).clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).stroke(Color.white, lineWidth: current ? 2 : 0))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(e.episodeNumber). \(e.name ?? "Episodio \(e.episodeNumber)")").font(NxFont.ui(14, .bold)).foregroundStyle(current ? NxColor.accentBright : .white).lineLimit(2).multilineTextAlignment(.leading)
                                    if let r = e.runtime { Text("\(r) min").font(NxFont.caption).foregroundStyle(NxColor.textDim) }
                                }
                                Spacer(minLength: 0)
                                if current { Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundStyle(NxColor.accentBright) }
                            }
                            .padding(.horizontal, Metrics.gutter).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
        }
        .background(NxColor.bg)
    }
    #endif
}
