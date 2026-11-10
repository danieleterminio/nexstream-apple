import SwiftUI

enum VodPhase: Equatable {
    /// resumeAt > 0: playback broke and the player is switching to another server / source from that point.
    case resolving(String)
    case playing
    case failed(String)
    case ended
    case stillWatching
}

/// On-demand playback through Stream4Me: find a source, play it, and when it breaks carry on from another server or
/// another source before ever showing an error. Saves the position, prepares the next episode during the credits.
@MainActor
final class VodPlayerModel: ObservableObject {
    let player = NxPlayer()
    private let core = NexCore.shared
    let request: PlayRequest
    private let pid: Int64
    @Published var phase: VodPhase = .resolving("Cerco le sorgenti…")
    @Published var controls = false
    @Published var nextReq: PlayRequest? = nil
    @Published var episodes: [TmdbEpisode] = []
    @Published var creditsDismissed = false
    @Published var speed: Float = 1
    @Published var seekTarget: Millis? = nil
    @Published var stream: ResolvedStream? = nil
    @Published var paused = false

    private var prefetched: ResolvedStream? = nil
    private var prefetching = false
    private var lastPos: Millis = 0
    private var triedUrls = Set<String>()
    private var triedSources = Set<String>()
    private var failovers = 0
    private var failingOver = false
    private var lastInteraction = Clock.now
    private var ticker: Task<Void, Never>? = nil
    private var tick = 0
    private var stallAt: Millis = 0
    private var lastEngine: Millis = -1
    private var langApplied = false
    private var closed = false

    init(request: PlayRequest, pid: Int64) {
        self.request = request
        self.pid = pid
        speed = core.settings.speed(pid)
        player.onEnded = { [weak self] in Task { @MainActor in await self?.ended() } }
        player.onError = { [weak self] in Task { @MainActor in await self?.errored() } }
    }

    var details: TmdbDetails { request.details }
    var subtitle: String {
        let d = request.details
        return d.isTv ? "S\(request.season) E\(request.episode)" + (request.episodeTitle.map { " · \($0)" } ?? "") : (d.year > 0 ? String(d.year) : "")
    }
    var position: Millis { seekTarget ?? player.positionMs }
    var duration: Millis { player.durationMs }
    var creditsVisible: Bool {
        phase == .playing && !creditsDismissed && core.settings.creditsPrompt(pid) && nextReq != nil && duration > 0 && duration - player.positionMs > 0 && duration - player.positionMs <= 60_000
    }

    func poke() { lastInteraction = Clock.now; controls = true }

