import Foundation

/// What kind of thing a programme is, from the EPG category, the channel genre and the title.
enum ProgKind: String { case movie, series, sport, other }

/// Dresses live programmes with TMDB metadata (logo, backdrop, overview, cast, rating) the way the VOD side does.
/// A programme is looked up by a key made of its cleaned title (+ year when the EPG has one); hits and misses are cached
/// in the database so the guide only ever costs one lookup per title.
final class MetaRepository {
    private let db: AppDB
    private let tmdb: TmdbApi
    private let lock = NSLock()
    private var inFlight = Set<String>()
    /// Mean luminance (0…1) of the opaque pixels of an image, set by the platform layer (needs an image decoder).
    static var logoLuminance: ((Data) -> Double?)?

    init(db: AppDB, tmdb: TmdbApi) { self.db = db; self.tmdb = tmdb }

    func allFound() -> [String: ProgrammeMetaEntity] { Dictionary(db.foundMetas().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }) }
    func get(_ key: String) -> ProgrammeMetaEntity? { db.programmeMeta(key) }

    private static let seRx = Rx(#"\bs\d+\s*e\d+\b"#)
    private static let newsy = Rx.i(#"\b(tg\d?|telegiornale|notiziario|meteo|news|edizione|rassegna|oroscopo|televendita)\b"#)

    func kindOf(_ p: ProgrammeEntity, _ c: ChannelEntity?) -> ProgKind {
        // a "film" that lasts 10 minutes is a cartoon episode, whatever the feed says
        let short = p.stop - p.start < 40 * Clock.minute
        // the broadcaster guides say what a programme is (Sky: /film/, /serie-tv/, /sport/…): trust them first
        switch p.kind {
        case "movie": return short ? ((c?.categoryId == "kids" || p.episode != nil) ? .series : .other) : .movie
        case "series": return .series
        case "sport": return .sport
        case "news", "show", "doc", "music": return .other
        case "kids": return (p.episode != nil || p.subtitle != nil) ? .series : .other
        default: break
        }
        let cat = (p.category ?? "").lowercased()
        let t = p.title.lowercased()
        if MetaRepository.sportCats.contains(cat) || (c?.categoryId == "sport" && cat.isEmpty) || c?.categoryId == "events" { return .sport }
        if MetaRepository.seriesCats.contains(cat) { return .series }
        if MetaRepository.movieCats.contains(cat) { return (p.episode != nil && !cat.hasPrefix("film") && cat != "cinema") ? .series : .movie }
        if cat.isEmpty && c?.categoryId == "cinema" { return p.episode != nil ? .series : .movie }
        if MetaRepository.noCats.contains(cat) { return .other }
        if p.episode != nil && (c?.categoryId == "entertainment" || c?.categoryId == "kids") { return .series }
        if t.contains(" - ep") || MetaRepository.seRx.contains(t) { return .series }
        return .other
    }

    /// Programmes worth a TMDB lookup: films and series. Talk shows, news and sport are not on TMDB in a useful way.
    func wantsMeta(_ p: ProgrammeEntity, _ c: ChannelEntity?) -> Bool {
        switch kindOf(p, c) {
        case .movie, .series: return true
        // shows / documentaries / kids without artwork: TMDB knows many of them as "tv" (exact title only, see lookup)
        case .other: return p.icon == nil && p.kind != "news" && titleOf(p).count >= 4 && !MetaRepository.newsy.contains(p.title)
        case .sport: return false
        }
    }

    func keyOf(_ p: ProgrammeEntity) -> String { titleOf(p).lowercased() + "|" + String(p.kind == "series" ? 0 : (p.year ?? 0)) }
    /// Best title to recognise a programme by: the source's clean show name, else our cleaned EPG title.
    func titleOf(_ p: ProgrammeEntity) -> String { MetaRepository.cleanTitle(p.show?.nilIfBlank ?? p.title) }

    /// Fetch (or return cached) metadata for a programme. Never throws; nil when unknown.
    @discardableResult
    func enrich(_ p: ProgrammeEntity, _ c: ChannelEntity?) async -> ProgrammeMetaEntity? {
        if !wantsMeta(p, c) { return nil }
        let key = keyOf(p)
        if let cached = db.programmeMeta(key) { return cached.found ? cached : nil }
        lock.lock()
        let mine = inFlight.insert(key).inserted
        lock.unlock()
        if !mine { return nil }
        defer { lock.lock(); inFlight.remove(key); lock.unlock() }
        do {
            let meta = try await lookup(key, titleOf(p), p.year, kindOf(p, c))
            db.upsertProgrammeMeta(meta)
            return meta.found ? meta : nil
        } catch {
            NxLog.w("NxMeta", "lookup failed for '\(p.title)': \(error)")
            return nil
        }
    }

    private func lookup(_ key: String, _ title: String, _ year: Int?, _ kind: ProgKind) async throws -> ProgrammeMetaEntity {
        let miss = ProgrammeMetaEntity(key: key, found: false, fetchedAt: Clock.now)
        if title.count < 2 { return miss }
        let primary = (kind == .series || kind == .other) ? "tv" : "movie"
        // the EPG "date" is the production year of the film, but of the *episode* for series: use it for films only
        let y: Int? = kind == .series ? nil : year
        var results = try await tmdb.searchKind(primary, title, year: y)
        if results.isEmpty && y != nil { results = try await tmdb.searchKind(primary, title) }
        if results.isEmpty { results = try await tmdb.searchKind("multi", title) }
        var best = MetaRepository.pick(title, y, results, exactOnly: kind == .other)
        if best == nil && kind == .other { return miss }
        if best == nil && title.contains(" - ") {   // "Face/Off - Due facce di un assassino" -> try the part before the dash
            let short = title.substringBefore(" - ").trimmed
            if short.count >= 3 { best = MetaRepository.pick(short, y, try await tmdb.searchKind(primary, short, year: y)) }
        }
        guard let b = best else { return miss }
        let media = b.mediaType ?? primary
        let d = try await tmdb.details(media, b.tmdbId)
        if kind == .other && d.bestBackdrop == nil { return miss }
        let castNames = (d.credits?.cast ?? []).sortedBy { $0.order ?? 99 }.prefix(8).map { $0.name }.joined(separator: ", ")
        return ProgrammeMetaEntity(
            key: key, found: true, fetchedAt: Clock.now, tmdbId: d.id, media: kind == .other ? "show" : media, title: d.displayTitle,
            overview: d.overview?.nilIfBlank, tagline: d.tagline?.nilIfBlank, backdrop: Img.tmdb(d.bestBackdrop, "w1280"), poster: Img.tmdb(d.posterPath, "w342"),
            logo: await brightLogo(d.logoPaths), cast: castNames, genres: d.genres.map { $0.name }.joined(separator: ", "), vote: d.voteAverage, popularity: d.popularity,
            year: d.year, runtime: d.runtimeMin, seasons: d.numberOfSeasons, episodes: d.numberOfEpisodes)
    }

    /// The title logo sits on dark artwork: a black or dark-red logo would vanish. Try the first few candidates at small size
    /// and keep the first one whose opaque pixels are bright enough; nil = show the title as text.
    private func brightLogo(_ paths: [String]) async -> String? {
        guard let measure = MetaRepository.logoLuminance else { return paths.first.flatMap { Img.tmdb($0, "w500") } }
        for path in paths.prefix(4) {
            guard let url = Img.tmdb(path, "w185"), let data = try? await Http.data(url), let lum = measure(data) else { continue }
            if lum >= 0.42 { return Img.tmdb(path, "w500") }
        }
        return nil
    }

    /// TMDB weekly trending for Italy (films + series, ~120 titles), refreshed once a day: feeds the "di tendenza" ranking.
    func refreshTrending(force: Bool = false) async {
        if !force && Clock.now - db.trendingAt() < 20 * Clock.hour { return }
        var items = [TmdbTitle]()
        for page in 1...6 {
            guard let l = try? await tmdb.trending("all", window: "week", page: page, region: true) else { continue }
            items += l.filter { !$0.adult && ($0.mediaType == "movie" || $0.mediaType == "tv") }
        }
        items = items.distinct { "\($0.media):\($0.tmdbId)" }
        if items.isEmpty { return }
        let now = Clock.now
        db.replaceTrending(items.enumerated().map { TrendingEntity(id: "\($1.media):\($1.tmdbId)", rank: $0 + 1, fetchedAt: now) })
        NxLog.i("NxMeta", "trending: \(items.count) titles")
    }

    /// Exact-ish title match (accents/case/punctuation-insensitive), year ±1 when known, then popularity.
    private static func pick(_ title: String, _ year: Int?, _ results: [TmdbTitle], exactOnly: Bool = false) -> TmdbTitle? {
        let want = MetaText.norm(title)
        func score(_ r: TmdbTitle) -> Double {
            let a = MetaText.norm(r.displayTitle), b = MetaText.norm(r.originalDisplayTitle)
            let exact = a == want || b == want
            let starts = a.hasPrefix(want) || want.hasPrefix(a) || b.hasPrefix(want)
            let tok = max(jaccard(want, a), jaccard(want, b))
            var s: Double = exact ? 3 : (starts && tok >= 0.5 ? 2 : (tok >= 0.6 ? 1 : 0))
            if s == 0 { return 0 }
            if let y = year, y > 0, r.year > 0 { s += abs(r.year - y) <= 1 ? 1.0 : -1.5 }
            s += min(r.popularity, 100) / 100 + (r.votes > 50 ? 0.3 : 0)
            return s
        }
        let floor: Double = exactOnly ? 3 : 1
        var best: TmdbTitle? = nil; var bestScore = -1.0
        for r in results { let sc = score(r); if sc >= floor && sc > bestScore { best = r; bestScore = sc } }
        return best
    }

    static let movieCats: Set<String> = ["film", "cinema", "commedia", "drammatico", "azione", "thriller", "avventura", "animazione", "poliziesco", "sentimentale", "horror", "fantascienza", "fantasy", "western", "giallo", "biografico", "storico", "guerra", "musical", "anime"]
    static let seriesCats: Set<String> = ["serie tv", "fiction", "telefilm", "sit com", "sit-com", "sitcom", "soap opera", "soap", "serie", "miniserie", "telenovela"]
    static let sportCats: Set<String> = ["sport", "calcio", "tennis", "basket", "motori", "golf", "equestri", "ciclismo", "rugby", "pallavolo", "volley", "formula 1", "motogp", "boxe", "atletica", "nuoto", "sci", "wrestling", "football americano", "baseball", "hockey"]
    static let noCats: Set<String> = ["informazione", "notiziario", "news", "telegiornale", "intrattenimento", "show", "talk show", "gioco", "reality show", "magazine", "attualita", "economia", "societa", "cucina", "lifestyle", "musica", "ragazzi e musica", "cartoni animati", "per i bimbi piccoli", "bambini", "documentario", "mondo e tendenze", "altri", "altro", "altri programmi", "educativo", "educational", "arte e cultura", "scoperta e avventura", "caccia", "pesca", "natura", "storia", "meteo", "religione", "televendita"]

    private static let junk: [Rx] = [
        Rx.i(#"\s*[-–:]\s*(1|2|3)[ªa^°]?\s*(tv|visione)\b.*$"#),
        Rx.i(#"\s*\(?\b(prima|1[ªa^°])\s*tv\)?"#),
        Rx.i(#"\s*[-–]\s*(ep\.?|episodio|puntata|parte|pt\.?)\s*\d+.*$"#),
        Rx.i(#"\s*\b(ep\.?|episodio)\s*\d+\b.*$"#),
        Rx.i(#"\s*\bs\d+\s*e\d+\b.*$"#),
        Rx(#"\s*\(\d{4}\)\s*$"#),
        Rx.i(#"\s*\((edizione|versione|director|extended|restaur|rimaster|cut|v\.?o\.?|sub|hd|4k)[^)]*\)"#),
        Rx.i(#"\s*[-–:]\s*(director'?s cut|versione integrale|edizione (speciale|deluxe|restaurata)|extended (cut|edition)|final cut|the final cut)\s*$"#),
        Rx(#"\s+:\s+.*$"#),   // "Blade Runner : Director's Cut" (loose colon = provider's subtitle)
        Rx.i(#"^\s*(speciale|film|serie)\s*:\s*"#),
        Rx(#"\s*\.\.\.\s*$"#),
    ]
    private static let multiSpace = Rx(#"\s{2,}"#)

    static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmed
        for r in junk { s = r.replace(s, "") }
        return multiSpace.replace(s, " ").trimmed.trimmingEnd("-:–").trimmed
    }

    private static func jaccard(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        if x.isEmpty || y.isEmpty { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
