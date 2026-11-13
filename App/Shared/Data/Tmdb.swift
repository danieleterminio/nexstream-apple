import Foundation

/// A film or a series as TMDB lists it (search, trending, discover…).
struct TmdbTitle: Codable, Hashable, Identifiable {
    var tmdbId: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var voteCount: Int?
    var popularityValue: Double?
    var genreIdList: [Int]?
    var originalLanguage: String?
    var adultFlag: Bool?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "id", mediaType = "media_type", title, name, originalTitle = "original_title", originalName = "original_name", overview
        case posterPath = "poster_path", backdropPath = "backdrop_path", releaseDate = "release_date", firstAirDate = "first_air_date"
        case voteAverage = "vote_average", voteCount = "vote_count", popularityValue = "popularity", genreIdList = "genre_ids"
        case originalLanguage = "original_language", adultFlag = "adult"
    }

    var id: String { "\(tmdbId)-\(media)" }
    var isTv: Bool { mediaType == "tv" }
    var media: String { isTv ? "tv" : "movie" }
    var displayTitle: String { (isTv ? name : title) ?? name ?? title ?? "" }
    var originalDisplayTitle: String { (isTv ? originalName : originalTitle) ?? originalName ?? originalTitle ?? displayTitle }
    var year: Int { Int(((isTv ? firstAirDate : releaseDate) ?? "").prefix(4)) ?? 0 }
    var date: String? { isTv ? firstAirDate : releaseDate }
    var vote: Double { voteAverage ?? 0 }
    var votes: Int { voteCount ?? 0 }
    var popularity: Double { popularityValue ?? 0 }
    var genreIds: [Int] { genreIdList ?? [] }
    var adult: Bool { adultFlag ?? false }
    /// "<tmdbId>-<media>", the key used by lists, progress and the recommender.
    var key: String { "\(tmdbId)-\(media)" }
    func with(media m: String) -> TmdbTitle { var c = self; c.mediaType = m; return c }
}

struct TmdbGenre: Codable, Hashable { var id: Int; var name: String }
struct TmdbPerson: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var character: String?
    var job: String?
    var profilePath: String?
    var order: Int?
    enum CodingKeys: String, CodingKey { case id, name, character, job, profilePath = "profile_path", order }
}
struct TmdbImage: Codable, Hashable {
    var filePath: String
    var lang: String?
    var vote: Double?
    enum CodingKeys: String, CodingKey { case filePath = "file_path", lang = "iso_639_1", vote = "vote_average" }
}
struct TmdbSeasonSummary: Codable, Hashable {
    var seasonNumber: Int
    var name: String?
    var episodeCount: Int?
    var airDate: String?
    enum CodingKeys: String, CodingKey { case seasonNumber = "season_number", name, episodeCount = "episode_count", airDate = "air_date" }
}
struct TmdbEpisode: Codable, Hashable, Identifiable {
    var id: Int
    var episodeNumber: Int
    var seasonNumber: Int
    var name: String?
    var overview: String?
    var stillPath: String?
    var runtime: Int?
    var airDate: String?
    enum CodingKeys: String, CodingKey { case id, episodeNumber = "episode_number", seasonNumber = "season_number", name, overview, stillPath = "still_path", runtime, airDate = "air_date" }
}
struct TmdbSeason: Codable {
    var seasonNumber: Int?
    var name: String?
    var overview: String?
    var episodes: [TmdbEpisode]?
    enum CodingKeys: String, CodingKey { case seasonNumber = "season_number", name, overview, episodes }
}
struct TmdbKeyword: Codable, Hashable { var id: Int; var name: String }

struct TmdbDetails: Codable, Hashable {
    struct Credits: Codable, Hashable { var cast: [TmdbPerson]?; var crew: [TmdbPerson]? }
    struct Images: Codable, Hashable { var logos: [TmdbImage]?; var backdrops: [TmdbImage]? }
    struct Video: Codable, Hashable { var key: String; var site: String; var type: String }
    struct Videos: Codable, Hashable { var results: [Video]? }
    struct Rating: Codable, Hashable { var country: String; var rating: String?; enum CodingKeys: String, CodingKey { case country = "iso_3166_1", rating } }
    struct Ratings: Codable, Hashable { var results: [Rating]? }
    struct ReleaseDate: Codable, Hashable { var certification: String? }
    struct ReleaseCountry: Codable, Hashable { var country: String; var dates: [ReleaseDate]?; enum CodingKeys: String, CodingKey { case country = "iso_3166_1", dates = "release_dates" } }
    struct Releases: Codable, Hashable { var results: [ReleaseCountry]? }
    struct Keywords: Codable, Hashable { var keywords: [TmdbKeyword]?; var results: [TmdbKeyword]? }

