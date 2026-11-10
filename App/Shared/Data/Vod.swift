import Foundation

// The on-demand side: TMDB catalogue rows, per-profile library, on-device recommender, search index.

enum RowKind { case poster, landscape, top10, `continue` }

/// How a row fetches further pages (endless rows). kind: popular, top_rated, trending, now_playing, on_the_air, upcoming, discover.
struct RowSource: Hashable {
    var kind: String
    var media: String
    var params: [[String]] = []
    var pairs: [(String, String)] { params.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
    static func discover(_ media: String, _ p: [(String, String)]) -> RowSource { RowSource(kind: "discover", media: media, params: p.map { [$0.0, $0.1] }) }
}

struct VodRow: Identifiable, Hashable {
    var id: String
    var title: String
    var items: [TmdbTitle]
    var kind: RowKind = .poster
    var reason: String? = nil
    var source: RowSource? = nil
}

/// A row that can be built on demand while the page scrolls down.
struct Recipe: Hashable { var id: String; var title: String; var source: RowSource; var kind: RowKind = .poster }

/// On-device index of the ~1500 most popular movies and series so that search works like Netflix: "bre" already shows
/// Breaking Bad. TMDB's search endpoint only matches whole words, so it is used as a complement for the long tail.
/// Built in the background once a day and persisted as JSON; fully local, no account.
final class SearchIndex {
    struct Entry { let title: TmdbTitle; let keys: [String] }
    struct Scored { let title: TmdbTitle; let score: Double }

    private let tmdb: TmdbApi
    private let file: URL
    private let mutex = AsyncLock()
    private let lock = NSLock()
    private var _entries = [Entry]()
    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return _entries }
    var ready: Bool { !entries.isEmpty }
    private static let refreshMs: Millis = 24 * Clock.hour

    init(tmdb: TmdbApi, dir: URL) { self.tmdb = tmdb; file = dir.appendingPathComponent("search_index.json") }

    private var fileAge: Millis {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return Millis.max }
        return Clock.now - d.ms
    }

    func ensure(force: Bool = false) async {
        await mutex.lock()
        if !force && !entries.isEmpty && fileAge < SearchIndex.refreshMs { await mutex.unlock(); return }
        if !force && entries.isEmpty, let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([TmdbTitle].self, from: d) {
            load(list)
            if !entries.isEmpty && fileAge < SearchIndex.refreshMs { await mutex.unlock(); return }
        }
        await build()
        await mutex.unlock()
    }

    private func build() async {
        var jobs = [() async -> [TmdbTitle]]()
        let t = tmdb
        for p in 1...12 { jobs.append { (try? await t.popular("movie", page: p)) ?? [] }; jobs.append { (try? await t.popular("tv", page: p)) ?? [] } }
        for p in 1...8 { jobs.append { (try? await t.topRated("movie", page: p)) ?? [] }; jobs.append { (try? await t.topRated("tv", page: p)) ?? [] } }
        for p in 1...5 { jobs.append { (try? await t.trending("all", window: "week", page: p)) ?? [] } }
        for p in 1...3 {
            jobs.append { (try? await t.discover("tv", [("with_original_language", "it"), ("sort_by", "popularity.desc")], page: p)) ?? [] }
            jobs.append { (try? await t.discover("movie", [("with_original_language", "it"), ("sort_by", "popularity.desc")], page: p)) ?? [] }
        }
        let lists = await mapConcurrent(jobs, limit: 6) { await $0() }
        let all = lists.flatMap { $0 }.filter { ($0.mediaType == "movie" || $0.mediaType == "tv") && $0.posterPath != nil && !$0.adult }.distinct { $0.key }
        if all.count < 100 { return }
        load(all)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
        NxLog.i("NxSearch", "index built: \(all.count) titles")
    }

    private func load(_ titles: [TmdbTitle]) {
        let e = titles.map { Entry(title: $0, keys: [$0.displayTitle, $0.originalDisplayTitle].map { SearchIndex.norm($0) }.distinct) }
        lock.lock(); _entries = e; lock.unlock()
    }

    /// Local matches ranked by match quality × popularity.
    func query(_ q: String, limit: Int = 40) -> [Scored] {
        let n = SearchIndex.norm(q)
        if n.isEmpty { return [] }
        var out = [Scored]()
        for e in entries {
            let m = e.keys.map { SearchIndex.matchQuality($0, n) }.max() ?? 0
            if m > 0 { out.append(Scored(title: e.title, score: m * (1.0 + log(1.0 + e.title.popularity)))) }
        }
        return Array(out.sortedByDescending { $0.score }.prefix(limit))
    }

    static func norm(_ s: String) -> String { MetaText.norm(s) }
    /// 3 = title starts with the query, 2 = a word starts with it, 1 = contained, 0 = no match.
    static func matchQuality(_ key: String, _ q: String) -> Double {
        if key.hasPrefix(q) { return 3 }
        if key.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
        // inside a word only for longer queries: "rai" must not find "Training Day" or "samurai"
        if q.count >= 5 && key.contains(q) { return 1 }
        return 0
    }
    /// Merge local and TMDB results: everything is scored the same way; TMDB-only hits keep a small floor so they still appear.
    static func rank(_ q: String, _ local: [Scored], _ remote: [TmdbTitle]) -> [TmdbTitle] {
        let n = norm(q)
        var order = [String](); var byKey = [String: Scored]()
        for s in local { if byKey[s.title.key] == nil { order.append(s.title.key) }; byKey[s.title.key] = s }
        for t in remote where byKey[t.key] == nil {
            let q0 = [t.displayTitle, t.originalDisplayTitle].map { matchQuality(norm($0), n) }.max() ?? 0
            // TMDB matches plots and alternative titles too: a short query whose letters sit inside a word is noise
            if q0 == 0 && n.count < 5 { continue }
            order.append(t.key)
            byKey[t.key] = Scored(title: t, score: max(q0, 0.5) * (1.0 + log(1.0 + t.popularity)))
        }
        return order.compactMap { byKey[$0] }.sortedByDescending { $0.score }.map { $0.title }
    }
}