    func start(retry: Bool = false) {
        if !request.auto && !retry { core.watchSession.touch() }
        let from = retry && lastPos > 0 ? lastPos : request.startMs
        phase = .resolving("Cerco le sorgenti…")
        if retry { core.db.clearSourceCache(details.id, details.media); triedUrls = []; triedSources = []; failovers = 0 }
        Task {
            if let file = request.localFile {
                player.loadFile(URL(fileURLWithPath: file), startMs: from)
                stream = ResolvedStream(url: file, headers: [:], kind: "offline", server: "Scaricato", channel: "offline")
                phase = .playing
            } else {
                var s = retry ? nil : request.preResolved
                if s == nil { s = await core.resolver.resolve(request) { [weak self] st in Task { @MainActor in
                    guard let me = self else { return }
                    if case .resolving = me.phase { me.phase = .resolving(st) }
                } } }
                guard let found = s else { phase = .failed("Questo titolo non è disponibile al momento su nessuna fonte."); return }
                if closed { return }
                open(found, at: from)
            }
            if details.isTv {
                episodes = (try? await core.catalog.season(details.id, request.season))?.episodes ?? []
                nextReq = await nextEpisode()
            }
        }
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.halfSecond()
                }
            }
        }
    }

    private func open(_ s: ResolvedStream, at: Millis) {
        stream = s
        langApplied = false
        stallAt = 0
        player.load(url: s.url, headers: s.headers, startMs: at, live: false)
        phase = .playing
        paused = false
        poke()
    }

    func close() {
        closed = true
        ticker?.cancel()
        let pos = player.positionMs, dur = player.durationMs
        player.shutdown()
        if dur > 0 {
            let d = details
            core.library.saveProgress(pid, d.id, d.media, season: request.season, episode: request.episode, positionMs: pos, durationMs: dur)
            core.library.abandoned(pid, d.id, d.media, positionMs: pos, durationMs: dur)
        }
    }

    func nextEpisode() async -> PlayRequest? {
        let d = details
        if !d.isTv { return nil }
        let season = try? await core.catalog.season(d.id, request.season)
        if let same = season?.episodes?.first(where: { $0.episodeNumber == request.episode + 1 }) {
            return PlayRequest(details: d, season: same.seasonNumber, episode: same.episodeNumber, episodeTitle: same.name)
        }
        guard let ns = d.seasons.filter({ $0.seasonNumber > request.season && ($0.episodeCount ?? 0) > 0 }).min(by: { $0.seasonNumber < $1.seasonNumber }),
              let first = (try? await core.catalog.season(d.id, ns.seasonNumber))?.episodes?.first else { return nil }
        return PlayRequest(details: d, season: first.seasonNumber, episode: first.episodeNumber, episodeTitle: first.name)
    }

    /// The request for the next episode, with its source if it was prepared during the credits.
    func nextRequest(auto: Bool) -> PlayRequest? {
        guard var n = nextReq else { return nil }
        n.preResolved = prefetched
        n.auto = auto
        return n
    }

    func togglePlay() {
        applySeek()
        if player.isPlaying { player.pause(); paused = true } else { player.play(); paused = false }
        poke()
    }
    func seekBy(_ deltaMs: Millis) {
        let base = seekTarget ?? player.positionMs
        seekTarget = max(0, min(base + deltaMs, max(0, duration)))
        poke()
    }
    func scrub(to ms: Millis) { seekTarget = ms; poke() }
    func applySeek() {
        if let t = seekTarget { player.seek(to: t); seekTarget = nil }
    }
    func setSpeed(_ v: Float) { speed = v; player.rate = v; core.settings.setSpeed(pid, v) }

    /// The stream broke: before showing any error, try the other servers of the same source, then the other sources,
    /// and carry on from where it was. The error page is the last resort.
    private func failover(_ reason: String) async {
        guard let cur = stream, cur.channel != "offline", !failingOver, !closed else { return }
        failingOver = true
        defer { failingOver = false }
        let at = max(lastPos, player.positionMs)
        NxLog.w("NxPlayer", "playback failed on \(cur.channel)/\(cur.server) at \(at / 1000)s: \(reason)")
        triedUrls.insert(cur.url)
        failovers += 1
        if failovers > 10 { phase = .failed("Nessuna fonte riesce a riprodurre questo titolo al momento."); return }
        player.stop()
        if let alt = cur.alternates.first(where: { !triedUrls.contains($0.url) }) {
            phase = .resolving("Passo a un altro server…")
            try? await Task.sleep(nanoseconds: 400_000_000)
            var s = cur
            s.url = alt.url; s.headers = alt.headerMap; s.kind = alt.kindValue
            if let l = alt.label, !l.isBlank { s.server = l }
            if !closed { open(s, at: at) }
            return
        }
        triedSources.insert(cur.channel)
        phase = .resolving("Cerco un'altra fonte…")
        let next = await core.resolver.resolve(request, exclude: triedSources)
        if closed { return }
        guard let n = next else { phase = .failed("Ho provato tutte le fonti disponibili, ma nessuna riesce a riprodurre questo titolo adesso."); return }
        open(n, at: at)
    }

    private func ended() async {
        guard phase == .playing, !failingOver else { return }
        let dur = player.durationMs, pos = player.positionMs
        // "ended" minutes before the end = the server dropped the file: carry on from another server / source
        if let cur = stream, cur.channel != "offline", dur <= 0 || dur - pos > 90_000 { await failover("ended early"); return }
        if dur > 0 { core.library.saveProgress(pid, details.id, details.media, season: request.season, episode: request.episode, positionMs: dur, durationMs: dur) }
        if nextReq == nil { nextReq = await nextEpisode() }
        let s = core.settings
        if nextReq != nil && core.watchSession.shouldAsk(hours: s.stillWatchingHours(pid), episodes: s.stillWatchingEpisodes(pid)) { phase = .stillWatching } else { phase = .ended }
    }
    private func errored() async {
        guard phase == .playing else { return }
        if stream == nil || stream?.channel == "offline" { phase = .failed("La riproduzione non è partita."); return }
        await failover("player error")
    }

    private func halfSecond() {
        tick += 1
        guard phase == .playing else { return }
        let t = Clock.now
        // a source that stops sending without an error would buffer for ever: after 25 s move to another one
        let engine = player.engineTimeMs
        if !paused && stream?.channel != "offline" && engine == lastEngine && seekTarget == nil {
            if stallAt == 0 { stallAt = t } else if t - stallAt > 25_000 { stallAt = 0; Task { await failover("stalled") } }
        } else { stallAt = 0 }
        lastEngine = engine
        if player.state == .playing && player.positionMs > 0 { lastPos = player.positionMs }
        if !langApplied && player.state == .playing && player.positionMs > 1500 {
            langApplied = true
            player.preferAudio(core.settings.audioLang(pid))
            if speed != 1 { player.rate = speed }
        }
        if tick % 10 == 0 && duration > 0 && player.isPlaying {
            core.library.saveProgress(pid, details.id, details.media, season: request.season, episode: request.episode, positionMs: player.positionMs, durationMs: duration)
        }
        if controls && player.isPlaying && seekTarget == nil && t - lastInteraction > 4500 { controls = false }
        if seekTarget != nil && t - lastInteraction > 700 { applySeek() }
        if let nr = nextReq, prefetched == nil, !prefetching, duration > 0, duration - player.positionMs < 240_000 {
            prefetching = true
            Task { self.prefetched = await self.core.resolver.resolve(nr); NxLog.i("NxPlayer", "prefetched next: \(self.prefetched?.channel ?? "-")") }
        }
    }
}