    var id: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var tagline: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var lastAirDate: String?
    var voteAverageValue: Double?
    var voteCountValue: Int?
    var popularityValue: Double?
    var runtime: Int?
    var episodeRunTime: [Int]?
    var seasonsCount: Int?
    var episodesCount: Int?
    var status: String?
    var genreList: [TmdbGenre]?
    var seasonList: [TmdbSeasonSummary]?
    var credits: Credits?
    var images: Images?
    var videos: Videos?
    var contentRatings: Ratings?
    var releaseDates: Releases?
    var keywords: Keywords?
    var originalLanguage: String?
    var createdBy: [TmdbPerson]?
    var nextEpisodeToAir: TmdbEpisode?
    var lastEpisodeToAir: TmdbEpisode?

    enum CodingKeys: String, CodingKey {
        case id, mediaType = "media_type", title, name, originalTitle = "original_title", originalName = "original_name", overview, tagline
        case posterPath = "poster_path", backdropPath = "backdrop_path", releaseDate = "release_date", firstAirDate = "first_air_date", lastAirDate = "last_air_date"
        case voteAverageValue = "vote_average", voteCountValue = "vote_count", popularityValue = "popularity", runtime, episodeRunTime = "episode_run_time"
        case seasonsCount = "number_of_seasons", episodesCount = "number_of_episodes", status, genreList = "genres", seasonList = "seasons", credits, images, videos
        case contentRatings = "content_ratings", releaseDates = "release_dates", keywords, originalLanguage = "original_language", createdBy = "created_by"
        case nextEpisodeToAir = "next_episode_to_air", lastEpisodeToAir = "last_episode_to_air"
    }

    var isTv: Bool { mediaType == "tv" }
    var media: String { isTv ? "tv" : "movie" }
    var displayTitle: String { (isTv ? name : title) ?? name ?? title ?? "" }
    var originalDisplayTitle: String { (isTv ? originalName : originalTitle) ?? displayTitle }
    var year: Int { Int(((isTv ? firstAirDate : releaseDate) ?? "").prefix(4)) ?? 0 }
    var runtimeMin: Int { runtime ?? episodeRunTime?.first ?? 0 }
    var voteAverage: Double { voteAverageValue ?? 0 }
    var popularity: Double { popularityValue ?? 0 }
    var genres: [TmdbGenre] { genreList ?? [] }
    var seasons: [TmdbSeasonSummary] { seasonList ?? [] }
    var numberOfSeasons: Int { seasonsCount ?? 0 }
    var numberOfEpisodes: Int { episodesCount ?? 0 }
    /// Title logos, best first: Italian, then English, then anything.
    var logoPaths: [String] {
        (images?.logos ?? []).sorted { a, b in
            let ka = (a.lang == "it" ? 0 : 1, a.lang == "en" ? 0 : 1, -(a.vote ?? 0)), kb = (b.lang == "it" ? 0 : 1, b.lang == "en" ? 0 : 1, -(b.vote ?? 0))
            return ka < kb
        }.map { $0.filePath }
    }
    var logoPath: String? { logoPaths.first }
    /// Best textless backdrop (language-less ones have no burnt-in title).
    var bestBackdrop: String? {
        let b = (images?.backdrops ?? []).sorted { a, c in
            let ka = (a.lang == nil ? 0 : 1, -(a.vote ?? 0)), kc = (c.lang == nil ? 0 : 1, -(c.vote ?? 0))
            return ka < kc
        }
        return b.first?.filePath ?? backdropPath
    }
    var certification: String? {
        func rating(_ c: String) -> String? { contentRatings?.results?.first { $0.country == c }?.rating?.nilIfBlank }
        func release(_ c: String) -> String? { releaseDates?.results?.first { $0.country == c }?.dates?.compactMap { $0.certification?.nilIfBlank }.first }
        return rating("IT") ?? rating("US") ?? release("IT") ?? release("US")
    }
    var cast: [TmdbPerson] { Array((credits?.cast ?? []).prefix(8)) }
    var directors: [TmdbPerson] { (credits?.crew ?? []).filter { $0.job == "Director" } }
    var trailerKey: String? { videos?.results?.first { $0.site == "YouTube" && $0.type == "Trailer" }?.key }
    var keywordList: [TmdbKeyword] { keywords?.keywords ?? keywords?.results ?? [] }
    func toTitle() -> TmdbTitle {
        TmdbTitle(tmdbId: id, mediaType: media, title: title, name: name, originalTitle: originalTitle, originalName: originalName, overview: overview, posterPath: posterPath,
                  backdropPath: backdropPath, releaseDate: releaseDate, firstAirDate: firstAirDate, voteAverage: voteAverage, voteCount: voteCountValue, popularityValue: popularity,
                  genreIdList: genres.map { $0.id }, originalLanguage: originalLanguage, adultFlag: false)
    }
}