/// Builds the public (non personalised) part of the pages from TMDB and caches title facts.
final class CatalogRepository {
    private let tmdb: TmdbApi
    private let db: AppDB
    /// Local popular-titles index; search works without it, just less Netflix-like.
    var index: SearchIndex?
    /// Maturity of the active profile: 0 bambini, 1 ragazzi (13+), 2 tutti.
    var maturity: Int = 2

    init(tmdb: TmdbApi, db: AppDB) { self.tmdb = tmdb; self.db = db }

    private static let kidsOk: Set<Int> = [16, 10751, 10762]
    private static let kidsNo: Set<Int> = [27, 53, 80, 10752]
    func clean(_ list: [TmdbTitle], _ kids: Bool) -> [TmdbTitle] {
        var l = list.filter { !$0.adult && $0.posterPath != nil && ($0.mediaType == "movie" || $0.mediaType == "tv") }
        if kids { l = l.filter { t in t.genreIds.contains { CatalogRepository.kidsOk.contains($0) } && !t.genreIds.contains { CatalogRepository.kidsNo.contains($0) } } }
        if !kids && maturity == 1 { l = l.filter { !$0.genreIds.contains(27) } }   // ragazzi: no horror
        return l.distinct { $0.key }
    }

    private static func isoDay(_ offsetDays: Int = 0, years: Int = 0) -> String {
        var c = DateComponents(); c.day = offsetDays; c.year = years
        let d = Calendar(identifier: .gregorian).date(byAdding: c, to: Date()) ?? Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    private static func daysAgo(_ date: String?) -> Int? {
        guard let s = date else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(s.prefix(10))) else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day
    }

    func heroCandidates(_ kids: Bool) async -> [TmdbTitle] {
        guard let l = try? await tmdb.trending("all", window: "day") else { return [] }
        return Array(clean(l, kids).filter { $0.backdropPath != nil }.prefix(8))
    }

    private func safe(_ body: () async throws -> [TmdbTitle]) async -> [TmdbTitle] { (try? await body()) ?? [] }

    func publicRows(_ kids: Bool) async -> [VodRow] {
        let t = tmdb
        let pop: [(String, String)] = [("sort_by", "popularity.desc")]
        let animeP: [(String, String)] = [("with_genres", "16"), ("with_original_language", "ja")] + pop
        let docP: [(String, String)] = [("with_genres", "99")] + pop
        let kidsP: [(String, String)] = [("with_genres", "10751,16"), ("certification_country", "IT")] + pop
        let shortP: [(String, String)] = [("with_runtime.lte", "100"), ("vote_count.gte", "300")] + pop
        var jobs = [() async -> VodRow]()
        jobs.append { VodRow(id: "top10tv", title: "Top 10 serie TV in Italia oggi", items: Array(self.clean(await self.safe { try await t.trending("tv", window: "day") }, kids).prefix(10)), kind: .top10) }
        jobs.append { VodRow(id: "top10movie", title: "Top 10 film in Italia oggi", items: Array(self.clean(await self.safe { try await t.trending("movie", window: "day") }, kids).prefix(10)), kind: .top10) }
        jobs.append {
            let l = await self.safe { try await t.nowPlaying() } + (await self.safe { try await t.onTheAir() })
            return VodRow(id: "new", title: "Novità", items: Array(self.clean(l, kids).sortedByDescending { $0.popularity }.prefix(20)), source: RowSource(kind: "now_playing", media: "movie"))
        }
        jobs.append { await self.releasesThisWeek(kids) }
        jobs.append { VodRow(id: "series", title: "Serie da divorare", items: Array(self.clean(await self.safe { try await t.popular("tv") }, kids).prefix(20)), source: RowSource(kind: "popular", media: "tv")) }
        jobs.append { VodRow(id: "movies", title: "Film del momento", items: Array(self.clean(await self.safe { try await t.popular("movie") }, kids).prefix(20)), source: RowSource(kind: "popular", media: "movie")) }
        jobs.append { VodRow(id: "anime", title: "Anime", items: Array(self.clean(await self.safe { try await t.discover("tv", animeP) }, kids).prefix(20)), source: .discover("tv", animeP)) }
        jobs.append {
            let l = await self.safe { try await t.discover("tv", docP) } + (await self.safe { try await t.discover("movie", docP) })
            return VodRow(id: "docs", title: "Documentari", items: Array(self.clean(l, kids).sortedByDescending { $0.popularity }.prefix(20)), source: .discover("movie", docP))
        }
        jobs.append {
            let l = await self.safe { try await t.topRated("movie") } + (await self.safe { try await t.topRated("tv") })
            return VodRow(id: "top_rated", title: "I più acclamati", items: Array(self.clean(l, kids).sortedByDescending { $0.vote }.prefix(20)), source: RowSource(kind: "top_rated", media: "movie"))
        }
        jobs.append { VodRow(id: "kids", title: "Per i più piccoli", items: Array(self.clean(await self.safe { try await t.discover("movie", kidsP) }, kids).prefix(20)), source: .discover("movie", kidsP)) }
        jobs.append { VodRow(id: "short", title: "Film da una sera", items: Array(self.clean(await self.safe { try await t.discover("movie", shortP) }, kids).prefix(20)), source: .discover("movie", shortP)) }
        let rows = await mapConcurrent(jobs, limit: 6) { await $0() }.filter { $0.items.count >= 4 }
        let adultOnly: Set<String> = ["docs", "top_rated", "short", "top10tv", "top10movie", "week"]
        return kids ? rows.filter { !adultOnly.contains($0.id) } : rows
    }

