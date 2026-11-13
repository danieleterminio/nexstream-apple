import SwiftUI

enum VodPhase: Equatable {
    case resolving(String)
    case playing
    case failed(String)
    case ended
    case stillWatching
}

/// On-demand playback through Stream4Me: find a source, play it, and when it breaks carry on from another server or
/// another source before ever showing an error. Saves the position, prepares the next episode during the credits.
/// Owned by the app model, so it survives the screen changing shape.
@MainActor
final class VodPlayerModel: ObservableObject {
    let player = NxPlayer()
    private let core = NexCore.shared
    let request: PlayRequest
    private let pid: Int64
    @Published var phase: VodPhase = .resolving("Cerco le sorgenti…")
    @Published var nextReq: PlayRequest? = nil
    @Published var episodes: [TmdbEpisode] = []
    @Published var creditsDismissed = false
    @Published var speed: Float = 1
    @Published var seekTarget: Millis? = nil
    @Published var stream: ResolvedStream? = nil
    @Published var paused = false
    /// Asked by the system controls: play the next episode (the app model does it).
    var onNext: ((PlayRequest) -> Void)?

    private var prefetched: ResolvedStream? = nil
    private var prefetching = false
    private var lastPos: Millis = 0
    private var triedUrls = Set<String>()
    private var triedSources = Set<String>()
    private var failovers = 0
    private var failingOver = false
    private var lastSeekInput = Clock.now
    private var ticker: Task<Void, Never>? = nil
    private var tick = 0
    private var stallAt: Millis = 0
    private var lastEngine: Millis = -1
    private var langApplied = false
    private var closed = false
    private var lastPublishedState: PlayerState = .idle

    init(request: PlayRequest, pid: Int64) {
        self.request = request
        self.pid = pid
        speed = core.settings.speed(pid)
        player.onEnded = { [weak self] in Task { @MainActor in await self?.ended() } }
        player.onError = { [weak self] in Task { @MainActor in await self?.errored() } }
    }

    var details: TmdbDetails { request.details }
    var isOffline: Bool { request.localFile != nil }
    /// Episodes and the next one can be looked up (a downloaded copy played with the VPN on can).
    var canBrowse: Bool { !isOffline || Vpn.shared.active.value }
    var subtitle: String {
        let d = request.details
        return d.isTv ? "S\(request.season) E\(request.episode)" + (request.episodeTitle.map { " · \($0)" } ?? "") : (d.year > 0 ? String(d.year) : "")
    }
    var position: Millis { seekTarget ?? player.positionMs }
    var duration: Millis { player.durationMs }
    var creditsVisible: Bool {
        phase == .playing && !creditsDismissed && core.settings.creditsPrompt(pid) && nextReq != nil && duration > 0 && duration - player.positionMs > 0 && duration - player.positionMs <= 60_000
    }

    func start(retry: Bool = false) {
        if !request.auto && !retry { core.watchSession.touch() }
        let from = retry && lastPos > 0 ? lastPos : request.startMs
        phase = .resolving("Cerco le sorgenti…")
        publishInfo()
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
                publishInfo()
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
    }

    func close() {
        if closed { return }
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
        if !d.isTv || !canBrowse { return nil }
        let season = try? await core.catalog.season(d.id, request.season)
        if let same = season?.episodes?.first(where: { $0.episodeNumber == request.episode + 1 }) {
            return PlayRequest(details: d, season: same.seasonNumber, episode: same.episodeNumber, episodeTitle: same.name)
        }
        let later: [TmdbSeasonSummary] = d.seasons.filter { $0.seasonNumber > request.season && ($0.episodeCount ?? 0) > 0 }
        guard let ns = later.min(by: { $0.seasonNumber < $1.seasonNumber }),
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
        publishProgress()
    }
    func setPaused(_ p: Bool) { if p != paused { togglePlay() } }
    func seekBy(_ deltaMs: Millis) {
        let base = seekTarget ?? player.positionMs
        seekTarget = max(0, min(base + deltaMs, max(0, duration)))
        lastSeekInput = Clock.now
    }
    func scrub(to ms: Millis) { seekTarget = ms; lastSeekInput = Clock.now + 60_000 }
    func applySeek() {
        if let t = seekTarget { player.seek(to: t); seekTarget = nil; publishProgress() }
    }
    /// "Fonte": another version (server) of the same source, from where it is.
    func useAlternate(_ alt: Playable) {
        guard var s = stream, s.channel != "offline", alt.url != s.url else { return }
        let at = max(lastPos, player.positionMs)
        s.url = alt.url; s.headers = alt.headerMap; s.kind = alt.kindValue
        if let l = alt.label, !l.isBlank { s.server = l }
        NxLog.i("NxPlayer", "version chosen: \(s.server)")
        open(s, at: at)
    }
    /// "Cerca un'altra fonte": a new search, playback goes on from where it is.
    func otherSource() {
        lastPos = max(lastPos, player.positionMs)
        start(retry: true)
    }
    func setSpeed(_ v: Float) { speed = v; player.rate = v; core.settings.setSpeed(pid, v); publishProgress() }

    // MARK: system controls

    private func publishInfo() {
        let d = details
        var h = NowPlaying.Handlers()
        h.play = { [weak self] in self?.setPaused(false) }
        h.pause = { [weak self] in self?.setPaused(true) }
        h.toggle = { [weak self] in self?.togglePlay() }
        h.skip = { [weak self] s in self?.seekBy(Millis(s * 1000)); self?.applySeek() }
        h.seek = { [weak self] s in self?.seekTarget = Millis(s * 1000); self?.applySeek() }
        if nextReq != nil { h.next = { [weak self] in if let me = self, let n = me.nextRequest(auto: false) { me.onNext?(n) } } }
        NowPlaying.shared.set(title: d.displayTitle, subtitle: subtitle.nilIfBlank, artwork: Img.tmdb(d.bestBackdrop ?? d.backdropPath ?? d.posterPath, "w780"), live: false, handlers: h)
        publishProgress()
    }
    private func publishProgress() {
        NowPlaying.shared.progress(positionMs: player.positionMs, durationMs: player.durationMs, playing: !paused && phase == .playing, rate: speed)
    }

    // MARK: failover

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
        if player.state != lastPublishedState || tick % 20 == 0 { lastPublishedState = player.state; publishProgress() }
        if tick % 10 == 0 && duration > 0 && player.isPlaying {
            core.library.saveProgress(pid, details.id, details.media, season: request.season, episode: request.episode, positionMs: player.positionMs, durationMs: duration)
        }
        if seekTarget != nil && t - lastSeekInput > 700 { applySeek() }
        if let nr = nextReq, prefetched == nil, !prefetching, duration > 0, duration - player.positionMs < 240_000 {
            prefetching = true
            Task { self.prefetched = await self.core.resolver.resolve(nr); NxLog.i("NxPlayer", "prefetched next: \(self.prefetched?.channel ?? "-")") }
        }
    }
}