struct TmdbError: Error, CustomStringConvertible { let description: String }

/// TMDB v3 client, Italian locale, with a small in-memory cache. No user login involved: only the app's API key.
final class TmdbApi {
    private let apiKey: String
    private let lock = NSLock()
    private var cache = [String: (Millis, Data)]()
    private struct Page: Codable { var results: [TmdbTitle]? }
    private struct GenreList: Codable { var genres: [TmdbGenre]? }

    init(apiKey: String = Secrets.tmdbKey) { self.apiKey = apiKey }

    private func get(_ path: String, _ params: [(String, String)] = [], ttlMs: Millis = 30 * Clock.minute) async throws -> Data {
        var q = "api_key=\(apiKey.urlQueryEncoded)&language=it-IT"
        for (k, v) in params { q += "&\(k.urlQueryEncoded)=\(v.urlQueryEncoded)" }
        let url = "https://api.themoviedb.org/3/\(path)?\(q)"
        lock.lock()
        if let hit = cache[url], Clock.now - hit.0 < ttlMs { lock.unlock(); return hit.1 }
        lock.unlock()
        let r = try await Http.request(url, timeout: 15)
        if !r.ok { throw TmdbError(description: "TMDB \(r.status) for \(path)") }
        lock.lock()
        if cache.count > 400 { cache.removeAll() }
        cache[url] = (Clock.now, r.data)
        lock.unlock()
        return r.data
    }

    private func page(_ path: String, _ params: [(String, String)] = [], media: String? = nil, ttlMs: Millis = 30 * Clock.minute) async throws -> [TmdbTitle] {
        let p = try JSONDecoder().decode(Page.self, from: try await get(path, params, ttlMs: ttlMs))
        let list = p.results ?? []
        guard let m = media else { return list }
        return list.map { $0.with(media: m) }
    }

