import SwiftUI

/// Live playback: tuning, zapping, and never giving up on a channel that stalls (the Android player's logic).
@MainActor
final class LivePlayerModel: ObservableObject {
    let player = NxPlayer()
    private let core = NexCore.shared
    @Published var channel: ChannelEntity? = nil
    @Published var now: ProgrammeEntity? = nil
    @Published var next: ProgrammeEntity? = nil
    @Published var nowMeta: ProgrammeMetaEntity? = nil
    /// Variant stream id + quality actually playing.
    @Published var playing: (String, String) = ("", "")
    @Published var buffering = true
    @Published var error: String? = nil
    /// "Qualità FHD non risponde, provo HD…"
    @Published var note: String? = nil
    @Published var info = true
    @Published var paused = false

    private var current: String
    private let listIds: [String]
    private var zapIds: [String] = []
    private var tuneTask: Task<Void, Never>? = nil
    private var tuning = false
    private var watchStart = Clock.now
    private var recovering = 0
    private var lastFailure: String? = nil
    private var lastInteraction = Clock.now
    // watchdog
    private var lastPos: Millis = -1
    private var lastProgressAt = Clock.now
    private var healthy = 0
    private var started = false
    private var ticker: Task<Void, Never>? = nil
    private var tick = 0

    init(channelId: String, listIds: [String]) {
        current = channelId
        self.listIds = listIds
        player.onEnded = { [weak self] in Task { @MainActor in self?.streamEnded() } }
        player.onError = { [weak self] in Task { @MainActor in self?.streamFailed() } }
    }

