import Foundation

struct ResolvedStream: Hashable {
    var url: String
    var headers: [String: String]
    var kind: String            // hls | dash | progressive
    var server: String
    var channel: String
    var alternates: [Playable] = []
}

struct PlayRequest: Hashable, Identifiable {
    var details: TmdbDetails
    var season: Int = 0
    var episode: Int = 0
    var episodeTitle: String? = nil
    var startMs: Millis = 0
    var preResolved: ResolvedStream? = nil
    var auto: Bool = false
    /// A downloaded file to play instead of resolving (offline).
    var localFile: String? = nil
    var id: String { "\(details.media)-\(details.id)-\(season)-\(episode)" }
}

/// Maps a TMDB title (+ optional S/E) to a playable URL via the Stream4Me engine, with a per-title source cache.
final class PlaybackResolver {
    private let engine: Engine
    private let db: AppDB
    init(engine: Engine, db: AppDB) { self.engine = engine; self.db = db }

    /// `exclude` = sources (Stream4Me channels) that already failed for this playback: they are skipped.
    func resolve(_ req: PlayRequest, exclude: Set<String> = [], onStatus statusRaw: @escaping (String) -> Void = { _ in }) async -> ResolvedStream? {
        let onStatus: (String) -> Void = { NxLog.i("NxResolver", $0); statusRaw($0) }
        let d = req.details
        NxLog.i("NxResolver", "resolve \(d.media)/\(d.id) \(d.displayTitle) S\(req.season)E\(req.episode)")
        let type = d.isTv ? "tvshow" : "movie"

        // 1) cached match for this TMDB title
        if let cached = db.sourceCache(d.id, d.media), !exclude.contains(cached.channel) {
            onStatus("Avvio il video…")
            if let r = await tryHit(SearchHit(channel: cached.channel, title: cached.title, type: type, item: cached.item), req) {
                db.upsertVodIndex(VodIndexEntity(tmdbId: d.id, media: d.media, available: true))
                return r
            }
            db.clearSourceCache(d.id, d.media)
        }

        // 2) search by Italian title, then by original title
        onStatus("Cerco le sorgenti…")
        let queries = [d.displayTitle, d.originalDisplayTitle].map { $0.trimmed }.filter { !$0.isBlank }.distinct
        var seenItems = Set<String>()
        // the sources answer at their own pace (slower behind a VPN): a first quick round, then, if nothing could be
        // played, a patient one that also waits for the slow sources and tries more of what they found
        let rounds: [(String, Int, Int)] = queries.map { ($0, 20, exclude.isEmpty ? 4 : 6) } + queries.prefix(1).map { ($0, 40, 8) }
        for (q, wait, take) in rounds {
            if wait > 20 { onStatus("Cerco ancora tra le sorgenti più lente…") }
            let resp: SearchResponse
            do { resp = try await engine.search(q, type: type, year: d.year, timeoutSec: wait) }
            catch { NxLog.w("NxResolver", "search \"\(q)\" failed: \(error)"); continue }
            NxLog.i("NxResolver", "search \"\(q)\" (\(wait) s): \(resp.hits.count) results in \(resp.elapsed ?? 0)s; top=\(resp.hits.prefix(5).map { "\($0.channel):\($0.title):\($0.scoreValue)" })")
            let hits = resp.hits.filter { $0.scoreValue >= 0.6 && !exclude.contains($0.channel) && seenItems.insert($0.item).inserted }.prefix(take)
            for hit in hits {
                onStatus("Trovato, lo preparo…")
                if let r = await tryHit(hit, req) {
                    db.upsertSourceCache(SourceCacheEntity(tmdbId: d.id, media: d.media, channel: hit.channel, item: hit.item, title: hit.title))
                    db.upsertVodIndex(VodIndexEntity(tmdbId: d.id, media: d.media, available: true))
                    return r
                }
            }
        }
        // remembered as a miss for a week, so the matcher does not keep promising what Stream4Me has not got
        if exclude.isEmpty { db.upsertVodIndex(VodIndexEntity(tmdbId: d.id, media: d.media, available: false)) }
        return nil
    }

