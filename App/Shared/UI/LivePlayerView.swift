import SwiftUI

/// The live player. Phone upright: the channel on top, what it is showing and the other channels under it. Phone on its
/// side: full screen, a swipe up or down changes channel. Apple TV: up / down change channel, select shows the info,
/// left opens the channel list, right the options.
struct LivePlayerView: View {
    @ObservedObject var model: LivePlayerModel
    @ObservedObject var player: NxPlayer
    let full: Bool
    let width: CGFloat
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var chrome = ChromeState()
    @State private var genre = "all"
    @FocusState private var focused: Bool

    init(model: LivePlayerModel, full: Bool, width: CGFloat) {
        self.model = model
        self.player = model.player
        self.full = full
        self.width = width
    }

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
        .onChange(of: model.currentId) { _, _ in chrome.show() }
        .onReceive(NotificationCenter.default.publisher(for: .nxRemoteKey)) { n in
            switch n.object as? String {
            case "playpause": model.togglePause()
            case "chup", "up": model.zap(1)
            case "chdown", "down": model.zap(-1)
            case "ok": chrome.show()
            case "back": app.closePlayer()
            case "menu", "right": options()
            case "left": channelList()
            default: break
            }
        }
    }

    private var video: some View {
        ZStack {
            PlayerSurface(player: model.player).ignoresSafeArea(.container, edges: full ? .all : [])
            if player.external { ElsewhereNotice(icon: "airplayvideo", text: "In riproduzione su AirPlay") }
            else if player.pipActive { ElsewhereNotice(icon: "pip", text: "In riproduzione in una finestra") }
            if model.buffering && model.error == nil { BrandLoader(size: full ? 60 : 44) }
            if let n = model.note, model.error == nil {
                VStack {
                    Text(n).font(NxFont.meta).foregroundStyle(.white).padding(.horizontal, Metrics.u(12)).padding(.vertical, Metrics.u(7))
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Metrics.u(4)))
                    Spacer()
                }
                .padding(.top, Metrics.u(full ? 60 : 44))
            }
            if let e = model.error { errorPanel(e) }
            else if chrome.visible { controls.transition(.opacity) }
        }
        .clipped()
        #if os(tvOS)
        .focusable(app.sheets.isEmpty && model.error == nil)
        .focused($focused)
        .onMoveCommand { dir in
            switch dir {
            case .up: model.zap(1)
            case .down: model.zap(-1)
            case .left: channelList()
            case .right: options()
            default: break
            }
        }
        .onPlayPauseCommand { model.togglePause(); chrome.show() }
        .onTapGesture { chrome.toggle() }
        .onExitCommand { if chrome.visible && model.error == nil { chrome.hide() } else { app.closePlayer() } }
        .onAppear { focused = true }
        .onChange(of: app.sheets.isEmpty) { _, empty in if empty { focused = true } }
        #else
        .contentShape(Rectangle())
        .onTapGesture { chrome.toggle() }
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { g in
            guard full else { return }
            if abs(g.translation.height) > abs(g.translation.width) * 1.4 && abs(g.translation.height) > 70 { model.zap(g.translation.height < 0 ? 1 : -1) }
        })
        #endif
    }

    private var title: String {
        guard let c = model.channel else { return "" }
        return (model.now != nil || c.event != nil) ? (model.showing?.cardTitle ?? c.name) : c.name
    }

    // MARK: controls

    @ViewBuilder private var controls: some View {
        #if os(tvOS)
        VStack(spacing: 0) {
            Spacer()
            infoBar
                .padding(.horizontal, 80).padding(.bottom, 60).padding(.top, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        #else
        ZStack {
            PlayerScrim()
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    PlayerKey(icon: "chevron.down", label: "Chiudi", size: 20) { app.closePlayer() }
                    if full, let c = model.channel {
                        ChannelLogo(channel: c, height: 20)
                        Text(title).font(NxFont.ui(15, .bold)).foregroundStyle(.white).lineLimit(1).padding(.leading, 8)
                    }
                    Spacer(minLength: 0)
                    if player.engine == .system { AirPlayButton().frame(width: 42, height: 42) }
                    if player.pipPossible { PlayerKey(icon: "pip.enter", label: "Finestra", size: 19) { player.togglePip() } }
                }
                .padding(.horizontal, full ? 6 : 2).padding(.top, full ? 6 : 0)
                Spacer(minLength: 0)
                HStack(spacing: full ? 60 : 38) {
                    PlayerKey(icon: "backward.end.fill", label: "Canale precedente", size: full ? 26 : 22) { model.zap(-1) }
                    PlayerKey(icon: model.paused ? "play.fill" : "pause.fill", label: "Pausa", size: full ? 44 : 36) { model.togglePause(); chrome.show() }
                    PlayerKey(icon: "forward.end.fill", label: "Canale successivo", size: full ? 26 : 22) { model.zap(1) }
                }
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 8) {
                        if full { infoBar } else {
                            NxTag(text: "Diretta", color: NxColor.accent)
                            QualityBadge(quality: model.playing.1)
                        }
                        Spacer(minLength: 0)
                        if !full || !Metrics.isPad {
                            PlayerKey(icon: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: "Schermo intero", size: 18) {
                                PlatformServices.shared.rotate(landscape: !full)
                            }
                        }
                    }
                    if full {
                        HStack(spacing: 18) {
                            PlayerOption(icon: "list.bullet", title: "Canali") { channelList() }
                            PlayerOption(icon: "captions.bubble", title: "Audio e sottotitoli") { app.presentTracks(model.player) }
                            if model.variants().count > 1 { PlayerOption(icon: "sparkles.tv", title: "Qualità") { quality() } }
                            PlayerOption(icon: "info.circle", title: "Programma") { details() }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, full ? 14 : 8).padding(.bottom, full ? 6 : 2)
            }
        }
        #endif
    }

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: Metrics.u(4)) {
            if let c = model.channel {
                HStack(spacing: Metrics.u(8)) {
                    #if os(tvOS)
                    ChannelLogo(channel: c, height: 26)
                    #endif
                    if c.num > 0 { Text("\(c.num)").font(NxFont.ui(13, .heavy)).foregroundStyle(NxColor.textMuted) }
                    Text(c.name).font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.textMuted)
                    QualityBadge(quality: model.playing.1)
                    if let s = model.showing, s.isLiveBroadcast { NxTag(text: "Diretta", color: NxColor.accent) }
                }
                #if os(tvOS)
                Text(title).font(NxFont.display(24, .bold)).foregroundStyle(.white).lineLimit(1)
                #endif
                if let s = model.showing, let line = [s.timeLabel(), s.cardLine].compactMap({ $0 }).joined(separator: " · ").nilIfBlank {
                    Text(line).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1)
                }
                if let p = model.showing?.progress() { NxProgressBar(value: p).frame(maxWidth: Metrics.u(Metrics.tv ? 420 : 260)) }
                if let n = model.next { Text("Dopo: \(TimeText.time(n.start)) \(n.title)").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1) }
                #if os(tvOS)
                Text("▲▼ canale     ◀ lista canali     ▶ opzioni").font(NxFont.ui(11, .semibold)).foregroundStyle(NxColor.textDim).padding(.top, 10)
                #endif
            }
        }
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: Metrics.u(8)) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: (full ? 34 : 24) * Metrics.unit)).foregroundStyle(NxColor.textDim)
            Text(message).font(full ? NxFont.body : NxFont.caption).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).lineLimit(3)
            HStack(spacing: 8) { NxSpinner(size: 13); Text("Continuo a riprovare…").font(NxFont.caption).foregroundStyle(NxColor.textDim) }
            HStack(spacing: Metrics.u(10)) {
                NxButton("Canale successivo", icon: "forward.end.fill", kind: .primary) { model.zap(1) }
                NxButton("Chiudi", kind: .secondary) { app.closePlayer() }
            }
            .padding(.top, 4)
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(Metrics.u(14))
        .frame(maxWidth: Metrics.u(460))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72))
    }

    // MARK: panels

    private func quality() {
        let vs = model.variants()
        app.menu("Qualità", vs.map { v in
            NxAction(v.1 == "UHD" ? "4K" : (v.1.isEmpty ? "Predefinita" : v.1), selected: v.0 == model.playing.0) { model.tune(model.currentId, variant: v) }
        })
    }

    private func details() {
        guard let c = model.channel else { return }
        let prog = model.now?.id ?? 0
        app.closePlayer()
        app.open(.programme(c.streamId, prog))
    }

    private func options() {
        guard let c = model.channel else { return }
        let fav = store.favorites.contains(c.streamId)
        var a = [NxAction]()
        if model.variants().count > 1 { a.append(NxAction("Qualità", sub: model.playing.1 == "UHD" ? "4K" : model.playing.1, icon: "sparkles.tv") { quality() }) }
        a.append(NxAction("Audio e sottotitoli", icon: "captions.bubble") { app.presentTracks(model.player) })
        a.append(NxAction("Lista dei canali", icon: "list.bullet") { channelList() })
        a.append(NxAction(fav ? "Togli dai preferiti" : "Aggiungi ai preferiti", icon: fav ? "star.slash" : "star") { app.toggleFavorite(c) })
        a.append(NxAction("Dettagli del programma", icon: "info.circle") { details() })
        a.append(NxAction("Esci dal canale", icon: "xmark") { app.closePlayer() })
        app.menu(c.name, a)
    }

    private func channelList() {
        let m = model
        app.present("Canali") {
            LazyVStack(spacing: 0) {
                ForEach(m.zapChannels) { c in
                    let s = store.showing(c)
                    OptionRow(title: (c.num > 0 ? "\(c.num)  " : "") + c.name, sub: s.programme != nil || c.event != nil ? s.cardTitle : nil, selected: c.streamId == m.currentId) {
                        app.dismissSheet()
                        m.tune(c.streamId)
                    }
                }
            }
        }
    }

    // MARK: portrait page

    #if os(iOS)
    private var below: some View {
        let c = model.channel
        let list = store.channels(in: genre).filter { $0.shiftMin == 0 }
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let c = c {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ChannelLogo(channel: c, height: 22)
                                if c.num > 0 { Text("\(c.num)").font(NxFont.ui(12, .heavy)).foregroundStyle(NxColor.textDim) }
                                Text(c.name).font(NxFont.ui(12, .bold)).foregroundStyle(NxColor.textMuted)
                                Spacer(minLength: 0)
                            }
                            Text(title).font(NxFont.display(20, .bold)).foregroundStyle(.white).lineLimit(2)
                            if let s = model.showing, let line = [s.timeLabel(), s.cardLine].compactMap({ $0 }).joined(separator: " · ").nilIfBlank {
                                Text(line).font(NxFont.meta).foregroundStyle(NxColor.textMuted).lineLimit(1)
                            }
                            if let p = model.showing?.progress() { NxProgressBar(value: p) }
                            if let n = model.next { Text("Dopo: \(TimeText.time(n.start)) \(n.title)").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1) }
                            if let o = model.showing?.overview { Text(o).font(NxFont.ui(13)).foregroundStyle(NxColor.textMuted).lineLimit(3) }
                            let fav = store.favorites.contains(c.streamId)
                            HStack(alignment: .top, spacing: 4) {
                                NxIconAction(icon: fav ? "star.fill" : "star", label: "Preferito", active: fav) { app.toggleFavorite(c) }
                                NxIconAction(icon: "info.circle", label: "Programma") { details() }
                                NxIconAction(icon: "captions.bubble", label: "Audio") { app.presentTracks(model.player) }
                                if model.variants().count > 1 { NxIconAction(icon: "sparkles.tv", label: "Qualità") { quality() } }
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, -10)
                        }
                        .padding(.horizontal, Metrics.gutter).padding(.top, 12).padding(.bottom, 6)
                    }
                    HStack {
                        Text("Canali").font(NxFont.rowTitle).foregroundStyle(.white)
                        Spacer()
                        GenrePill(selected: $genre)
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 8)
                    ForEach(list) { ch in
                        ChannelLine(showing: store.showing(ch), favorite: store.favorites.contains(ch.streamId), current: ch.streamId == model.currentId) {
                            if ch.streamId != model.currentId { app.play(ch, ids: list.map { $0.streamId }) }
                        }
                        .id(ch.streamId)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .background(NxColor.bg)
        }
    }
    #endif
}
