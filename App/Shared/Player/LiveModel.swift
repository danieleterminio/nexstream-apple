import SwiftUI

/// Live playback: tuning, zapping, and never giving up on a channel that stalls (the Android player's logic). It lives
/// in the app model, not in a view, so the channel keeps playing while the screen changes shape (portrait, full screen,
/// picture in picture, CarPlay).
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
    @Published var paused = false

    private var current: String
    private var listIds: [String]
    private var zapIds: [String] = []
    private var tuneTask: Task<Void, Never>? = nil
    private var tuning = false
    private var watchStart = Clock.now
    private var recovering = 0
    private var lastFailure: String? = nil
    // watchdog
    private var lastPos: Millis = -1
    private var lastProgressAt = Clock.now
    private var healthy = 0
    private var started = false
    private var ticker: Task<Void, Never>? = nil
    private var tick = 0
    private var stopped = false

    init(channelId: String, listIds: [String]) {
        current = channelId
        self.listIds = listIds
        player.onEnded = { [weak self] in Task { @MainActor in self?.streamEnded() } }
        player.onError = { [weak self] in Task { @MainActor in self?.streamFailed() } }
    }

    func start() {
        buildZap()
        tune(current)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.everySecond()
            }
        }
    }

    private func buildZap() {
        // opened from a page of a single channel: zapping uses every channel, in number order
        if listIds.count > 1 { zapIds = listIds }
        else {
            let all = core.channels.visible()
            let ordered = all.filter { $0.shiftMin == 0 }.sorted { ($0.num > 0 ? $0.num : Int.max) < ($1.num > 0 ? $1.num : Int.max) }.map { $0.streamId }
            zapIds = ordered.contains(current) ? ordered : [current] + ordered
        }
    }

    /// Another channel was picked from outside the player (a list, CarPlay, a link) while this one was playing.
    func switchTo(_ id: String, listIds ids: [String]) {
        listIds = ids
        current = id
        buildZap()
        tune(id)
    }

    func stop() {
        if stopped { return }
        stopped = true
        ticker?.cancel(); tuneTask?.cancel()
        if let c = channel { core.recordWatch(c, startedAt: watchStart) }
        player.shutdown()
    }

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
        if let test = Demo.liveTestUrl {
            // the build pipeline's test stream: a plain HLS address, or a .ts one to exercise the live proxy
            player.load(url: test, headers: [:], live: test.contains(".ts"), key: nil)
        } else {
            player.load(url: client.liveUrl(variantId, ext: "ts"), headers: ["User-Agent": Http.userAgent], live: true, key: "live-" + variantId)
        }
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
        let ch = core.channels.get(id)
        channel = ch
        let prefs = core.prefs.values.value
        let v = variant ?? ch.map { Prefs.pickVariant($0.variants, fallbackId: $0.streamId, want: prefs.quality, hevc: prefs.hevc) } ?? (id, "")
        playing = v
        refreshGuide()
        tuneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self = self, !Task.isCancelled else { return }
            self.open(v.0)
            self.tuning = false
            self.core.channels.touchRecent(id)
        }
    }

    /// The channel stopped (server closed the stream, error, frozen picture, endless buffering): connect again, and keep
    /// doing it until the picture moves. Each quality gets two tries, then the next one, round and round; the pause grows
    /// up to 4 s so a dead channel is not hammered. After a full round the panel explains what is going on, but the
    /// attempts never stop: the watchdog clears everything as soon as the channel plays again.
    private func reconnect() {
        if tuning || stopped { return }
        recovering += 1
        NxLog.w("NxLive", "reconnect #\(recovering) on \(channel?.name ?? "?")/\(playing.1): \(lastFailure ?? "?")")
        buffering = true
        let vs = variants()
        var target = playing
        if vs.count > 1 && recovering % 2 == 0 {
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
        if player.isPlaying { player.pause(); paused = true }
        else if player.hasMedia { player.play(); paused = false; resetWatchdog() }
        publish()
    }
    func setPaused(_ p: Bool) { if p != paused { togglePause() } }

    private func refreshGuide() {
        if let e = channel?.epgId {
            let t = Clock.now
            let list = core.db.upcoming(e, now: t, limit: 2)
            now = list.first { $0.start <= t }
            next = list.first { $0.start > t }
            nowMeta = now.flatMap { core.meta.get(core.meta.keyOf($0)) }.flatMap { $0.found ? $0 : nil }
        } else { now = nil; next = nil; nowMeta = nil }
        publish()
    }

    var showing: Showing? { channel.map { Showing(channel: $0, programme: now, meta: nowMeta) } }

    /// Tells the system what is on (Control Centre, lock screen, CarPlay).
    private func publish() {
        guard let c = channel else { return }
        let s = Showing(channel: c, programme: now, meta: nowMeta)
        let title = (now != nil || c.event != nil) ? s.cardTitle : c.name
        var h = NowPlaying.Handlers()
        h.play = { [weak self] in self?.setPaused(false) }
        h.pause = { [weak self] in self?.setPaused(true) }
        h.toggle = { [weak self] in self?.togglePause() }
        h.next = { [weak self] in self?.zap(1) }
        h.previous = { [weak self] in self?.zap(-1) }
        NowPlaying.shared.set(title: title, subtitle: c.name, artwork: Img.card(s.image) ?? c.icon, live: true, handlers: h)
        NowPlaying.shared.progress(positionMs: 0, durationMs: 0, playing: !paused)
    }

    /// Watchdog: the stream can die without an error (frozen picture, buffering that never ends). Once a second: is the
    /// position moving?
    private func everySecond() {
        tick += 1
        let t = Clock.now
        if tick % 30 == 0 { refreshGuide() }
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
        // a channel that was playing gets 8 s to move again; one that is still starting gets 20 s
        if t - lastProgressAt > (started ? 8_000 : 20_000) {
            if lastFailure == nil { lastFailure = "Il canale non manda più dati." }
            lastProgressAt = t
            reconnect()
        }
    }
}