    func start() {
        let all = core.channels.visible()
        // opened from a page of a single channel: zapping uses every channel, in number order
        if listIds.count > 1 { zapIds = listIds }
        else {
            let ordered = all.filter { $0.shiftMin == 0 }.sorted { ($0.num > 0 ? $0.num : Int.max) < ($1.num > 0 ? $1.num : Int.max) }.map { $0.streamId }
            zapIds = ordered.contains(current) ? ordered : [current] + ordered
        }
        tune(current)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.everySecond()
            }
        }
    }

    func stop() {
        ticker?.cancel(); tuneTask?.cancel()
        if let c = channel { core.recordWatch(c, startedAt: watchStart) }
        player.shutdown()
    }

    func poke() { lastInteraction = Clock.now; info = true }

    /// All playable variants of a channel, the preferred one first.
    func variants() -> [(String, String)] {
        guard let ch = channel else { return [] }
        let prefs = core.prefs.values.value
        var all = Prefs.variants(ch.variants, hevc: prefs.hevc)
        if all.isEmpty { all = [(ch.streamId, ch.quality)] }
        let want = Prefs.pickVariant(ch.variants, fallbackId: ch.streamId, want: prefs.quality, hevc: prefs.hevc)
        func rank(_ q: String) -> Int { switch q { case "UHD": return 5; case "FHD": return 4; case "HD": return 3; case "HEVC": return 2; default: return 1 } }
        return [want] + all.filter { $0.0 != want.0 }.sorted { rank($0.1) > rank($1.1) }
    }

    private func open(_ variantId: String) {
        guard let client = core.xtream else { error = "Linea non collegata."; return }
        var url = client.liveUrl(variantId, ext: "ts")
        if let test = Demo.liveTestUrl { url = test }
        player.load(url: url, headers: ["User-Agent": Http.userAgent], live: true)
        paused = false
        resetWatchdog()
    }

    private func resetWatchdog() { lastPos = -1; lastProgressAt = Clock.now; healthy = 0; started = false }

    /// The line allows one connection: the previous stream must be stopped before the next one opens, or the edge answers
    /// 403. So: stop, a short pause, then open.
    func tune(_ id: String, variant: (String, String)? = nil) {
        if (id != current || variant == nil), let c = channel { core.recordWatch(c, startedAt: watchStart) }
        watchStart = Clock.now
        current = id; error = nil; buffering = true; recovering = 0; note = nil; lastFailure = nil
        player.stop()
        tuneTask?.cancel()
        tuning = true
        let delay = UInt64(max(300, core.prefs.values.value.zapDelayMs)) * 1_000_000
        tuneTask = Task { [weak self] in
            guard let self = self else { return }
            let ch = self.core.channels.get(id)
            self.channel = ch
            let prefs = self.core.prefs.values.value
            let v = variant ?? ch.map { Prefs.pickVariant($0.variants, fallbackId: $0.streamId, want: prefs.quality, hevc: prefs.hevc) } ?? (id, "")
            self.playing = v
            self.refreshGuide()
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            self.open(v.0)
            self.tuning = false
            self.core.channels.touchRecent(id)
        }
        poke()
    }

    /// The channel stopped (server closed the stream, error, frozen picture, endless buffering): connect again, and keep
    /// doing it until the picture moves. Each quality gets two tries, then the next one, round and round; the pause grows
    /// up to 4 s so a dead channel is not hammered. After a full round the panel explains what is going on, but the
    /// attempts never stop: the watchdog clears everything as soon as the channel plays again.
    private func reconnect(skipQuality: Bool = false) {
        if tuning { return }
        recovering += 1
        NxLog.w("NxLive", "reconnect #\(recovering) on \(channel?.name ?? "?")/\(playing.1): \(lastFailure ?? "?")")
        buffering = true
        let vs = variants()
        var target = playing
        if vs.count > 1 && (skipQuality || recovering % 2 == 0) {
            let i = vs.firstIndex { $0.0 == playing.0 } ?? 0
            target = vs[(i + 1) % vs.count]
            note = "Qualità \(playing.1.isEmpty ? "predefinita" : playing.1) non risponde, provo \(target.1.isEmpty ? "un'altra" : target.1)…"
            playing = target
        } else if note == nil { note = "Segnale interrotto, mi ricollego…" }
        if recovering >= max(4, vs.count * 2) { error = lastFailure ?? "Il canale ha smesso di trasmettere." }
        let pauseMs: UInt64 = recovering == 1 ? 900 : (recovering == 2 ? 1500 : (recovering == 3 ? 2500 : 4000))
        player.stop()
        tuning = true
        tuneTask?.cancel()
        tuneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: pauseMs * 1_000_000)
            guard let self = self, !Task.isCancelled else { return }
            self.open(target.0)
            self.tuning = false
        }
    }

    private func streamEnded() {
        if tuning || paused { return }
        // a live stream has no end: it means the server closed the connection
        lastFailure = "Il server ha chiuso il collegamento con il canale."
        reconnect()
    }
    private func streamFailed() {
        if tuning { return }
        lastFailure = Vpn.shared.active.value ? "Il canale non si avvia. Può succedere quando la linea è già in uso su un altro dispositivo." : "Nessuna connessione: controlla la rete e la VPN."
        reconnect()
    }

    func zap(_ delta: Int) {
        if zapIds.isEmpty { return }
        let i = zapIds.firstIndex(of: current) ?? 0
        let n = zapIds.count
        tune(zapIds[((i + delta) % n + n) % n])
    }
    var zapChannels: [ChannelEntity] { zapIds.compactMap { core.channels.get($0) } }
    var currentId: String { current }

    func togglePause() {
        if player.isPlaying { player.pause(); paused = true } else { player.play(); paused = false; resetWatchdog() }
        poke()
    }

    private func refreshGuide() {
        guard let e = channel?.epgId else { now = nil; next = nil; nowMeta = nil; return }
        let t = Clock.now
        let list = core.db.upcoming(e, now: t, limit: 2)
        now = list.first { $0.start <= t }
        next = list.first { $0.start > t }
        nowMeta = now.flatMap { core.meta.get(core.meta.keyOf($0)) }.flatMap { $0.found ? $0 : nil }
    }

    /// Watchdog: the stream can die without an error (frozen picture, buffering that never ends). Once a second: is the
    /// position moving?
    private func everySecond() {
        tick += 1
        let t = Clock.now
        if tick % 30 == 0 { refreshGuide() }
        if info && error == nil && t - lastInteraction > 5000 { info = false }
        if tuning || !player.hasMedia || paused { lastProgressAt = t; healthy = 0; if tuning { started = false }; return }
        let pos = player.engineTimeMs
        let moving = player.state == .playing && pos != lastPos
        if moving { lastProgressAt = t }
        lastPos = pos
        buffering = !moving && !paused
        if moving {
            started = true
            healthy += 1
            if healthy >= 4 && (recovering > 0 || error != nil || note != nil) { recovering = 0; error = nil; note = nil; lastFailure = nil }
            // the stream's audio / subtitle languages are known once it plays
            if healthy == 3 { let p = core.prefs.values.value; player.preferAudio(p.preferredAudio); player.preferSubtitle(p.preferredText) }
        } else { healthy = 0 }
        // a channel that was playing gets 8 s to move again; one that is still starting gets 15 s
        if t - lastProgressAt > (started ? 8_000 : 15_000) {
            if lastFailure == nil { lastFailure = "Il canale non manda più dati." }
            lastProgressAt = t
            reconnect()
        }
    }
}