    func trending(_ media: String, window: String = "week", page p: Int = 1, region: Bool = false) async throws -> [TmdbTitle] {
        var params = [("page", "\(p)")]
        if region { params.append(("region", "IT")) }
        let list = try await page("trending/\(media)/\(window)", params)
        return list.map { $0.mediaType == nil ? $0.with(media: media) : $0 }
    }
    func popular(_ media: String, page p: Int = 1) async throws -> [TmdbTitle] { try await page("\(media)/popular", [("page", "\(p)"), ("region", "IT")], media: media) }
    func topRated(_ media: String, page p: Int = 1) async throws -> [TmdbTitle] { try await page("\(media)/top_rated", [("page", "\(p)"), ("region", "IT")], media: media) }
    func nowPlaying(page p: Int = 1) async throws -> [TmdbTitle] { try await page("movie/now_playing", [("page", "\(p)"), ("region", "IT")], media: "movie") }
    func upcoming(page p: Int = 1) async throws -> [TmdbTitle] { try await page("movie/upcoming", [("page", "\(p)"), ("region", "IT")], media: "movie") }
    func onTheAir(page p: Int = 1) async throws -> [TmdbTitle] { try await page("tv/on_the_air", [("page", "\(p)")], media: "tv") }
    func discover(_ media: String, _ params: [(String, String)], page p: Int = 1) async throws -> [TmdbTitle] {
        try await page("discover/\(media)", [("page", "\(p)"), ("region", "IT"), ("include_adult", "false"), ("watch_region", "IT")] + params, media: media)
    }
    func similar(_ media: String, _ id: Int) async throws -> [TmdbTitle] {
        try await page("\(media)/\(id)/recommendations").map { $0.mediaType == nil ? $0.with(media: media) : $0 }
    }
    /// Films and series matching a query (TMDB matches whole words).
    func search(_ query: String, page p: Int = 1) async throws -> [TmdbTitle] {
        try await page("search/multi", [("query", query), ("page", "\(p)"), ("include_adult", "false")], ttlMs: 5 * Clock.minute).filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }
    /// `kind` = "movie" | "tv" | "multi" (the guide's programme recognition).
    func searchKind(_ kind: String, _ query: String, year: Int? = nil) async throws -> [TmdbTitle] {
        var params = [("query", query), ("include_adult", "false")]
        if let y = year, y > 0 { params.append((kind == "tv" ? "first_air_date_year" : "year", String(y))) }
        let list = try await page("search/\(kind)", params)
        return list.map { kind == "multi" ? $0 : $0.with(media: kind) }.filter { !$0.adult && (kind != "multi" || $0.mediaType == "movie" || $0.mediaType == "tv") }
    }
    func details(_ media: String, _ id: Int) async throws -> TmdbDetails {
        let d = try await get("\(media)/\(id)", [("append_to_response", "credits,images,videos,content_ratings,release_dates,keywords"), ("include_image_language", "it,en,null")], ttlMs: 6 * Clock.hour)
        var det = try JSONDecoder().decode(TmdbDetails.self, from: d)
        det.mediaType = media
        return det
    }
    func season(_ tvId: Int, _ season: Int) async throws -> TmdbSeason {
        try JSONDecoder().decode(TmdbSeason.self, from: try await get("tv/\(tvId)/season/\(season)", ttlMs: 6 * Clock.hour))
    }
    func genres(_ media: String) async throws -> [Int: String] {
        let g = try JSONDecoder().decode(GenreList.self, from: try await get("genre/\(media)/list", ttlMs: 24 * Clock.hour))
        return Dictionary((g.genres ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
}

extension TmdbDetails {
    /// The episode after S`season` E`episode`: the next one of the same season, or E1 of the next season with episodes
    /// once the season is over (TMDB's episode counts). Past the last season it stays on the next number.
    func episodeAfter(_ season: Int, _ episode: Int) -> (Int, Int) {
        let s = max(1, season)
        if let cur = seasons.first(where: { $0.seasonNumber == s }), let n = cur.episodeCount, n > 0, episode >= n,
           let next = seasons.filter({ $0.seasonNumber > s && ($0.episodeCount ?? 0) > 0 }).min(by: { $0.seasonNumber < $1.seasonNumber }) {
            return (next.seasonNumber, 1)
        }
        return (s, episode + 1)
    }

    /// TMDB ratings come in US codes ("TV-MA", "R"): shown as the age they mean, the Italian way.
    static func ageLabel(_ c: String?) -> String? {
        guard let raw = c?.trimmed, !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "NR", "UNRATED", "NOT RATED": return nil
        case "G", "TV-G", "TV-Y", "T", "U", "0", "TP": return "Per tutti"
        case "TV-Y7", "PG", "TV-PG", "6", "7": return "7+"
        case "PG-13", "TV-14", "12", "13", "14": return "14+"
        case "R", "16": return "16+"
        case "NC-17", "TV-MA", "18", "VM18": return "18+"
        default:
            if raw.hasSuffix("+") { return raw }
            return raw.allSatisfy({ $0.isNumber }) ? raw + "+" : nil
        }
    }

    /// TMDB leaves some series genres in English.
    static func genreIt(_ g: String) -> String {
        switch g {
        case "Action & Adventure": return "Azione e avventura"
        case "Sci-Fi & Fantasy": return "Fantascienza e fantasy"
        case "War & Politics": return "Guerra e politica"
        case "Kids": return "Bambini"
        case "News": return "Notizie"
        case "Talk": return "Talk show"
        default: return g
        }
    }
}