    /// Next page of a row (used when the viewer reaches the end of it). Empty = nothing more.
    func page(_ src: RowSource, _ page: Int, _ kids: Bool) async -> [TmdbTitle] {
        let t = tmdb
        let l: [TmdbTitle]
        switch src.kind {
        case "popular": l = await safe { try await t.popular(src.media, page: page) }
        case "top_rated": l = await safe { try await t.topRated(src.media, page: page) }
        case "trending": l = await safe { try await t.trending(src.media, window: "week", page: page) }
        case "now_playing": l = await safe { try await t.nowPlaying(page: page) }
        case "on_the_air": l = await safe { try await t.onTheAir(page: page) }
        case "upcoming": l = await safe { try await t.upcoming(page: page) }
        default: l = await safe { try await t.discover(src.media, src.pairs, page: page) }
        }
        return clean(l, kids)
    }

    /// "Prossimamente": films and series not yet released in Italy (next 90 days), soonest first.
    func upcomingRow(_ kids: Bool) async -> VodRow {
        let today = CatalogRepository.isoDay(), to = CatalogRepository.isoDay(90)
        let t = tmdb
        let l = await safe { try await t.upcoming() } + (await safe { try await t.upcoming(page: 2) })
            + (await safe { try await t.discover("tv", [("first_air_date.gte", today), ("first_air_date.lte", to), ("sort_by", "popularity.desc")]) })
        let items = clean(l, kids).filter { x in guard let d = x.date, d.count >= 10 else { return false }; return d >= today && d <= to }
            .sorted { a, b in (a.date ?? "", -a.popularity) < (b.date ?? "", -b.popularity) }
        return VodRow(id: "soon", title: "Prossimamente", items: Array(items.prefix(30)), kind: .landscape)
    }

    /// Endless pages: rows that get built while scrolling down, in a different order every day. media = nil for the mixed page.
    func recipes(tvGenres: [Int: String], movieGenres: [Int: String], kids: Bool, media: String?) -> [Recipe] {
        var out = [Recipe]()
        let kidsGenres: Set<Int> = [16, 10751, 10762, 35, 12, 14, 878]
        let pop = ("sort_by", "popularity.desc")
        for (g, n) in tvGenres.sorted(by: { $0.key < $1.key }) where !kids || kidsGenres.contains(g) {
            out.append(Recipe(id: "r-tv-\(g)", title: "Serie TV · \(n)", source: .discover("tv", [("with_genres", "\(g)"), pop, ("vote_count.gte", "50")])))
        }
        for (g, n) in movieGenres.sorted(by: { $0.key < $1.key }) where !kids || kidsGenres.contains(g) {
            out.append(Recipe(id: "r-mv-\(g)", title: "Film · \(n)", source: .discover("movie", [("with_genres", "\(g)"), pop, ("vote_count.gte", "100")])))
        }
        if !kids {
            for (from, to, label) in [(1980, 1989, "anni '80"), (1990, 1999, "anni '90"), (2000, 2009, "anni 2000"), (2010, 2019, "anni 2010")] {
                out.append(Recipe(id: "r-dec-\(from)", title: "Film \(label)", source: .discover("movie", [("primary_release_date.gte", "\(from)-01-01"), ("primary_release_date.lte", "\(to)-12-31"), pop, ("vote_count.gte", "500")])))
            }
            for (from, to, label) in [(2000, 2009, "anni 2000"), (2010, 2019, "anni 2010")] {
                out.append(Recipe(id: "r-tvdec-\(from)", title: "Serie \(label)", source: .discover("tv", [("first_air_date.gte", "\(from)-01-01"), ("first_air_date.lte", "\(to)-12-31"), pop, ("vote_count.gte", "200")])))
            }
            func d(_ id: String, _ title: String, _ media: String, _ p: [(String, String)]) { out.append(Recipe(id: id, title: title, source: .discover(media, p))) }
            d("r-it-tv", "Serie italiane", "tv", [("with_original_language", "it"), pop, ("vote_count.gte", "10")])
            d("r-it-mv", "Film italiani", "movie", [("with_original_language", "it"), pop, ("vote_count.gte", "50")])
            d("r-it-com", "Commedie italiane", "movie", [("with_original_language", "it"), ("with_genres", "35"), pop, ("vote_count.gte", "50")])
            d("r-kdrama", "K-drama", "tv", [("with_original_language", "ko"), pop, ("vote_count.gte", "50")])
            d("r-es-tv", "Serie spagnole", "tv", [("with_original_language", "es"), pop, ("vote_count.gte", "50")])
            d("r-uk-tv", "Serie britanniche", "tv", [("with_origin_country", "GB"), pop, ("vote_count.gte", "50")])
            d("r-tr-tv", "Serie turche", "tv", [("with_original_language", "tr"), pop, ("vote_count.gte", "20")])
            d("r-fr-mv", "Cinema francese", "movie", [("with_original_language", "fr"), pop, ("vote_count.gte", "200")])
            d("r-ko-mv", "Film coreani", "movie", [("with_original_language", "ko"), pop, ("vote_count.gte", "200")])
            d("r-anime-mv", "Film d'animazione giapponesi", "movie", [("with_genres", "16"), ("with_original_language", "ja"), pop, ("vote_count.gte", "100")])
            d("r-award-mv", "Film da non perdere", "movie", [("vote_average.gte", "8"), ("vote_count.gte", "3000"), ("sort_by", "vote_average.desc")])
            d("r-award-tv", "Serie acclamate dalla critica", "tv", [("vote_average.gte", "8.2"), ("vote_count.gte", "1000"), ("sort_by", "vote_average.desc")])
            d("r-mini", "Miniserie da finire in un weekend", "tv", [("with_type", "2"), pop, ("vote_count.gte", "50")])
            d("r-horror-new", "Horror recenti", "movie", [("with_genres", "27"), ("primary_release_date.gte", CatalogRepository.isoDay(0, years: -2)), pop, ("vote_count.gte", "100")])
            d("r-super", "Supereroi", "movie", [("with_keywords", "9715"), pop, ("vote_count.gte", "300")])
            d("r-zombie", "Zombie e apocalissi", "movie", [("with_keywords", "12377"), pop, ("vote_count.gte", "100")])
            d("r-spy", "Spie e agenti segreti", "movie", [("with_keywords", "470"), pop, ("vote_count.gte", "200")])
            d("r-time", "Viaggi nel tempo", "movie", [("with_keywords", "4379"), pop, ("vote_count.gte", "200")])
            d("r-true", "Tratti da storie vere", "movie", [("with_keywords", "9672"), pop, ("vote_count.gte", "300")])
            d("r-xmas", "Film di Natale", "movie", [("with_keywords", "207317"), pop, ("vote_count.gte", "50")])
            d("r-long-tv", "Serie lunghe per maratone", "tv", [pop, ("vote_count.gte", "1000"), ("first_air_date.lte", CatalogRepository.isoDay(0, years: -5))])
            out.append(Recipe(id: "r-trend-week", title: "Di tendenza questa settimana", source: RowSource(kind: "trending", media: "all")))
        }
        out.append(Recipe(id: "r-family", title: "Film per tutta la famiglia", source: .discover("movie", [("with_genres", "10751"), pop, ("vote_count.gte", "200")])))
        out.append(Recipe(id: "r-kids-tv", title: "Cartoni per i più piccoli", source: .discover("tv", [("with_genres", "10762"), pop, ("vote_count.gte", "20")])))
        let filtered = out.filter { media == nil || $0.source.media == media || $0.source.media == "all" }
        // a different order every day, the same all day
        var rng = SeededRandom(seed: UInt64(Clock.now / Clock.day))
        return filtered.shuffled(using: &rng)
    }