/// On-demand player. Touch: tap for the controls, the bar to move. Apple TV remote: left / right move by 10 s,
/// select or play/pause pauses, up opens the options.
struct VodPlayerView: View {
    let request: PlayRequest
    @EnvironmentObject var app: AppModel
    @StateObject private var model: VodPlayerModel
    @State private var showOptions = false
    @State private var showEpisodes = false
    @State private var countdown = 10
    @FocusState private var focused: Bool

    init(request: PlayRequest) {
        self.request = request
        _model = StateObject(wrappedValue: VodPlayerModel(request: request, pid: NexCore.shared.profiles.id))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: model.player).ignoresSafeArea()
            switch model.phase {
            case .resolving(let status): resolving(status)
            case .playing: playingOverlay
            case .failed(let message): failed(message)
            case .ended: ended
            case .stillWatching: stillWatching
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.controls)
        #if os(tvOS)
        .focusable(model.phase == .playing && !showOptions && !showEpisodes)
        .focused($focused)
        .onMoveCommand { dir in
            switch dir {
            case .left: model.seekBy(-10_000)
            case .right: model.seekBy(10_000)
            case .up: showOptions = true
            case .down: model.poke()
            default: break
            }
        }
        .onPlayPauseCommand { model.togglePlay() }
        .onTapGesture { if model.seekTarget != nil { model.applySeek() } else { model.togglePlay() } }
        .onExitCommand { if model.controls && model.phase == .playing && model.player.isPlaying { model.controls = false } else { app.playing = nil } }
        .onAppear { focused = true }
        .onChange(of: showOptions) { _, v in if !v { focused = true } }
        .onChange(of: showEpisodes) { _, v in if !v { focused = true } }
        .onChange(of: model.phase) { _, p in if p == .playing { focused = true } }
        #else
        .contentShape(Rectangle())
        .onTapGesture { if model.controls { model.controls = false } else { model.poke() } }
        .statusBarHidden(true)
        #endif
        .onAppear { model.start() }
        .onDisappear { model.close() }
        .sheet(isPresented: $showOptions) { options }
        .sheet(isPresented: $showEpisodes) { episodeList }
    }

    private func go(_ r: PlayRequest) { app.playing = .vod(r) }

    private func resolving(_ status: String) -> some View {
        ZStack {
            NxImage(url: Img.tmdb(model.details.bestBackdrop ?? model.details.backdropPath, "w1280"), maxPixel: 1600) { Color.black }.ignoresSafeArea().opacity(0.35)
            VStack(spacing: Metrics.u(14)) {
                BrandLoader(size: 64)
                Text(model.details.displayTitle).font(NxFont.titleL).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
                if !model.subtitle.isEmpty { Text(model.subtitle).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                Text(status).font(NxFont.meta).foregroundStyle(NxColor.textDim)
                NxButton("Annulla", kind: .quiet) { app.playing = nil }.padding(.top, Metrics.u(8))
            }
            .padding(Metrics.u(24))
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: Metrics.u(12)) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 38 * Metrics.unit)).foregroundStyle(NxColor.textDim)
            Text(model.details.displayTitle).font(NxFont.titleM).foregroundStyle(NxColor.text)
            Text(message).font(NxFont.body).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center)
            HStack(spacing: Metrics.u(10)) {
                NxButton("Riprova", icon: "arrow.clockwise", kind: .primary) { model.start(retry: true) }
                NxButton("Chiudi", kind: .quiet) { app.playing = nil }
            }
        }
        .padding(Metrics.u(26)).frame(maxWidth: Metrics.u(460)).nxGlassPanel()
    }

    @ViewBuilder private var playingOverlay: some View {
        if model.player.state == .opening || model.player.state == .buffering { BrandLoader(size: 60) }
        if model.controls || model.paused || model.seekTarget != nil { controlsView.transition(.opacity) }
        if model.creditsVisible, let n = model.nextRequest(auto: false) {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: Metrics.u(8)) {
                        Text("Prossimo episodio").font(NxFont.label).foregroundStyle(NxColor.textDim)
                        Text("S\(n.season) E\(n.episode)" + (n.episodeTitle.map { " · \($0)" } ?? "")).font(NxFont.bodyStrong).foregroundStyle(NxColor.text).lineLimit(1)
                        HStack(spacing: Metrics.u(8)) {
                            NxButton("Guarda ora", icon: "forward.end.fill", kind: .primary) { go(n) }
                            NxButton("Titoli di coda", kind: .quiet) { model.creditsDismissed = true }
                        }
                    }
                    .padding(Metrics.u(14)).nxGlassPanel()
                }
            }
            .padding(.horizontal, Metrics.u(18)).padding(.bottom, Metrics.u(Metrics.tv ? 150 : 96))
        }
    }

    private var controlsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.u(10)) {
                #if os(iOS)
                NxIconButton(icon: "chevron.down", label: "Chiudi") { app.playing = nil }
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.details.displayTitle).font(NxFont.titleM).foregroundStyle(NxColor.text).lineLimit(1)
                    if !model.subtitle.isEmpty { Text(model.subtitle).font(NxFont.caption).foregroundStyle(NxColor.textMuted).lineLimit(1) }
                }
                Spacer()
                #if os(iOS)
                if model.details.isTv { NxIconButton(icon: "rectangle.stack", label: "Episodi") { showEpisodes = true } }
                NxIconButton(icon: "slider.horizontal.3", label: "Opzioni") { showOptions = true }
                #endif
            }
            .padding(.horizontal, Metrics.u(18)).padding(.top, Metrics.u(Metrics.tv ? 50 : 12))
            Spacer()
            #if os(iOS)
            HStack(spacing: 34) {
                NxIconButton(icon: "gobackward.10", label: "Indietro 10 secondi", size: 52) { model.seekBy(-10_000); model.applySeek() }
                NxIconButton(icon: model.paused ? "play.fill" : "pause.fill", label: "Pausa", size: 68) { model.togglePlay() }
                NxIconButton(icon: "goforward.10", label: "Avanti 10 secondi", size: 52) { model.seekBy(10_000); model.applySeek() }
            }
            Spacer()
            #endif
            VStack(spacing: Metrics.u(6)) {
                #if os(iOS)
                Slider(value: Binding(get: { Double(model.position) }, set: { model.scrub(to: Millis($0)) }), in: 0...Double(max(1, model.duration))) { editing in if !editing { model.applySeek() } }
                    .tint(NxColor.accent)
                #else
                NxProgressBar(value: model.duration > 0 ? Double(model.position) / Double(model.duration) : 0, height: 5)
                #endif
                HStack {
                    Text(playerClock(model.position)).font(NxFont.ui(12, .bold)).foregroundStyle(NxColor.text).monospacedDigit()
                    Spacer()
                    #if os(tvOS)
                    Text(model.paused ? "In pausa   ·   ▲ opzioni" : "◀ ▶ 10 secondi   ·   ▲ opzioni").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    Spacer()
                    #endif
                    Text(model.duration > 0 ? "-" + playerClock(model.duration - model.position) : "").font(NxFont.ui(12, .bold)).foregroundStyle(NxColor.textMuted).monospacedDigit()
                }
            }
            .padding(Metrics.u(14))
            .nxGlassPanel()
            .padding(.horizontal, Metrics.u(16)).padding(.bottom, Metrics.u(Metrics.tv ? 40 : 12))
        }
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false))
    }

    private var ended: some View {
        let next = model.nextRequest(auto: true)
        let autoplay = next != nil && app.core.settings.autoplay(app.pid)
        return VStack(spacing: Metrics.u(14)) {
            if let n = next {
                Text("Prossimo episodio").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim)
                Text("S\(n.season) E\(n.episode)" + (n.episodeTitle.map { " · \($0)" } ?? "")).font(NxFont.titleL).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
                if autoplay { Text("Parte tra \(countdown) secondi").font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                HStack(spacing: Metrics.u(10)) {
                    NxButton("Guarda ora", icon: "play.fill", kind: .primary) { var x = n; x.auto = false; app.core.watchSession.touch(); go(x) }
                    NxButton("Chiudi", kind: .quiet) { app.playing = nil }
                }
            } else {
                Text(model.details.displayTitle).font(NxFont.titleL).foregroundStyle(NxColor.text)
                Text("Fine").font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                NxButton("Chiudi", kind: .primary) { app.playing = nil }
            }
        }
        .padding(Metrics.u(26)).frame(maxWidth: Metrics.u(480)).nxGlassPanel()
        .task {
            guard autoplay, let n = next else { return }
            countdown = 10
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
            app.core.watchSession.autoplayed += 1
            go(n)
        }
    }

    /// Netflix-style "Stai ancora guardando?": playback stays stopped until the viewer answers.
    private var stillWatching: some View {
        VStack(spacing: Metrics.u(14)) {
            Text("Stai ancora guardando?").font(NxFont.titleXL).foregroundStyle(NxColor.text)
            Text(model.details.displayTitle).font(NxFont.meta).foregroundStyle(NxColor.textMuted)
            HStack(spacing: Metrics.u(10)) {
                NxButton("Continua a guardare", icon: "play.fill", kind: .primary) {
                    app.core.watchSession.touch()
                    if let n = model.nextRequest(auto: false) { go(n) } else { app.playing = nil }
                }
                NxButton("Esci", kind: .quiet) { app.playing = nil }
            }
        }
        .padding(Metrics.u(28)).frame(maxWidth: Metrics.u(520)).nxGlassPanel()
    }

    private var options: some View {
        OptionSheet(title: "Opzioni") {
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
            SwiftUI.Section("Velocità") {
                ForEach(Settings.speedOptions, id: \.self) { v in
                    OptionRow(title: v == 1 ? "Normale" : String(format: "%.2g×", v), selected: model.speed == v) { model.setSpeed(v); showOptions = false }
                }
            }
            if let s = model.stream, s.channel != "offline" {
                SwiftUI.Section("Fonte") {
                    OptionRow(title: "\(s.channel) · \(s.server)", sub: "Se il video ha problemi puoi cercarne un'altra", selected: false) { showOptions = false; model.start(retry: true) }
                }
            }
            #if os(tvOS)
            if model.details.isTv { SwiftUI.Section { OptionRow(title: "Episodi", selected: false) { showOptions = false; showEpisodes = true } } }
            SwiftUI.Section { OptionRow(title: "Esci dal video", selected: false) { showOptions = false; app.playing = nil } }
            #endif
        }
    }

    private var episodeList: some View {
        OptionSheet(title: "Stagione \(request.season)") {
            ForEach(model.episodes) { e in
                OptionRow(title: "\(e.episodeNumber). \(e.name ?? "Episodio \(e.episodeNumber)")", sub: e.runtime.map { "\($0) min" }, selected: e.episodeNumber == request.episode) {
                    showEpisodes = false
                    if e.episodeNumber != request.episode { go(PlayRequest(details: model.details, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name)) }
                }
            }
        }
    }
}