    private func tryHit(_ hit: SearchHit, _ req: PlayRequest) async -> ResolvedStream? {
        var item = hit.item
        if req.details.isTv {
            let eps: [EpisodeHit]
            do { eps = try await engine.episodes(hit.item) } catch { NxLog.w("NxResolver", "\(hit.channel): episodes failed: \(error)"); return nil }
            if eps.isEmpty { NxLog.w("NxResolver", "\(hit.channel): no episodes listed"); return nil }
            guard let ep = eps.first(where: { $0.season == req.season && $0.episode == req.episode })
                    ?? eps.first(where: { $0.season == 0 && $0.episode == req.episode && req.season == 1 })   // channels that don't number seasons
            else { NxLog.w("NxResolver", "\(hit.channel): S\(req.season)E\(req.episode) not among \(eps.count) episodes"); return nil }
            item = ep.item
        }
        let r: PlayResponse
        do { r = try await engine.play(item) } catch { NxLog.w("NxResolver", "\(hit.channel): play failed: \(error)"); return nil }
        guard let url = r.url else { NxLog.w("NxResolver", "\(hit.channel): no playable link"); return nil }
        NxLog.i("NxResolver", "play on \(hit.channel): server=\(r.server ?? "?") kind=\(r.kind ?? "?")")
        return ResolvedStream(url: url, headers: r.headers ?? [:], kind: r.kind ?? "progressive", server: r.server ?? "", channel: hit.channel, alternates: r.all ?? [])
    }
}

enum UpdateResult: Equatable {
    case upToDate
    case updated(String)
    case failed(String)
    case skipped
}

/// Keeps the extracted Stream4Me copy in sync with its GitHub branch (same source Kodi uses for its "Aggiornamento domini"
/// commits). One tiny API call per check; a full zip download only when the commit changed. The new tree is swapped in and
/// rolled back if the engine cannot load it. Download and unzip run in the embedded Python (`nxtools.py`).
final class AddonUpdater {
    private let engine: Engine
    private let d = UserDefaults.standard
    private let mutex = AsyncLock()
    let last = Observable<UpdateResult?>(nil)

    private static let commitFile = "nx_commit.txt"
    private static let user = "stream4me", repo = "addon", branch = "master"
    private static let minIntervalMs: Millis = 2 * Clock.hour
    private static let shaRx = Rx("^[0-9a-f]{40}$")

    init(engine: Engine) { self.engine = engine }

    func localCommit() -> String? {
        (try? String(contentsOf: engine.addonDir.appendingPathComponent(AddonUpdater.commitFile), encoding: .utf8))?.trimmed.nilIfBlank
    }

    @discardableResult
    func check(force: Bool = false) async -> UpdateResult {
        await mutex.lock()
        var r: UpdateResult
        do { r = try await doCheck(force) } catch {
            NxLog.w("NxUpdater", "update failed: \(error)")
            r = .failed("Aggiornamento non riuscito: uso le sorgenti locali")
        }
        if r != .skipped { last.value = r }
        await mutex.unlock()
        return r
    }

    private func doCheck(_ force: Bool) async throws -> UpdateResult {
        let now = Clock.now
        if !force && now - Millis(d.double(forKey: "updater.last_check")) < AddonUpdater.minIntervalMs { return .skipped }
        try await engine.ensureReady()
        let shaUrl = "https://api.github.com/repos/\(AddonUpdater.user)/\(AddonUpdater.repo)/commits/\(AddonUpdater.branch)"
        guard let resp = try? await Http.request(shaUrl, headers: ["Accept": "application/vnd.github.sha", "User-Agent": "NexStream"], timeout: 10), resp.ok else {
            return .failed("Nessuna connessione: uso le sorgenti locali")
        }
        let remote = resp.text.trimmed
        if !AddonUpdater.shaRx.matches(remote) { return .failed("Risposta inattesa da GitHub") }
        d.set(Double(now), forKey: "updater.last_check")
        let local = localCommit()
        NxLog.i("NxUpdater", "local=\(local?.take(7) ?? "-") remote=\(remote.take(7))")
        if remote == local { return .upToDate }
        if d.string(forKey: "updater.bad") == remote { return .failed("L'ultimo aggiornamento non è compatibile: uso le sorgenti locali") }

        // download + extract into a fresh folder
        let fm = FileManager.default
        let parent = engine.addonDir.deletingLastPathComponent()
        let fresh = parent.appendingPathComponent("s4me_new"), old = parent.appendingPathComponent("s4me_old")
        let zip = Paths.tmp.appendingPathComponent("s4me_update.zip")
        let res = J.parse(try await engine.tool("download_addon", [AddonUpdater.user, AddonUpdater.repo, remote, fresh.path, zip.path]))
        if !res["ok"].bool {
            try? fm.removeItem(at: fresh)
            throw EngineError(description: res["error"].stringOrNil ?? "zip incompleto (\(res["files"].int) file)")
        }
        try remote.write(to: fresh.appendingPathComponent(AddonUpdater.commitFile), atomically: true, encoding: .utf8)
        try? fm.copyItem(at: engine.addonDir.appendingPathComponent(".version"), to: fresh.appendingPathComponent(".version"))

        // swap in, verify, roll back on failure
        try? fm.removeItem(at: old)
        try fm.moveItem(at: engine.addonDir, to: old)
        do { try fm.moveItem(at: fresh, to: engine.addonDir) } catch { try? fm.moveItem(at: old, to: engine.addonDir); throw error }
        let ok = (try? await engine.reload()) ?? 0
        if ok <= 0 {
            try? fm.removeItem(at: engine.addonDir)
            try? fm.moveItem(at: old, to: engine.addonDir)
            _ = try? await engine.reload()
            d.set(remote, forKey: "updater.bad")
            return .failed("Aggiornamento non compatibile: mantengo le sorgenti locali")
        }
        try? fm.removeItem(at: old)
        NxLog.i("NxUpdater", "updated to \(remote.take(7)) (\(res["files"].int) files, \(ok) channels)")
        return .updated(remote)
    }
}