    func build(_ r: Recipe, _ kids: Bool) async -> VodRow {
        VodRow(id: r.id, title: r.title, items: Array(await page(r.source, 1, kids).prefix(20)), kind: r.kind, source: r.source)
    }

    /// Movies and series released in the last 7 days (Italy).
    func releasesThisWeek(_ kids: Bool) async -> VodRow {
        let to = CatalogRepository.isoDay(), from = CatalogRepository.isoDay(-7)
        let t = tmdb
        let mp: [(String, String)] = [("primary_release_date.gte", from), ("primary_release_date.lte", to), ("sort_by", "popularity.desc")]
        let l = await safe { try await t.discover("movie", mp) } + (await safe { try await t.discover("tv", [("first_air_date.gte", from), ("first_air_date.lte", to), ("sort_by", "popularity.desc")]) })
        let items = clean(l, kids).filter { $0.votes >= 3 || $0.popularity > 20 }.sortedByDescending { $0.popularity }
        return VodRow(id: "week", title: "Uscite di questa settimana", items: Array(items.prefix(20)), source: .discover("movie", mp))
    }

    func byGenre(_ media: String, _ genreId: Int, _ name: String, _ kids: Bool) async -> VodRow {
        let p: [(String, String)] = [("with_genres", "\(genreId)"), ("sort_by", "popularity.desc"), ("vote_count.gte", "50")]
        let t = tmdb
        return VodRow(id: "genre-\(media)-\(genreId)", title: name, items: Array(clean(await safe { try await t.discover(media, p) }, kids).prefix(20)), source: .discover(media, p))
    }

