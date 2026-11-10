import Foundation

// The same tables as the Android app (Room schema v3), so the two apps mean the same thing by every column.

/// A live channel after grouping: one row per logical channel, the best quality variant chosen at sync time.
struct ChannelEntity: Hashable, Identifiable {
    var streamId: String                // Xtream stream_id of the chosen variant
    var num: Int = 0                    // our number (DTT / Sky-like blocks)
    var providerNum: Int = 0
    var name: String = ""               // clean display name, e.g. "Rai 1", "DAZN Evento 47"
    var baseName: String = ""
    var quality: String = "SD"          // UHD / FHD / HD / HEVC / SD
    var icon: String? = nil
    var epgId: String? = nil            // effective id used in `programmes`
    var lineEpgId: String? = nil
    var categoryId: String = "local"    // general, sport, events, cinema, entertainment, docs, news, kids, music, local
    var providerCategory: String = ""
    var shiftMin: Int = 0               // 60 for "+1" channels
    var event: String? = nil            // PPV/event channels: "Hellas Verona - Carrarese"
    var eventSub: String? = nil         // "Serie BKT"
    var eventStart: Millis? = nil
    var archive: Bool = false
    var archiveDays: Int = 0
    /// Other variants of the same channel: "streamId|quality,streamId|quality"
    var variants: String = ""
    /// White (for dark backgrounds) logo from the broadcaster guide; nil when unknown.
    var logo: String? = nil

    var id: String { streamId }
    var isEvent: Bool { event != nil || eventSub != nil }
}

struct CategoryEntity: Hashable, Identifiable {
    var id: String                      // "<kind>:<category_id>"
    var categoryId: String
    var kind: String                    // live | vod | series
    var name: String
    var rawName: String
    var order: Int
}

/// A viewer profile. Everything personal — favourites, recents, taste, reminders, playback prefs — hangs off its id.
struct ProfileEntity: Hashable, Identifiable {
    var id: Int64 = 0
    var name: String
    var avatarColor: Int = 0
    var kids: Bool = false
    var createdAt: Millis = Clock.now
    /// 4-digit PIN asked when entering this profile (nil = open).
    var pin: String? = nil
    var avatarIcon: Int = 0
    /// 0 = bambini (same as kids), 1 = ragazzi 13+, 2 = tutti.
    var maturity: Int = 2

    var level: Int { kids ? 0 : maturity }
}

struct ProgrammeEntity: Hashable, Identifiable {
    var id: Int64 = 0
    var epgId: String
    var start: Millis
    var stop: Millis
    var title: String
    var desc: String? = nil
    var icon: String? = nil             // still when the source has one
    var category: String? = nil         // "Film", "Calcio", "Approfondimento"…
    var subtitle: String? = nil         // episode name
    var episode: String? = nil          // "S1 E5"
    var year: Int? = nil
    var poster: String? = nil
    /// movie | series | sport | show | news | kids | doc | music; nil = unknown.
    var kind: String? = nil
    /// Clean show / film title for recognition (TMDB, replicas).
    var show: String? = nil
    var firstRun: Bool = false
    var highlight: Bool = false         // editorial pick of the source
    var live: Bool = false              // a real live broadcast, not a replay
    var src: String = ""                // sky | rai | mediaset | ext | iptvepg | dazn | line
}

/// TMDB dressing for a programme title (films/series): cached hits and misses, keyed by cleaned title + year.
struct ProgrammeMetaEntity: Hashable {
    var key: String
    var found: Bool
    var fetchedAt: Millis
    var tmdbId: Int = 0
    var media: String = ""              // movie | tv | show
    var title: String = ""
    var overview: String? = nil
    var tagline: String? = nil
    var backdrop: String? = nil
    var poster: String? = nil
    var logo: String? = nil
    var cast: String = ""
    var genres: String = ""
    var vote: Double = 0
    var popularity: Double = 0
    var year: Int = 0
    var runtime: Int = 0
    var seasons: Int = 0
    var episodes: Int = 0
}

struct UsageEntity { var profileId: Int64; var key: String; var seconds: Double; var updatedAt: Millis }
struct TrendingEntity { var id: String; var rank: Int; var fetchedAt: Millis }

/// "Avvisami": a notification (and an in-app alert when the app is open) when a programme starts on a channel.
struct ReminderEntity: Hashable, Identifiable {
    var profileId: Int64
    var streamId: String
    var at: Millis
    var title: String
    var sub: String?
    var createdAt: Millis
    var id: String { "\(profileId)|\(streamId)|\(at)" }
}

/// Cached TMDB title facts, shared by all profiles (also the recommender's feature vectors).
struct TitleEntity: Hashable {
    var tmdbId: Int
    var media: String
    var title: String
    var originalTitle: String
    var year: Int
    var posterPath: String?
    var backdropPath: String?
    var logoPath: String?
    var overview: String?
    var genreIds: String
    var keywordIds: String = ""
    var castIds: String = ""
    var directorIds: String = ""
    var originalLanguage: String?
    var runtimeMin: Int
    var voteAverage: Double
    var popularity: Double
    var certification: String?
    var seasons: Int = 0
    var updatedAt: Millis = Clock.now
    var lastAirDate: String? = nil
    var nextAirDate: String? = nil
    var status: String? = nil
    var lastEpisode: Int = 0
    var lastSeason: Int = 0
}

/// Playback position per profile and content (episode-level for series).
struct ProgressEntity: Hashable {
    var profileId: Int64
    var tmdbId: Int
    var media: String
    var season: Int = 0
    var episode: Int = 0
    var positionMs: Millis
    var durationMs: Millis
    var completed: Bool
    var updatedAt: Millis = Clock.now
}

/// Implicit/explicit feedback events consumed by the recommender.
struct WatchEventEntity {
    var id: Int64 = 0
    var profileId: Int64
    var tmdbId: Int
    var media: String
    var kind: String                    // started | progress | completed | abandoned | liked | disliked | listed | unlisted | rewatch
    var weight: Double
    var at: Millis = Clock.now
}

struct ListItemEntity: Hashable { var profileId: Int64; var tmdbId: Int; var media: String; var addedAt: Millis = Clock.now }

/// Remembered Stream4Me match for a TMDB title so the second play is instant.
struct SourceCacheEntity { var tmdbId: Int; var media: String; var channel: String; var item: String; var title: String; var updatedAt: Millis = Clock.now }

/// What Stream4Me can actually play, learnt from every search.
struct VodIndexEntity { var tmdbId: Int; var media: String; var available: Bool; var checkedAt: Millis = Clock.now }

/// Offline download (phones): one row per film / episode.
struct DownloadEntity: Hashable, Identifiable {
    var id: String                      // "<media>-<tmdbId>-<season>-<episode>"
    var profileId: Int64
    var tmdbId: Int
    var media: String
    var season: Int
    var episode: Int
    var title: String
    var sub: String?
    var poster: String?
    var backdrop: String?
    var state: String                   // queued | running | done | failed
    var progress: Double
    var bytes: Int64
    var file: String?                   // path relative to the downloads folder (movpkg or mp4)
    var createdAt: Millis = Clock.now
    var error: String? = nil
}
