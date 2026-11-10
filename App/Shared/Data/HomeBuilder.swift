import Foundation

/// What sits on top of a poster: progress, an episode label, a "Nuovo" badge.
struct CardOverlay: Hashable {
    var progress: Double? = nil
    var label: String? = nil
    var badge: String? = nil
}

enum HomeRow: Identifiable {
    case shows(id: String, title: String, items: [Showing], wide: Bool, sub: String?)
    case channels(id: String, title: String, items: [ChannelEntity])
    /// On-demand row (TMDB titles through Stream4Me).
    case vod(id: String, title: String, row: VodRow, overlays: [String: CardOverlay], sub: String?, tag: String?)

    var id: String {
        switch self {
        case .shows(let id, _, _, _, _): return id
        case .channels(let id, _, _): return id
        case .vod(let id, _, _, _, _, _): return id
        }
    }
}

/// One slide of the carousel: a live programme or an on-demand title.
enum HeroItem: Identifiable {
    case live(Showing)
    case vod(TmdbTitle, TmdbDetails?)
    var id: String {
        switch self {
        case .live(let s): return "l-" + s.key
        case .vod(let t, _): return "v-" + t.key
        }
    }
}

struct HomeState {
    var carousel: [HeroItem] = []
    var rows: [HomeRow] = []
    /// True while the first rows are still being built (a loader instead of an empty message).
    var loading = true
}

/// The on-demand half of the Home, loaded once per profile.
struct VodData {
    var continueRow: HomeRow? = nil
    var forYou: HomeRow? = nil
    var top10Movie: HomeRow? = nil
    var top10Tv: HomeRow? = nil
    var fresh: HomeRow? = nil
    var heroes: [HeroItem] = []
}

/// The ranking itself, off the main thread on a snapshot of the data.
struct HomeBuilder {
    let core: NexCore
    let all: [ChannelEntity]
    let now: [String: ProgrammeEntity]
    let metas: [String: ProgrammeMetaEntity]
    let vod: VodData
    let syncing: Bool

    private struct Scored { let s: Showing; let kind: ProgKind; let score: Double; let sportWeight: Int }
    private struct Taste { let profile: UsageRepository.Profile; let trending: [String: Int] }