    /// "Sfoglia per genere": rows for one genre.
    func genreRows(_ media: String, _ genreId: Int, _ name: String, _ kids: Bool) async -> [VodRow] {
        let dateKey = media == "tv" ? "first_air_date" : "primary_release_date"
        let g = ("with_genres", "\(genreId)")
        let popP: [(String, String)] = [g, ("sort_by", "popularity.desc"), ("vote_count.gte", "50")]
        let topP: [(String, String)] = [g, ("sort_by", "vote_average.desc"), ("vote_count.gte", "300")]
        let newP: [(String, String)] = [g, ("sort_by", "\(dateKey).desc"), ("vote_count.gte", "20"), ("\(dateKey).lte", CatalogRepository.isoDay())]
        let itP: [(String, String)] = [g, ("with_original_language", "it"), ("sort_by", "popularity.desc"), ("vote_count.gte", "10")]
        let t = tmdb
        var jobs = [() async -> VodRow]()
        jobs.append {
            var top = Array(self.clean(await self.safe { try await t.trending(media, window: "week") }, kids).filter { $0.genreIds.contains(genreId) }.prefix(10))
            if top.count < 10 { top = Array(self.clean(await self.safe { try await t.discover(media, popP) }, kids).prefix(10)) }
            return VodRow(id: "g-top10-\(media)-\(genreId)", title: "Top 10 · \(name)", items: top, kind: .top10)
        }
        jobs.append {
            let l = await self.safe { try await t.discover(media, popP) } + (await self.safe { try await t.discover(media, popP, page: 2) })
            return VodRow(id: "g-pop-\(media)-\(genreId)", title: "\(name) · I più popolari", items: Array(self.clean(l, kids).prefix(30)), source: .discover(media, popP))
        }
        jobs.append { VodRow(id: "g-top-\(media)-\(genreId)", title: "\(name) · I più votati", items: Array(self.clean(await self.safe { try await t.discover(media, topP) }, kids).prefix(20)), source: .discover(media, topP)) }
        jobs.append { VodRow(id: "g-new-\(media)-\(genreId)", title: "\(name) · Novità", items: Array(self.clean(await self.safe { try await t.discover(media, newP) }, kids).prefix(20)), source: .discover(media, newP)) }
        jobs.append { VodRow(id: "g-it-\(media)-\(genreId)", title: "\(name) · Italiani", items: Array(self.clean(await self.safe { try await t.discover(media, itP) }, kids).prefix(20)), source: .discover(media, itP)) }
        return await mapConcurrent(jobs, limit: 5) { await $0() }.filter { $0.items.count >= 4 }
    }

    func similar(_ media: String, _ id: Int, _ kids: Bool) async -> [TmdbTitle] {
        let t = tmdb
        return Array(clean(await safe { try await t.similar(media, id) }, kids).prefix(20))
    }

    /// Instant on-device results (prefix match × popularity).
    func searchLocal(_ query: String, _ kids: Bool) -> [TmdbTitle] {
        guard let hits = index?.query(query) else { return [] }
        let ok = Set(clean(hits.map { $0.title }, kids).map { $0.key })
        return SearchIndex.rank(query, hits.filter { ok.contains($0.title.key) }, [])
    }

    /// Local hits merged with TMDB's own search (long tail), ranked together.
    func search(_ query: String, _ kids: Bool) async -> [TmdbTitle] {
        let t = tmdb
        let remote = clean(await safe { try await t.search(query) }, kids)
        let hits = index?.query(query) ?? []
        let ok = Set(clean(hits.map { $0.title }, kids).map { $0.key })
        return SearchIndex.rank(query, hits.filter { ok.contains($0.title.key) }, remote)
    }

    /// Titles for the taste picker of a new profile: well known, mixed movies/series.
    func onboardingPicks(_ kids: Bool) async -> [TmdbTitle] {
        let t = tmdb
        var jobs = [() async -> [TmdbTitle]]()
        jobs.append { await self.safe { try await t.trending("all", window: "week") } }
        jobs.append { await self.safe { try await t.popular("tv") } + (await self.safe { try await t.popular("tv", page: 2) }) }
        jobs.append { await self.safe { try await t.popular("movie") } + (await self.safe { try await t.popular("movie", page: 2) }) }
        jobs.append { await self.safe { try await t.topRated("tv") } }
        jobs.append { await self.safe { try await t.topRated("movie") } }
        jobs.append { await self.safe { try await t.discover("movie", [("with_genres", "16,10751"), ("sort_by", "popularity.desc")]) } }
        let all = clean(await mapConcurrent(jobs, limit: 6) { await $0() }.flatMap { $0 }, kids).filter { $0.votes >= 200 || kids }
        // interleave series and films so both are well represented, most popular first
        let tv = all.filter { $0.isTv }.sortedByDescending { $0.popularity }, mv = all.filter { !$0.isTv }.sortedByDescending { $0.popularity }
        var out = [TmdbTitle](); var i = 0
        while out.count < 30 && (i < tv.count || i < mv.count) {
            if i < tv.count { out.append(tv[i]) }
            if i < mv.count { out.append(mv[i]) }
            i += 1
        }
        return Array(out.prefix(30))
    }

    func details(_ media: String, _ id: Int) async throws -> TmdbDetails {
        let d = try await tmdb.details(media, id)
        cacheTitle(d)
        return d
    }
    func season(_ tvId: Int, _ season: Int) async throws -> TmdbSeason { try await tmdb.season(tvId, season) }
    func genres(_ media: String) async -> [Int: String] { (try? await tmdb.genres(media)) ?? [:] }
    func cachedTitle(_ id: Int, _ media: String) -> TitleEntity? { db.title(id, media) }

    func cacheTitle(_ d: TmdbDetails) {
        db.upsertTitle(TitleEntity(
            tmdbId: d.id, media: d.media, title: d.displayTitle, originalTitle: d.originalDisplayTitle, year: d.year, posterPath: d.posterPath, backdropPath: d.backdropPath,
            logoPath: d.logoPath, overview: d.overview, genreIds: d.genres.map { String($0.id) }.joined(separator: ","),
            keywordIds: d.keywordList.prefix(15).map { String($0.id) }.joined(separator: ","), castIds: d.cast.prefix(5).map { String($0.id) }.joined(separator: ","),
            directorIds: (d.directors + (d.createdBy ?? [])).prefix(3).map { String($0.id) }.joined(separator: ","), originalLanguage: d.originalLanguage, runtimeMin: d.runtimeMin,
            voteAverage: d.voteAverage, popularity: d.popularity, certification: d.certification, seasons: d.numberOfSeasons,
            lastAirDate: d.lastEpisodeToAir?.airDate ?? d.lastAirDate, nextAirDate: d.nextEpisodeToAir?.airDate, status: d.status,
            lastEpisode: d.lastEpisodeToAir?.episodeNumber ?? 0, lastSeason: d.lastEpisodeToAir?.seasonNumber ?? 0))
    }

