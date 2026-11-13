import SwiftUI

/// The on-demand player. Phone upright: the video on top, the title, the options and the episodes under it. Phone on
/// its side: full screen with the controls over the picture. Apple TV: left / right move by 10 s, select or play/pause
/// pauses, up opens the options.
struct VodPlayerView: View {
    @ObservedObject var model: VodPlayerModel
    @ObservedObject var player: NxPlayer
    let full: Bool
    let width: CGFloat
    @EnvironmentObject var app: AppModel
    @StateObject private var chrome = ChromeState()
    @State private var countdown = 10
    @FocusState private var focused: Bool

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
            switch n.object as? String {
            case "playpause", "ok": model.togglePlay(); chrome.show()
            case "left": model.seekBy(-10_000); chrome.show()
            case "right": model.seekBy(10_000); chrome.show()
            case "back": app.closePlayer()
            case "menu", "up": options()
            default: break
            }
        }
    }

    private var video: some View {
        ZStack {
            PlayerSurface(player: model.player).ignoresSafeArea(.container, edges: full ? .all : [])
            if player.external { ElsewhereNotice(icon: "airplayvideo", text: "In riproduzione su AirPlay") }
            else if player.pipActive { ElsewhereNotice(icon: "pip", text: "In riproduzione in una finestra") }
            switch model.phase {
            case .resolving(let status): resolving(status)
            case .playing: playingOverlay
            case .failed(let message): failed(message)
            case .ended: ended
            case .stillWatching: stillWatching
            }
        }
        .clipped()
        #if os(tvOS)
        .focusable(model.phase == .playing && app.sheets.isEmpty)
        .focused($focused)
        .onMoveCommand { dir in
            switch dir {
            case .left: model.seekBy(-10_000); chrome.show()
            case .right: model.seekBy(10_000); chrome.show()
            case .up: options()
            case .down: chrome.show()
            default: break
            }
        }
        .onPlayPauseCommand { model.togglePlay(); chrome.show() }
        .onTapGesture { if model.seekTarget != nil { model.applySeek() } else { model.togglePlay() }; chrome.show() }
        .onExitCommand { if chrome.visible && model.phase == .playing && !model.paused { chrome.hide() } else { app.closePlayer() } }
        .onAppear { focused = true }
        .onChange(of: app.sheets.isEmpty) { _, empty in if empty { focused = true } }
        .onChange(of: model.phase) { _, p in if p == .playing { focused = true } }
        #else
        .contentShape(Rectangle())
        .onTapGesture { if model.phase == .playing { chrome.toggle() } }
        #endif
    }

    // MARK: states

    private func backdrop(_ opacity: Double) -> some View {
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
                #endif
            }
            .padding(Metrics.u(16))
            closeCorner
        }
    }

    private func failed(_ message: String) -> some View {
        ZStack {
            backdrop(0.25)
            VStack(spacing: Metrics.u(8)) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: (full ? 34 : 22) * Metrics.unit)).foregroundStyle(NxColor.textDim)
                Text(message).font(full ? NxFont.body : NxFont.caption).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).lineLimit(3)
                HStack(spacing: Metrics.u(10)) {
                    NxButton("Riprova", icon: "arrow.clockwise", kind: .primary) { model.start(retry: true) }
                    NxButton("Chiudi", kind: .secondary) { app.closePlayer() }
                }
                .padding(.top, 4)
                #if os(tvOS)
                .focusSection()
                #endif
            }
            .padding(Metrics.u(14)).frame(maxWidth: Metrics.u(460))
        }
    }

    @ViewBuilder private var playingOverlay: some View {
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
    }

    @ViewBuilder private var controlsView: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.details.displayTitle).font(NxFont.display(24, .bold)).foregroundStyle(.white).lineLimit(1)
                if !model.subtitle.isEmpty { Text(model.subtitle).font(NxFont.meta).foregroundStyle(NxColor.textMuted).lineLimit(1) }
            }
            .padding(.horizontal, 80).padding(.top, 70)
            Spacer()
            if model.paused && model.seekTarget == nil {
                Image(systemName: "pause.fill").font(.system(size: 90, weight: .bold)).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: .infinity)
                Spacer()
            }
            VStack(spacing: 14) {
                GeometryReader { g in
                    let f = model.duration > 0 ? CGFloat(max(0, min(1, Double(model.position) / Double(model.duration)))) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(height: 8)
                        Capsule().fill(NxColor.accent).frame(width: g.size.width * f, height: 8)
                        Circle().fill(NxColor.accent).frame(width: 26, height: 26).offset(x: g.size.width * f - 13)
                    }
                    .frame(height: 26)
                }
                .frame(height: 26)
                HStack {
                    Text(playerClock(model.position)).font(NxFont.ui(13, .heavy)).foregroundStyle(.white).monospacedDigit()
                    Spacer()
                    Text("◀ ▶ 10 secondi     ▲ audio, sottotitoli, episodi").font(NxFont.ui(11, .semibold)).foregroundStyle(NxColor.textDim)
                    Spacer()
                    Text(model.duration > 0 ? "-" + playerClock(model.duration - model.position) : "").font(NxFont.ui(13, .heavy)).foregroundStyle(NxColor.textMuted).monospacedDigit()
                }
            }
            .padding(.horizontal, 80).padding(.bottom, 60)
        }
        .background(LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        .ignoresSafeArea()
        #else
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
                            PlayerOption(icon: "speedometer", title: model.speed == 1 ? "Velocità" : String(format: "%.2g×", model.speed)) { speed() }
                            if model.details.isTv && !model.isOffline { PlayerOption(icon: "rectangle.stack", title: "Episodi") { episodes() } }
                            PlayerOption(icon: "captions.bubble", title: "Audio e sottotitoli") { app.presentTracks(model.player) }
                            PlayerOption(icon: player.fill ? "arrow.down.right.and.arrow.up.left.rectangle" : "arrow.up.left.and.arrow.down.right.rectangle", title: player.fill ? "Adatta" : "Riempi") { player.fill.toggle() }
                            Spacer(minLength: 0)
                            if let n = model.nextRequest(auto: false) { PlayerOption(icon: "forward.end.fill", title: "Prossimo episodio") { app.play(n) } }
                        }
                    }
                }
                .padding(.leading, full ? 16 : 10).padding(.trailing, full ? 10 : 2).padding(.bottom, full ? 4 : 0)
            }
        }
        #endif
    }

    private var ended: some View {
        let next = model.nextRequest(auto: true)
        let autoplay = next != nil && app.core.settings.autoplay(app.pid)
        return ZStack {
            backdrop(0.3)
            VStack(spacing: Metrics.u(full ? 12 : 6)) {
                if let n = next {
                    Text("Prossimo episodio").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                    Text("S\(n.season) E\(n.episode)" + (n.episodeTitle.map { " · \($0)" } ?? "")).font(full ? NxFont.titleL : NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center).lineLimit(2)
                    if autoplay { Text("Parte tra \(countdown) secondi").font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                    HStack(spacing: Metrics.u(10)) {
                        NxButton("Guarda ora", icon: "play.fill", kind: .primary) { var x = n; x.auto = false; app.core.watchSession.touch(); app.play(x) }
                        NxButton("Chiudi", kind: .secondary) { app.closePlayer() }
                    }
                } else {
                    Text(model.details.displayTitle).font(NxFont.titleL).foregroundStyle(NxColor.text).lineLimit(2)
                    Text("Fine").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                    NxButton("Chiudi", kind: .primary) { app.closePlayer() }
                }
            }
            .padding(Metrics.u(14))
            #if os(tvOS)
            .focusSection()
            #endif
        }
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

    /// "Stai ancora guardando?": playback stays stopped until the viewer answers.
    private var stillWatching: some View {
        ZStack {
            backdrop(0.25)
            VStack(spacing: Metrics.u(full ? 12 : 8)) {
                Text("Stai ancora guardando?").font(full ? NxFont.titleXL : NxFont.titleM).foregroundStyle(NxColor.text)
                HStack(spacing: Metrics.u(10)) {
                    NxButton("Continua", icon: "play.fill", kind: .primary) {
                        app.core.watchSession.touch()
                        if let n = model.nextRequest(auto: false) { app.play(n) } else { app.closePlayer() }
                    }
                    NxButton("Esci", kind: .secondary) { app.closePlayer() }
                }
            }
            .padding(Metrics.u(14))
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    // MARK: panels

    private func speed() {
        app.choose("Velocità", Settings.speedOptions.map { ($0, $0 == 1 ? "Normale" : String(format: "%.2g×", $0)) }, current: model.speed) { model.setSpeed($0) }
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
        app.confirm("Cercare un'altra fonte?", message: "Adesso: \(s.channel) · \(s.server). La riproduzione riparte da dove sei.", confirm: "Cerca un'altra fonte") { model.start(retry: true) }
    }

    private func options() {
        var a = [NxAction]()
        a.append(NxAction("Audio e sottotitoli", icon: "captions.bubble") { app.presentTracks(model.player) })
        a.append(NxAction("Velocità", sub: model.speed == 1 ? "Normale" : String(format: "%.2g×", model.speed), icon: "speedometer") { speed() })
        if model.details.isTv && !model.isOffline { a.append(NxAction("Episodi", icon: "rectangle.stack") { episodes() }) }
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
                        NxIconAction(icon: "captions.bubble", label: "Audio") { app.presentTracks(model.player) }
                        NxIconAction(icon: "speedometer", label: model.speed == 1 ? "Velocità" : String(format: "%.2g×", model.speed)) { speed() }
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
                if d.isTv && !model.isOffline && !model.episodes.isEmpty {
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