/// Live player. Touch: tap for the info, swipe up / down to change channel. Apple TV remote: up / down change channel,
/// select shows the info, left opens the channel list, right the options, play/pause pauses.
struct LivePlayerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: LivePlayerModel
    @State private var showOptions = false
    @State private var showList = false
    @FocusState private var focused: Bool

    init(channelId: String, listIds: [String]) { _model = StateObject(wrappedValue: LivePlayerModel(channelId: channelId, listIds: listIds)) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: model.player).ignoresSafeArea()
            if model.buffering && model.error == nil { BrandLoader(size: 64) }
            if let n = model.note, model.error == nil {
                VStack { Text(n).font(NxFont.meta).foregroundStyle(NxColor.text).padding(.horizontal, 16).padding(.vertical, 9).nxGlass(Capsule()); Spacer() }.padding(.top, Metrics.u(26))
            }
            if let e = model.error { errorPanel(e) }
            else if model.info { overlay.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: model.info)
        #if os(tvOS)
        .focusable(model.error == nil && !showOptions && !showList)
        .focused($focused)
        .onMoveCommand { dir in
            switch dir {
            case .up: model.zap(1)
            case .down: model.zap(-1)
            case .left: showList = true
            case .right: showOptions = true
            default: break
            }
        }
        .onPlayPauseCommand { model.togglePause() }
        .onTapGesture { if model.info { model.info = false } else { model.poke() } }
        .onLongPressGesture(minimumDuration: 0.6) { showOptions = true }
        .onExitCommand { if model.info && model.error == nil { model.info = false } else { app.playing = nil } }
        .onAppear { focused = true }
        .onChange(of: showOptions) { _, v in if !v { focused = true } }
        .onChange(of: showList) { _, v in if !v { focused = true } }
        #else
        .contentShape(Rectangle())
        .onTapGesture { if model.info { model.info = false } else { model.poke() } }
        .gesture(DragGesture(minimumDistance: 40).onEnded { g in
            if abs(g.translation.height) > abs(g.translation.width) * 1.4 && abs(g.translation.height) > 70 { model.zap(g.translation.height < 0 ? 1 : -1) }
        })
        .statusBarHidden(true)
        #endif
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showOptions) { options }
        .sheet(isPresented: $showList) { channelList }
    }

    private var showing: Showing? { model.channel.map { Showing(channel: $0, programme: model.now, meta: model.nowMeta) } }

    private var overlay: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            HStack(spacing: 10) {
                NxIconButton(icon: "chevron.down", label: "Chiudi") { app.playing = nil }
                Spacer()
                NxIconButton(icon: "list.bullet", label: "Canali") { showList = true }
                NxIconButton(icon: "slider.horizontal.3", label: "Opzioni") { showOptions = true }
            }
            .padding(.horizontal, 16).padding(.top, 10)
            Spacer()
            NxIconButton(icon: model.paused ? "play.fill" : "pause.fill", label: "Pausa", size: 62) { model.togglePause() }
            Spacer()
            #else
            Spacer()
            #endif
            infoBar
        }
    }

    private var infoBar: some View {
        HStack(alignment: .center, spacing: Metrics.u(14)) {
            if let c = model.channel {
                VStack(alignment: .leading, spacing: Metrics.u(4)) {
                    HStack(spacing: Metrics.u(8)) {
                        ChannelLogo(channel: c, height: 24)
                        if c.num > 0 { Text("\(c.num)").font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.textDim) }
                        QualityBadge(quality: model.playing.1)
                        if let s = showing, s.isLiveBroadcast { NxTag(text: "Diretta", color: NxColor.accent) }
                    }
                    Text(showing?.cardTitle ?? c.name).font(NxFont.titleM).foregroundStyle(NxColor.text).lineLimit(1)
                    if let s = showing, let line = [s.timeLabel(), s.cardLine].compactMap({ $0 }).joined(separator: " · ").nilIfBlank {
                        Text(line).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1)
                    }
                    if let p = showing?.progress() { NxProgressBar(value: p).frame(maxWidth: Metrics.u(300)) }
                    if let n = model.next { Text("Dopo: \(TimeText.time(n.start)) \(n.title)").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1) }
                }
                Spacer(minLength: 0)
                #if os(tvOS)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("▲▼ canale   ◀ lista   ▶ opzioni").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                }
                #endif
            }
        }
        .padding(Metrics.u(16))
        .frame(maxWidth: Metrics.tv ? 1500 : 640, alignment: .leading)
        .nxGlassPanel()
        .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(Metrics.tv ? 40 : 14))
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: Metrics.u(12)) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 38 * Metrics.unit)).foregroundStyle(NxColor.textDim)
            Text(model.channel?.name ?? "Canale").font(NxFont.titleM).foregroundStyle(NxColor.text)
            Text(message).font(NxFont.body).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center)
            HStack(spacing: 8) { ProgressView(); Text("Continuo a riprovare…").font(NxFont.caption).foregroundStyle(NxColor.textDim) }
            HStack(spacing: Metrics.u(10)) {
                NxButton("Canale successivo", icon: "chevron.up", kind: .primary) { model.zap(1) }
                NxButton("Esci", kind: .quiet) { app.playing = nil }
            }
        }
        .padding(Metrics.u(26))
        .frame(maxWidth: Metrics.u(460))
        .nxGlassPanel()
    }

    private var options: some View {
        OptionSheet(title: model.channel?.name ?? "Opzioni") {
            let vs = model.variants()
            if vs.count > 1 {
                SwiftUI.Section("Qualità") {
                    ForEach(vs, id: \.0) { v in
                        OptionRow(title: v.1 == "UHD" ? "4K" : v.1, selected: v.0 == model.playing.0) { model.tune(model.currentId, variant: v); showOptions = false }
                    }
                }
            }
            let audio = model.player.audioTracks
            if audio.count > 1 {
                SwiftUI.Section("Audio") {
                    ForEach(audio) { t in OptionRow(title: t.name, selected: t.id == model.player.currentAudio) { model.player.currentAudio = t.id; showOptions = false } }
                }
            }
            let subs = model.player.subtitleTracks
            if subs.count > 1 {
                SwiftUI.Section("Sottotitoli") {
                    ForEach(subs) { t in OptionRow(title: t.id < 0 ? "Spenti" : t.name, selected: t.id == model.player.currentSubtitle) { model.player.currentSubtitle = t.id; showOptions = false } }
                }
            }
            if let c = model.channel {
                SwiftUI.Section {
                    OptionRow(title: store.favorites.contains(c.streamId) ? "Togli dai preferiti" : "Aggiungi ai preferiti", selected: false) { app.toggleFavorite(c) }
                    OptionRow(title: "Dettagli del programma", selected: false) {
                        showOptions = false
                        app.playing = nil
                        app.open(.programme(c.streamId, model.now?.id ?? 0))
                    }
                }
            }
        }
    }

    private var channelList: some View {
        OptionSheet(title: "Canali") {
            ForEach(model.zapChannels) { c in
                let s = store.showing(c)
                OptionRow(title: (c.num > 0 ? "\(c.num)  " : "") + c.name, sub: s.programme != nil || c.event != nil ? s.cardTitle : nil, selected: c.streamId == model.currentId) {
                    showList = false
                    model.tune(c.streamId)
                }
            }
        }
    }
}