    /// Make sure a lightweight title row exists for progress/list rendering (fetches details once, refreshes series facts every 12 h).
    func ensureTitle(_ id: Int, _ media: String) async -> TitleEntity? {
        let cached = db.title(id, media)
        let stale = cached != nil && cached!.media == "tv" && (cached!.status == nil || Clock.now - cached!.updatedAt > 12 * Clock.hour)
        if let c = cached, !stale { return c }
        _ = try? await details(media, id)
        return db.title(id, media) ?? cached
    }

    static func asTmdb(_ e: TitleEntity) -> TmdbTitle {
        TmdbTitle(tmdbId: e.tmdbId, mediaType: e.media, title: e.media == "movie" ? e.title : nil, name: e.media == "tv" ? e.title : nil, originalTitle: e.originalTitle, originalName: nil,
                  overview: e.overview, posterPath: e.posterPath, backdropPath: e.backdropPath, releaseDate: e.media == "movie" ? "\(e.year)-01-01" : nil,
                  firstAirDate: e.media == "tv" ? "\(e.year)-01-01" : nil, voteAverage: e.voteAverage, voteCount: nil, popularityValue: e.popularity,
                  genreIdList: e.genreIds.split(separator: ",").compactMap { Int($0) }, originalLanguage: e.originalLanguage, adultFlag: false)
    }

    /// Netflix-style card badge from public dates. `e` (cached details) enables the series badges.
    static func badgeFor(_ t: TmdbTitle, _ e: TitleEntity? = nil) -> String? {
        if let e = e, e.media == "tv" {
            let d = daysAgo(e.lastAirDate)
            if let d = d, (0...21).contains(d), e.lastEpisode == 1, e.lastSeason > 1 { return "Nuova stagione" }
            if let d = d, (0...14).contains(d) { return "Nuovi episodi" }
            if e.status == "Ended", let d = d, (0...30).contains(d) { return "Ultimo episodio" }
        }
        if let rel = daysAgo(t.date), (0...45).contains(rel) { return "Nuovo" }
        return nil
    }
}

/// Small deterministic generator (the daily shuffle must give the same order all day).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

/// Per-profile state: progress, lists, feedback events.
final class LibraryRepository {
    private let db: AppDB
    init(db: AppDB) { self.db = db }

    func continueWatching(_ pid: Int64) -> [ProgressEntity] { db.continueWatching(pid) }
    func progressFor(_ pid: Int64, _ id: Int, _ media: String) -> [ProgressEntity] { db.progressForTitle(pid, id, media) }
    func progressFor(_ pid: Int64, _ id: Int, _ media: String, _ s: Int, _ e: Int) -> ProgressEntity? { db.progressForEpisode(pid, id, media, s, e) }

    /// Called every few seconds from the player. Marks completed at 90%. Emits recommender events on transitions.
    func saveProgress(_ pid: Int64, _ id: Int, _ media: String, season: Int, episode: Int, positionMs: Millis, durationMs: Millis) {
        if durationMs <= 0 { return }
        let prev = db.progressForEpisode(pid, id, media, season, episode)
        let completed = Double(positionMs) >= Double(durationMs) * 0.90
        db.upsertProgress(ProgressEntity(profileId: pid, tmdbId: id, media: media, season: season, episode: episode, positionMs: positionMs, durationMs: durationMs, completed: completed || prev?.completed == true))
        if prev == nil { event(pid, id, media, "started", 0.1) }
        if completed && prev?.completed != true { event(pid, id, media, "completed", 1.0) }
        else if !completed && Double(positionMs) > Double(durationMs) * 0.6 && (prev == nil || Double(prev!.positionMs) < Double(durationMs) * 0.6) { event(pid, id, media, "progress", 0.6) }
    }
    func abandoned(_ pid: Int64, _ id: Int, _ media: String, positionMs: Millis, durationMs: Millis) {
        if durationMs > 0 && Double(positionMs) < Double(durationMs) * 0.10 && positionMs > 20_000 { event(pid, id, media, "abandoned", -0.4) }
    }
    /// "Segna come visto": completed at full length (duration from TMDB runtime when known).
    func markWatched(_ pid: Int64, _ id: Int, _ media: String, season: Int, episode: Int, runtimeMin: Int) {
        let dur = Millis(runtimeMin > 0 ? runtimeMin : 45) * Clock.minute
        let prev = db.progressForEpisode(pid, id, media, season, episode)
        db.upsertProgress(ProgressEntity(profileId: pid, tmdbId: id, media: media, season: season, episode: episode, positionMs: dur, durationMs: dur, completed: true))
        if prev?.completed != true { event(pid, id, media, "completed", 1.0) }
    }
    func markUnwatched(_ pid: Int64, _ id: Int, _ media: String, season: Int, episode: Int) { db.deleteProgressEpisode(pid, id, media, season, episode) }
    func clearProgress(_ pid: Int64, _ id: Int, _ media: String) { db.clearProgressTitle(pid, id, media) }
    /// Settings: wipe viewing history and the recommender's memory for a profile.
    func clearHistory(_ pid: Int64) { db.clearProgress(pid); db.clearEvents(pid) }
    func clearContinue(_ pid: Int64) { db.clearProgress(pid, unfinishedOnly: true) }