/// The bridge between the two worlds: a live programme the guide recognised (TMDB id in `programme_meta`) and the same
/// title on Stream4Me. Live → VOD: "Guarda dall'inizio" (the film, or this very episode), the whole series, similar titles.
/// VOD → live: where and when the title is on TV in the next days.
final class LiveVodMatcher {
    struct Link { let media: String; let id: Int; let season: Int; let episode: Int; let available: Bool; let similar: [TmdbTitle] }

    private let db: AppDB
    private let catalog: CatalogRepository
    private let channels: ChannelRepository
    private let meta: MetaRepository
    private static let ep = Rx.i(#"S(\d+)\s*E(\d+)"#)

    init(db: AppDB, catalog: CatalogRepository, channels: ChannelRepository, meta: MetaRepository) { self.db = db; self.catalog = catalog; self.channels = channels; self.meta = meta }

    /// TMDB identity of a live programme, when the guide recognised a film or a series.
    func tmdbOf(_ m: ProgrammeMetaEntity?) -> (String, Int)? {
        guard let m = m, m.found, m.tmdbId > 0, m.media == "movie" || m.media == "tv" else { return nil }
        return (m.media, m.tmdbId)
    }
    /// "S2 E5" → (2, 5).
    func episodeOf(_ p: ProgrammeEntity?) -> (Int, Int)? {
        guard let e = p?.episode, let m = LiveVodMatcher.ep.find(e), let s = Int(m[1]), let n = Int(m[2]) else { return nil }
        return (s, n)
    }
    /// A Stream4Me miss is remembered a week; anything else is worth a try (the player resolves and says so if it fails).
    func maybeAvailable(_ media: String, _ id: Int) -> Bool {
        guard let v = db.vodIndex(id, media) else { return true }
        return v.available || Clock.now - v.checkedAt > 7 * Clock.day
    }
    /// Everything the programme page needs to offer the VOD side, or nil when the title is not a film / series.
    func linkFor(_ m: ProgrammeMetaEntity?, _ p: ProgrammeEntity?, kids: Bool) async -> Link? {
        guard let (media, id) = tmdbOf(m) else { return nil }
        let se = media == "tv" ? (episodeOf(p) ?? (1, 1)) : (0, 0)
        let similar = await catalog.similar(media, id, kids)
        return Link(media: media, id: id, season: se.0, episode: se.1, available: maybeAvailable(media, id), similar: similar)
    }
    /// "Guarda dall'inizio": the film from 0, or the episode on air (the guide's S/E) through Stream4Me.
    func watchFromStart(_ link: Link, _ p: ProgrammeEntity?) async throws -> PlayRequest {
        let d = try await catalog.details(link.media, link.id)
        return link.media == "movie" ? PlayRequest(details: d, startMs: 0) : PlayRequest(details: d, season: link.season, episode: link.episode, episodeTitle: p?.subtitle, startMs: 0)
    }
    /// Where a VOD title is on TV: airings on the viewer's channels from half an hour ago to `hours` ahead, soonest first.
    func airingsOf(_ media: String, _ id: Int, hours: Int = 72, limit: Int = 12) -> [Showing] {
        let keys = Set(db.metaKeysFor(id, media))
        if keys.isEmpty { return [] }
        let now = Clock.now
        var byEpg = [String: ChannelEntity]()
        for c in channels.visible() where c.shiftMin == 0 { if let e = c.epgId, byEpg[e] == nil { byEpg[e] = c } }
        var out = [Showing](); var seen = Set<String>()
        for p in db.allProgrammesBetween(now - 30 * Clock.minute, now + Millis(hours) * Clock.hour).sortedBy({ $0.start }) {
            let k = meta.keyOf(p)
            guard keys.contains(k), let c = byEpg[p.epgId], channels.allowedProgramme(c, p), seen.insert("\(c.streamId)\(p.start)").inserted else { continue }
            let m = meta.get(k)
            out.append(Showing(channel: c, programme: p, meta: (m?.found ?? false) ? m : nil))
            if out.count >= limit { break }
        }
        return out
    }
}