    static let sportHeadline: Set<String> = ["Sky Sport Uno", "Sky Sport Calcio", "DAZN 1", "DAZN 2", "Rai 1", "Rai 2", "TV8", "Italia 1", "Canale 5"]
    /// Event weight from which a sport event may reach the carousel and "Di tendenza".
    static let big = 80
    /// Sports that never make the front page, whatever words their titles contain.
    static let minor = Rx.i(#"\b(longines|equestr|horse|salto|golf|curling|table tennis|ping pong|fighting|mma|snooker|darts|freccette|padel|women|femminile|frauen|youth|giovanili|primavera|under ?\d+|u\d\d|esports|e-sports|challenger|utr|ncaa|college|paddock|magazine|show|rubrica|studio|anteprima|highlights|sintesi|notizie|news|replica|best of|football night|pre ?partita|post ?partita)\b"#)
    static let bigEvents: [(Rx, Int)] = [
        (#"\b(champions league|uefa champions)\b"#, 120),
        (#"\b(italia)\s*[-–]|[-–]\s*(italia)\b|\bnazionale\b|\bazzurr"#, 130),
        (#"\b(mondiali|world cup|europei|euro 20\d\d)\b"#, 110),
        (#"\bserie a\b(?!\s*(women|femminile|2|basket))"#, 100),
        (#"\bcoppa italia\b"#, 80), (#"\beuropa league\b"#, 80), (#"\bconference league\b"#, 60), (#"\bpremier league\b"#, 70),
        (#"\b(laliga|la liga)\b"#, 60), (#"\bbundesliga\b"#, 60), (#"\bligue 1\b"#, 50),
        (#"\b(formula 1|f1|gran premio|grand prix|gp d[i'])\b"#, 110), (#"\bmotogp\b"#, 110),
        (#"\b(wimbledon|roland garros|us open|australian open|atp finals|masters 1000|davis cup|coppa davis|finals)\b"#, 90),
        (#"\bnba\b"#, 60), (#"\b(euroleague|eurolega)\b"#, 50), (#"\b(superlega|serie a1)\b"#, 30), (#"\b(supercoppa)\b"#, 90), (#"\b(derby)\b"#, 20),
    ].map { (Rx.i($0.0), $0.1) }
    private static let versus = Rx(#"\s-\s|\svs\.?\s"#)

    private func showing(_ c: ChannelEntity, _ p: ProgrammeEntity?) -> Showing { Showing(channel: c, programme: p, meta: p.flatMap { metas[core.meta.keyOf($0)] }) }
    private func hour(_ ms: Millis? = nil) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: ms.map { Date(ms: $0) } ?? Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    func build() -> HomeState {
        let vodRows = [vod.continueRow, vod.forYou, vod.top10Movie, vod.top10Tv, vod.fresh].compactMap { $0 }
        if all.isEmpty { return HomeState(carousel: vod.heroes, rows: vodRows, loading: syncing || (vodRows.isEmpty && vod.heroes.isEmpty)) }
        let t = Clock.now
        let taste = Taste(profile: core.usage.profile(), trending: core.db.trending())
        func live(_ c: ChannelEntity) -> Showing { showing(c, c.epgId.flatMap { now[$0] }) }

        let scored = rank(taste, t)
        // the front page (carousel + "Di tendenza"): films and series, plus the big sport events only
        let withArt = scored.filter { $0.s.image != nil && ($0.kind != .sport || $0.sportWeight >= HomeBuilder.big) }
        // carousel: the 7 hottest things with artwork, at most 2 sport, no duplicate titles
        var carousel = [Showing](); var sport = 0
        for x in withArt {
            if x.kind == .sport { if sport >= 2 { continue }; sport += 1 }
            if !carousel.contains(where: { $0.title == x.s.title }) { carousel.append(x.s) }
            if carousel.count >= 7 { break }
        }
        // the profile's teams: a match on air leads the carousel and the sport row
        let teamMatches = core.teams.upcomingForCurrent()
        let teamNames = core.teams.followed().map { $0.name }
        let teamShows = teamMatches.map { showing($0.showing.channel, $0.showing.programme) }.filter { core.channels.allowedProgramme($0.channel, $0.programme) }
        let teamLive = teamShows.filter { $0.isLive(t) }
        for x in teamLive.reversed() { carousel.removeAll { $0.title == x.title }; carousel.insert(x, at: 0) }
        if carousel.count > 7 { carousel = Array(carousel.prefix(7)) }
        let inCarousel = Set(carousel.map { $0.key })
        var rows = [HomeRow]()

        let trend = Array(withArt.filter { !inCarousel.contains($0.s.key) }.distinct { $0.s.title }.prefix(16)).map { $0.s }
        if !trend.isEmpty { rows.append(.shows(id: "trend", title: "Di tendenza ora", items: trend, wide: true, sub: "in onda e tra poco")) }
        if !teamShows.isEmpty { rows.append(.shows(id: "teams", title: "Le tue squadre", items: Array(teamShows.prefix(12)), wide: true, sub: teamNames.prefix(3).joined(separator: ", "))) }

        let pr = taste.profile
        if !pr.isEmpty {
            let forYou = scored.filter { $0.s.image != nil && affinity($0, pr) > 0.15 }.sortedByDescending { affinity($0, pr) * 100 + $0.score * 0.2 }.distinct { $0.s.title }.prefix(14).map { $0.s }
            if forYou.count >= 3 { rows.append(.shows(id: "foryou", title: "Scelti per te", items: Array(forYou), wide: false, sub: "in base a cosa guardi")) }
        }
        let favs = core.channels.favorites()
        if !favs.isEmpty { rows.append(.channels(id: "fav", title: "I tuoi canali preferiti", items: favs)) }

        let films = scored.filter { $0.kind == .movie && $0.s.isLive(t) }.distinct { $0.s.title }.prefix(16).map { $0.s }
        if !films.isEmpty { rows.append(.shows(id: "films", title: "Film in onda", items: Array(films), wide: true, sub: nil)) }
        let sportRow = (teamLive + scored.filter { $0.kind == .sport && $0.sportWeight > 0 }.map { $0.s }).distinct { $0.title }.prefix(14)
        if !sportRow.isEmpty { rows.append(.shows(id: "sport", title: "Sport in diretta", items: Array(sportRow), wide: true, sub: nil)) }
        let series = scored.filter { $0.kind == .series && $0.s.isLive(t) }.distinct { $0.s.title }.prefix(16).map { $0.s }
        if !series.isEmpty { rows.append(.shows(id: "series", title: "Serie TV in onda", items: Array(series), wide: true, sub: nil)) }

        let recents = core.channels.recents()
        if !recents.isEmpty { rows.append(.channels(id: "recent", title: "Guardati di recente", items: recents)) }

        let main = all.filter { (1...99).contains($0.num) && $0.shiftMin == 0 && $0.epgId.flatMap { now[$0] } != nil }.sortedBy { $0.num }.prefix(24).map { live($0) }
        if !main.isEmpty { rows.append(.shows(id: "now", title: "Adesso sui canali principali", items: Array(main), wide: false, sub: nil)) }

        var byEpg = [String: ChannelEntity]()
        for c in all where c.shiftMin == 0 { if let e = c.epgId, byEpg[e] == nil { byEpg[e] = c } }
        let soonProgs = core.db.allProgrammesBetween(t, t + 75 * Clock.minute).filter { $0.start > t }
        let soon = soonProgs.compactMap { p in byEpg[p.epgId].map { showing($0, p) } }
            .filter { $0.image != nil && core.channels.allowedProgramme($0.channel, $0.programme) }.sortedByDescending { quickScore($0, taste) }.distinct { $0.title }.prefix(14)
        if !soon.isEmpty { rows.append(.shows(id: "soon", title: "Tra poco", items: Array(soon), wide: false, sub: "nei prossimi 75 minuti")) }

        let tonightAt = NexCore.tonightAt(graceMinutes: 105)
        var tonightMap = [String: ProgrammeEntity]()
        for p in core.db.programmesAt(tonightAt) { tonightMap[p.epgId] = p }
        let tonightChans = all.filter { $0.shiftMin == 0 && ((1...60).contains($0.num) || $0.categoryId == "cinema" || $0.categoryId == "entertainment") }
        var tonight = [Showing]()
        for c in tonightChans { if let e = c.epgId, let p = tonightMap[e] { tonight.append(showing(c, p)) } }
        tonight = tonight.filter { ($0.stop ?? 0) - ($0.start ?? 0) >= 50 * Clock.minute && core.channels.allowedProgramme($0.channel, $0.programme) }
            .sorted { a, b in let qa = quickScore(a, taste), qb = quickScore(b, taste); return qa == qb ? a.channel.num < b.channel.num : qa > qb }
        tonight = Array(tonight.distinct { $0.title }.prefix(18))
        if !tonight.isEmpty { rows.append(.shows(id: "tonight", title: tonightAt - t > 20 * Clock.hour ? "Domani sera in TV" : "Stasera in TV", items: tonight, wide: false, sub: "prima serata")) }

        let byGenre = all.filter { $0.shiftMin == 0 }.grouped { $0.categoryId }
        let genres = ChannelCatalog.genres.filter { !(byGenre[$0.id] ?? []).isEmpty }.sortedByDescending { pr.isEmpty ? 0.0 : pr.genre($0.id) }
        for g in genres { rows.append(.channels(id: "cat-\(g.id)", title: g.label, items: byGenre[g.id] ?? [])) }

        // ---- the mix: prime time or a big live event put the live side first; the rest of the day what you were watching on demand comes first
        let h = hour()
        let bigLive = scored.contains { $0.kind == .sport && $0.sportWeight >= HomeBuilder.big && $0.s.isLive(t) }
        let evening = (h >= 20 && h <= 23.5) || bigLive
        // a match of your teams on air or starting within 3 hours puts "Le tue squadre" first
        let teamsFirst = teamShows.contains { ($0.start ?? Millis.max) - t < 3 * Clock.hour }
        return HomeState(carousel: mixCarousel(carousel, vod.heroes, evening), rows: orderRows(rows, vodRows, evening, teamsFirst), loading: false)
    }

    private func mixCarousel(_ live: [Showing], _ vodHeroes: [HeroItem], _ evening: Bool) -> [HeroItem] {
        var out = [HeroItem](); var li = 0, vi = 0
        let liveRun = evening ? 2 : 1
        while li < live.count || vi < vodHeroes.count {
            if !evening && vi < vodHeroes.count { out.append(vodHeroes[vi]); vi += 1 }
            for _ in 0..<liveRun where li < live.count { out.append(.live(live[li])); li += 1 }
            if evening && vi < vodHeroes.count { out.append(vodHeroes[vi]); vi += 1 }
        }
        return Array(out.prefix(9))
    }

    private func orderRows(_ live: [HomeRow], _ vodRows: [HomeRow], _ evening: Bool, _ teamsFirst: Bool) -> [HomeRow] {
        var byId = [String: HomeRow]()
        for r in live + vodRows { byId[r.id] = r }
        let base = evening
            ? ["trend", "vod-continue", "films", "sport", "series", "foryou", "vod-foryou", "fav", "vod-top10tv", "vod-top10movie", "recent", "now", "soon", "tonight", "vod-new"]
            : ["vod-continue", "vod-foryou", "trend", "vod-top10movie", "vod-top10tv", "foryou", "films", "sport", "series", "vod-new", "fav", "recent", "now", "soon", "tonight"]
        // "Le tue squadre": first when a match is close, otherwise right after the first row
        let order = teamsFirst ? ["teams"] + base : [base[0], "teams"] + Array(base.dropFirst())
        var out = order.compactMap { byId[$0] }
        out += live.filter { $0.id.hasPrefix("cat-") }
        return out
    }

    private func affinity(_ x: Scored, _ p: UsageRepository.Profile) -> Double {
        p.channel(x.s.channel.streamId) * 0.5 + p.genre(x.s.channel.categoryId) * 0.2 + p.kind(x.kind.rawValue) * 0.15 + (x.s.meta.map { p.tmdbGenres($0.genres) } ?? 0) * 0.25
    }

    /// Cheap score for programmes outside the main ranking (tonight, soon).
    private func quickScore(_ s: Showing, _ t: Taste) -> Double {
        var v = 0.0
        if let m = s.meta {
            v += min(m.popularity, 150) * 0.5 + m.vote * 3
            if let r = t.trending["\(m.media):\(m.tmdbId)"] { v += 120.0 * (1 - Double(r) / 130.0) }
        }
        if s.firstRun { v += 30 }
        if s.highlight { v += 25 }
        if (1...9).contains(s.channel.num) { v += 18 }
        v += t.profile.channel(s.channel.streamId) * 40 + t.profile.genre(s.channel.categoryId) * 15
        return v
    }

    /// "Di tendenza": everything on air now (or starting within 30 min) scored by — TMDB weekly trending rank, TMDB popularity
    /// and rating, Sky's editorial highlights, first runs, big sport events, the generalist channels' prime time — plus a bonus
    /// from the on-device viewing profile, so the mix drifts towards what is watched here.
    private func rank(_ taste: Taste, _ t: Millis) -> [Scored] {
        let h = hour()
        // artwork for event channels (DAZN & co.): the same match in another channel's EPG (Sky / DAZN feeds carry stills)
        var artByMatch = [String: ProgrammeEntity]()
        for p in now.values where p.icon != nil { let k = MetaText.norm(p.title); if artByMatch[k] == nil { artByMatch[k] = p } }
        var out = [Scored]()
        for c in all {
            if c.shiftMin > 0 { continue }
            var p = c.epgId.flatMap { now[$0] }
            if let cur = p, cur.icon == nil, let art = artByMatch[MetaText.norm(cur.title)] {
                // same match at the same time on a Sky channel: take its still, and its live / replay flag
                let same = art.src == "sky" && abs(art.start - cur.start) <= 20 * Clock.minute
                var x = cur; x.icon = art.icon; x.desc = cur.desc ?? art.desc; x.kind = cur.kind ?? art.kind
                if same { x.live = art.live; x.src = art.src }
                p = x
            }
            if p == nil, let ev = c.event, let art = artByMatch[MetaText.norm(ev)] {
                var x = art
                x.id = -Int64(abs(c.streamId.hashValue % 1_000_000_000)) - 1
                x.epgId = c.epgId ?? ""; x.start = c.eventStart ?? art.start; x.stop = (c.eventStart ?? art.start) + (art.stop - art.start); x.title = ev
                p = x
            }
            if p == nil && c.event == nil { continue }
            let s = showing(c, p)
            let startsSoon = (s.start ?? 0) > t && (s.start ?? 0) <= t + 30 * Clock.minute
            if !s.isLive(t) && !startsSoon { continue }
            let kind: ProgKind
            if s.meta?.media == "movie" { kind = .movie }          // TMDB knows best what it recognised
            else if s.meta?.media == "tv" { kind = .series }
            else if let pp = p, pp.id >= 0 { kind = core.meta.kindOf(pp, c) }
            else { kind = .sport }
            var score = 0.0; var sw = 0
            switch kind {
            case .sport:
                if !s.isReplay {
                    let text = [s.title, s.sub, c.eventSub, p?.category, p?.subtitle, p?.desc.map { $0.take(160) }].compactMap { $0 }.joined(separator: " ").lowercased()
                    sw = eventWeight(text, c)
                    // films and series lead the front page; sport reaches it only for the big events. Everything else lives in "Sport in diretta".
                    if sw >= HomeBuilder.big { score = 80.0 + Double(sw) * 0.35 + (c.categoryId == "sport" ? 3 : 0) }
                    else if sw > 0 { score = 20.0 + Double(sw) * 0.2 }
                }
            case .movie, .series:
                if let m = s.meta {
                    score = 90.0 + min(m.popularity, 150) * 0.5 + m.vote * 4 + (c.categoryId == "cinema" ? 8 : 0) + ((1...9).contains(c.num) ? 15 : 0)
                    if let r = taste.trending["\(m.media):\(m.tmdbId)"] { score += 110.0 * (1 - Double(r) / 130.0) }
                } else if p?.src == "sky" && s.image != nil { score = 60.0 + ((1...9).contains(c.num) ? 15 : 0) }
            case .other: break
            }
            if s.firstRun { score += score > 0 ? 30 : 70 }
            if s.highlight { score += score > 0 ? 25 : 65 }
            // prime time on the generalist channels (from 20:00): the evening's main programme
            if let pp = p, (1...9).contains(c.num), h >= 20 {
                let sh = hour(pp.start)
                if sh >= 20.3 && sh <= 21.9 && pp.stop - pp.start >= Clock.hour {
                    score = max(score, 95.0 + Double(10 - c.num) * 4 + (s.meta.map { min($0.popularity, 100) * 0.3 } ?? 0))
                }
            }
            if score <= 0 { continue }
            if startsSoon { score -= 15 }
            // what this device watches: up to +60
            let pr = taste.profile
            if !pr.isEmpty { score += pr.channel(c.streamId) * 30 + pr.genre(c.categoryId) * 10 + pr.kind(kind.rawValue) * 10 + (s.meta.map { pr.tmdbGenres($0.genres) } ?? 0) * 10 }
            out.append(Scored(s: s, kind: kind, score: score, sportWeight: sw))
        }
        return out.sortedByDescending { $0.score }
    }

    private func eventWeight(_ text: String, _ c: ChannelEntity) -> Int {
        if HomeBuilder.minor.contains(text) { return 0 }
        var best = 0
        for (re, w) in HomeBuilder.bigEvents where re.contains(text) { best = max(best, w) }
        if best == 0 && HomeBuilder.sportHeadline.contains(c.name) && HomeBuilder.versus.contains(text) { best = 40 }
        return best
    }
}