    func list(_ pid: Int64) -> [ListItemEntity] { db.list(pid) }
    func isInList(_ pid: Int64, _ id: Int, _ media: String) -> Bool { db.inList(pid, id, media) }
    func toggleList(_ pid: Int64, _ id: Int, _ media: String, currently: Bool) {
        if currently { db.removeFromList(pid, id, media); event(pid, id, media, "unlisted", -0.2) }
        else { db.addToList(ListItemEntity(profileId: pid, tmdbId: id, media: media)); event(pid, id, media, "listed", 0.5) }
    }

    /// Explicit opinion, Netflix style: pressing again removes it; like and dislike exclude each other. nil / "liked" / "disliked".
    func feedback(_ pid: Int64, _ id: Int, _ media: String) -> String? {
        let f = db.feedback(pid, id, media)
        return (f == "liked" || f == "disliked") ? f : nil
    }
    func like(_ pid: Int64, _ id: Int, _ media: String) { event(pid, id, media, "liked", 0.8) }
    func setFeedback(_ pid: Int64, _ id: Int, _ media: String, current: String?, want: String) {
        if current == "liked" { event(pid, id, media, "unliked", -0.8) } else if current == "disliked" { event(pid, id, media, "undisliked", 1.0) }
        if current != want { if want == "liked" { event(pid, id, media, "liked", 0.8) } else { event(pid, id, media, "disliked", -1.0) } }
    }

    private func event(_ pid: Int64, _ id: Int, _ media: String, _ kind: String, _ weight: Double) {
        db.insertEvent(WatchEventEntity(profileId: pid, tmdbId: id, media: media, kind: kind, weight: weight))
    }
    func recentEvents(_ pid: Int64) -> [WatchEventEntity] { db.recentEvents(pid) }
    func signalCount(_ pid: Int64) -> Int { db.signalCount(pid) }
    func recentCompleted(_ pid: Int64) -> [WatchEventEntity] { db.recentCompleted(pid) }
}

/// On-device content-based recommender with implicit feedback.
///
/// Profile vector = Σ weight(event) · decay(age) · features(title). Features: genres, keywords, cast, directors, language, decade, media.
/// Score(candidate) = cosine(profile, candidate) · novelty · popularity^0.3 · recency bonus.
/// Everything runs locally; candidates come from TMDB public endpoints (similar-to, discover by top genres, trending).
final class Recommender {
    private let db: AppDB
    private let catalog: CatalogRepository
    private let library: LibraryRepository
    private let halfLifeMs = 45.0 * 24 * 3600 * 1000

    struct Profile { let vec: [String: Double]; let topGenres: [Int]; let seen: Set<String>; let lastCompleted: [TitleEntity]; let signals: Int }

    init(db: AppDB, catalog: CatalogRepository, library: LibraryRepository) { self.db = db; self.catalog = catalog; self.library = library }

    private func features(_ t: TitleEntity) -> [String: Double] {
        var f = [String: Double]()
        for g in t.genreIds.split(separator: ",") where !g.isEmpty { f["g:\(g)"] = 1.0 }
        for k in t.keywordIds.split(separator: ",") where !k.isEmpty { f["k:\(k)"] = 0.6 }
        for c in t.castIds.split(separator: ",") where !c.isEmpty { f["c:\(c)"] = 0.5 }
        for d in t.directorIds.split(separator: ",") where !d.isEmpty { f["d:\(d)"] = 0.7 }
        if let l = t.originalLanguage { f["l:\(l)"] = 0.4 }
        if t.year > 0 { f["y:\(t.year / 10)"] = 0.3 }
        f["m:\(t.media)"] = 0.5
        if (1...100).contains(t.runtimeMin) { f["short"] = 0.2 }
        return f
    }
    private func featuresOf(_ t: TmdbTitle) -> [String: Double] {
        var f = [String: Double]()
        for g in t.genreIds { f["g:\(g)"] = 1.0 }
        if let l = t.originalLanguage { f["l:\(l)"] = 0.4 }
        if t.year > 0 { f["y:\(t.year / 10)"] = 0.3 }
        f["m:\(t.media)"] = 0.5
        return f
    }

    func profile(_ pid: Int64) -> Profile {
        let events = library.recentEvents(pid)
        let now = Clock.now
        let keys = events.map { "\($0.tmdbId)-\($0.media)" }.distinct
        let byKey = Dictionary(db.titles(keys).map { ("\($0.tmdbId)-\($0.media)", $0) }, uniquingKeysWith: { a, _ in a })
        var vec = [String: Double]()
        for e in events {
            guard let t = byKey["\(e.tmdbId)-\(e.media)"] else { continue }
            let w = e.weight * exp(-log(2.0) * Double(now - e.at) / halfLifeMs)
            for (k, v) in features(t) { vec[k, default: 0] += w * v }
        }
        let topGenres = vec.filter { $0.key.hasPrefix("g:") }.sorted { $0.value > $1.value }.prefix(3).compactMap { Int($0.key.removingPrefix("g:")) }
        let completed = library.recentCompleted(pid).compactMap { byKey["\($0.tmdbId)-\($0.media)"] }
        return Profile(vec: vec, topGenres: topGenres, seen: Set(keys), lastCompleted: completed, signals: library.signalCount(pid))
    }

    private func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var dot = 0.0
        for (k, v) in b { dot += v * (a[k] ?? 0) }
        let na = sqrt(a.values.reduce(0) { $0 + $1 * $1 }), nb = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return (na == 0 || nb == 0) ? 0 : dot / (na * nb)
    }

    func score(_ p: Profile, _ t: TmdbTitle) -> Double {
        let sim = cosine(p.vec, featuresOf(t))
        let novelty = p.seen.contains(t.key) ? 0.15 : 1.0
        let pop = pow(1.0 + t.popularity, 0.3)
        let thisYear = Calendar.current.component(.year, from: Date())
        return sim * novelty * pop * (t.year >= thisYear - 1 ? 1.15 : 1.0)
    }

    /// Personalised rows. Empty until the profile has at least 3 signals (cold start).
    func rows(_ pid: Int64, kids: Bool, genreNames: [Int: String]) async -> [VodRow] {
        let p = profile(pid)
        if p.signals < 3 { return [] }
        var rows = [VodRow]()
        // "Perché hai guardato X" for the two most recent completed titles
        for t in p.lastCompleted.prefix(2) {
            let sims = await catalog.similar(t.media, t.tmdbId, kids).filter { !p.seen.contains($0.key) }
            if sims.count >= 4 { rows.append(VodRow(id: "because-\(t.media)-\(t.tmdbId)", title: "Perché hai guardato \(t.title)", items: Array(sims.sortedByDescending { self.score(p, $0) }.prefix(20)), reason: t.title)) }
        }
        // "Scelti per te": pool from top genres + trending, ranked by affinity
        var pool = [TmdbTitle]()
        for g in p.topGenres {
            pool += await catalog.byGenre("movie", g, "", kids).items
            pool += await catalog.byGenre("tv", g, "", kids).items
        }
        pool += await catalog.heroCandidates(kids)
        let picks = Array(pool.distinct { $0.key }.filter { !p.seen.contains($0.key) }.sortedByDescending { self.score(p, $0) }.prefix(24))
        if picks.count >= 6 { rows.insert(VodRow(id: "foryou", title: "Scelti per te", items: picks), at: 0) }
        // one row per emerging genre
        for g in p.topGenres.prefix(2) {
            guard let name = genreNames[g] else { continue }
            var r = await catalog.byGenre((p.vec["m:tv"] ?? 0) > (p.vec["m:movie"] ?? 0) ? "tv" : "movie", g, "\(name) che potrebbero piacerti", kids)
            let items = r.items.filter { !p.seen.contains($0.key) }
            if items.count >= 6 { r.items = items.sortedByDescending { self.score(p, $0) }; rows.append(r) }
        }
        return rows
    }

    /// Human readable affinity for the detail page: 0 when there is not enough data.
    func matchPercent(_ pid: Int64, _ t: TmdbTitle) -> Int {
        let p = profile(pid)
        if p.signals < 3 { return 0 }
        return min(99, max(0, Int(55 + cosine(p.vec, featuresOf(t)) * 44)))
    }
}

/// On-device viewing profile, per viewer profile, nothing leaves the device. Watching time is added to a few keys — the
/// channel, its genre, the kind of programme and its TMDB genres — and halves every two weeks, so the Home's "di tendenza"
/// mix slowly drifts towards what is actually watched.
final class UsageRepository {
    private let db: AppDB
    private let profiles: Profiles
    static let halfLifeMs: Double = 14 * 24 * 3_600_000

    /// Affinity 0..1 per key, relative to the most watched key of the same family.
    struct Profile {
        let share: [String: Double]
        func of(_ key: String) -> Double { share[key] ?? 0 }
        func channel(_ id: String) -> Double { of("ch:\(id)") }
        func genre(_ cat: String) -> Double { of("cat:\(cat)") }
        func kind(_ k: String) -> Double { of("kind:\(k)") }
        func tmdbGenres(_ genres: String) -> Double { genres.components(separatedBy: ", ").filter { !$0.isBlank }.map { of("g:\($0)") }.max() ?? 0 }
        var isEmpty: Bool { share.isEmpty }
    }

    init(db: AppDB, profiles: Profiles) { self.db = db; self.profiles = profiles }

    private func decay(_ u: UsageEntity, _ now: Millis) -> Double { u.seconds * pow(0.5, Double(now - u.updatedAt) / UsageRepository.halfLifeMs) }

    func profile() -> Profile {
        let now = Clock.now
        var decayed = [String: Double]()
        for u in db.usage(profiles.id) { decayed[u.key] = decay(u, now) }
        var maxByFamily = [String: Double]()
        for (k, v) in decayed { let f = k.substringBefore(":"); maxByFamily[f] = max(maxByFamily[f] ?? 1.0, v) }
        return Profile(share: decayed.mapValues { $0 }.reduce(into: [String: Double]()) { acc, kv in acc[kv.key] = kv.value / (maxByFamily[kv.key.substringBefore(":")] ?? 1.0) })
    }

    /// Called by the player when a channel has been watched for `seconds` (zap away / exit). Short zaps are ignored.
    func record(_ c: ChannelEntity, _ p: ProgrammeEntity?, kind: String?, meta: ProgrammeMetaEntity?, seconds: Int) {
        let pid = profiles.id
        if seconds < 20 || pid == 0 { return }
        let now = Clock.now
        let s = Double(min(seconds, 4 * 3600))
        var keys = ["ch:\(c.streamId)", "cat:\(c.categoryId)"]
        if let k = kind { keys.append("kind:\(k)") }
        if let m = meta { keys += m.genres.components(separatedBy: ", ").filter { !$0.isBlank }.map { "g:\($0)" } }
        else if let cat = p?.category, !cat.isBlank { keys.append("g:\(cat)") }
        for k in keys {
            let base = db.usage(pid, k).map { decay($0, now) } ?? 0
            db.upsertUsage(UsageEntity(profileId: pid, key: k, seconds: base + s, updatedAt: now))
        }
    }
}
