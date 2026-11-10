import Foundation

/// The app database: one SQLite file with the same tables as the Android app. Queries never throw to their callers — a
/// failed statement is logged and reads come back empty — so the screens above stay simple.
/// `changes` says which table was written, and the view models reload what depends on it.
final class AppDB {
    let sql: SQLiteDB
    let changes = Signal<String>()

    static let schemaVersion = 4

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        sql = try SQLiteDB(path: url.path)
        if sql.userVersion != AppDB.schemaVersion {
            // a cache-like database: a new schema starts clean (personal data comes back from the backup, see `Backup`)
            for t in AppDB.tables { try? sql.exec("DROP TABLE IF EXISTS \(t)") }
        }
        try sql.exec(AppDB.schema)
        sql.userVersion = AppDB.schemaVersion
    }

    static let tables = ["channels", "categories", "profiles", "favorites", "recents", "programmes", "programme_meta", "usage", "trending", "meta", "reminders",
                         "title", "progress", "watch_event", "list_item", "source_cache", "vod_index", "downloads"]

    static let schema = """
    CREATE TABLE IF NOT EXISTS channels (streamId TEXT PRIMARY KEY, num INTEGER NOT NULL, providerNum INTEGER NOT NULL, name TEXT NOT NULL, baseName TEXT NOT NULL,
      quality TEXT NOT NULL, icon TEXT, epgId TEXT, lineEpgId TEXT, categoryId TEXT NOT NULL, providerCategory TEXT NOT NULL, shiftMin INTEGER NOT NULL,
      event TEXT, eventSub TEXT, eventStart INTEGER, archive INTEGER NOT NULL, archiveDays INTEGER NOT NULL, variants TEXT NOT NULL, logo TEXT);
    CREATE INDEX IF NOT EXISTS ix_channels_cat ON channels(categoryId);
    CREATE INDEX IF NOT EXISTS ix_channels_epg ON channels(epgId);
    CREATE INDEX IF NOT EXISTS ix_channels_num ON channels(num);
    CREATE TABLE IF NOT EXISTS categories (id TEXT PRIMARY KEY, categoryId TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL, rawName TEXT NOT NULL, "order" INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, avatarColor INTEGER NOT NULL, kids INTEGER NOT NULL, createdAt INTEGER NOT NULL,
      pin TEXT, avatarIcon INTEGER NOT NULL, maturity INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS favorites (profileId INTEGER NOT NULL, streamId TEXT NOT NULL, addedAt INTEGER NOT NULL, PRIMARY KEY(profileId, streamId));
    CREATE TABLE IF NOT EXISTS recents (profileId INTEGER NOT NULL, streamId TEXT NOT NULL, watchedAt INTEGER NOT NULL, PRIMARY KEY(profileId, streamId));
    CREATE TABLE IF NOT EXISTS programmes (id INTEGER PRIMARY KEY AUTOINCREMENT, epgId TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, title TEXT NOT NULL,
      "desc" TEXT, icon TEXT, category TEXT, subtitle TEXT, episode TEXT, year INTEGER, poster TEXT, kind TEXT, show TEXT, firstRun INTEGER NOT NULL, highlight INTEGER NOT NULL,
      live INTEGER NOT NULL, src TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS ix_prog_epg_start ON programmes(epgId, start);
    CREATE INDEX IF NOT EXISTS ix_prog_stop ON programmes(stop);
    CREATE INDEX IF NOT EXISTS ix_prog_start ON programmes(start);
    CREATE TABLE IF NOT EXISTS programme_meta ("key" TEXT PRIMARY KEY, found INTEGER NOT NULL, fetchedAt INTEGER NOT NULL, tmdbId INTEGER NOT NULL, media TEXT NOT NULL, title TEXT NOT NULL,
      overview TEXT, tagline TEXT, backdrop TEXT, poster TEXT, logo TEXT, "cast" TEXT NOT NULL, genres TEXT NOT NULL, vote REAL NOT NULL, popularity REAL NOT NULL, year INTEGER NOT NULL,
      runtime INTEGER NOT NULL, seasons INTEGER NOT NULL, episodes INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS usage (profileId INTEGER NOT NULL, "key" TEXT NOT NULL, seconds REAL NOT NULL, updatedAt INTEGER NOT NULL, PRIMARY KEY(profileId, "key"));
    CREATE TABLE IF NOT EXISTS trending (id TEXT PRIMARY KEY, rank INTEGER NOT NULL, fetchedAt INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS meta ("key" TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS reminders (profileId INTEGER NOT NULL, streamId TEXT NOT NULL, at INTEGER NOT NULL, title TEXT NOT NULL, sub TEXT, createdAt INTEGER NOT NULL, PRIMARY KEY(profileId, streamId));
    CREATE TABLE IF NOT EXISTS title (tmdbId INTEGER NOT NULL, media TEXT NOT NULL, title TEXT NOT NULL, originalTitle TEXT NOT NULL, year INTEGER NOT NULL, posterPath TEXT, backdropPath TEXT,
      logoPath TEXT, overview TEXT, genreIds TEXT NOT NULL, keywordIds TEXT NOT NULL, castIds TEXT NOT NULL, directorIds TEXT NOT NULL, originalLanguage TEXT, runtimeMin INTEGER NOT NULL,
      voteAverage REAL NOT NULL, popularity REAL NOT NULL, certification TEXT, seasons INTEGER NOT NULL, updatedAt INTEGER NOT NULL, lastAirDate TEXT, nextAirDate TEXT, status TEXT,
      lastEpisode INTEGER NOT NULL, lastSeason INTEGER NOT NULL, PRIMARY KEY(tmdbId, media));
    CREATE TABLE IF NOT EXISTS progress (profileId INTEGER NOT NULL, tmdbId INTEGER NOT NULL, media TEXT NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL, positionMs INTEGER NOT NULL,
      durationMs INTEGER NOT NULL, completed INTEGER NOT NULL, updatedAt INTEGER NOT NULL, PRIMARY KEY(profileId, tmdbId, media, season, episode));
    CREATE TABLE IF NOT EXISTS watch_event (id INTEGER PRIMARY KEY AUTOINCREMENT, profileId INTEGER NOT NULL, tmdbId INTEGER NOT NULL, media TEXT NOT NULL, kind TEXT NOT NULL, weight REAL NOT NULL, at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS ix_event_pid ON watch_event(profileId, at);
    CREATE TABLE IF NOT EXISTS list_item (profileId INTEGER NOT NULL, tmdbId INTEGER NOT NULL, media TEXT NOT NULL, addedAt INTEGER NOT NULL, PRIMARY KEY(profileId, tmdbId, media));
    CREATE TABLE IF NOT EXISTS source_cache (tmdbId INTEGER NOT NULL, media TEXT NOT NULL, channel TEXT NOT NULL, item TEXT NOT NULL, title TEXT NOT NULL, updatedAt INTEGER NOT NULL, PRIMARY KEY(tmdbId, media));
    CREATE TABLE IF NOT EXISTS vod_index (tmdbId INTEGER NOT NULL, media TEXT NOT NULL, available INTEGER NOT NULL, checkedAt INTEGER NOT NULL, PRIMARY KEY(tmdbId, media));
    CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, profileId INTEGER NOT NULL, tmdbId INTEGER NOT NULL, media TEXT NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL,
      title TEXT NOT NULL, sub TEXT, poster TEXT, backdrop TEXT, state TEXT NOT NULL, progress REAL NOT NULL, bytes INTEGER NOT NULL, file TEXT, createdAt INTEGER NOT NULL, error TEXT);
    """

    // ---------------------------------------------------------------------------------------------------- plumbing

    func rows<T>(_ q: String, _ args: [Any?] = [], _ map: (SQLRow) -> T) -> [T] {
        do { return try sql.query(q, args, map) } catch { NxLog.e("NxDb", "\(error) in \(q.prefix(90))"); return [] }
    }
    func one<T>(_ q: String, _ args: [Any?] = [], _ map: (SQLRow) -> T) -> T? { rows(q, args, map).first }
    @discardableResult
    func run(_ q: String, _ args: [Any?] = [], touch table: String? = nil) -> Int {
        do {
            let n = try sql.run(q, args)
            if let t = table { changes.send(t) }
            return n
        } catch { NxLog.e("NxDb", "\(error) in \(q.prefix(90))"); return 0 }
    }
    func count(_ q: String, _ args: [Any?] = []) -> Int { one(q, args) { $0.int(0) } ?? 0 }
    func tx(_ body: () throws -> Void) {
        do { try sql.transaction(body) } catch { NxLog.e("NxDb", "transaction: \(error)") }
    }
    /// "?,?,?" for an IN list.
    static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    // ---------------------------------------------------------------------------------------------------- meta (key/value)

    func meta(_ key: String) -> String? { one("SELECT value FROM meta WHERE \"key\" = ?", [key]) { $0.string(0) } }
    func setMeta(_ key: String, _ value: String) { run("INSERT OR REPLACE INTO meta(\"key\", value) VALUES(?,?)", [key, value], touch: "meta") }
    func metaInt64(_ key: String) -> Int64 { meta(key).flatMap { Int64($0) } ?? 0 }

    // ---------------------------------------------------------------------------------------------------- profiles

    private static let profileCols = "id, name, avatarColor, kids, createdAt, pin, avatarIcon, maturity"
    private static func profile(_ r: SQLRow) -> ProfileEntity {
        ProfileEntity(id: r.int64(0), name: r.string(1), avatarColor: r.int(2), kids: r.bool(3), createdAt: r.int64(4), pin: r.stringOrNil(5), avatarIcon: r.int(6), maturity: r.int(7))
    }
    func profiles() -> [ProfileEntity] { rows("SELECT \(AppDB.profileCols) FROM profiles ORDER BY createdAt", [], AppDB.profile) }
    func profile(_ id: Int64) -> ProfileEntity? { one("SELECT \(AppDB.profileCols) FROM profiles WHERE id = ?", [id], AppDB.profile) }
    func insertProfile(_ p: ProfileEntity) -> Int64 {
        let id = (try? sql.insert("INSERT INTO profiles(name, avatarColor, kids, createdAt, pin, avatarIcon, maturity) VALUES(?,?,?,?,?,?,?)",
                                  [p.name, p.avatarColor, p.kids, p.createdAt, p.pin, p.avatarIcon, p.maturity])) ?? 0
        changes.send("profiles")
        return id
    }
    func upsertProfile(_ p: ProfileEntity) {
        run("INSERT OR REPLACE INTO profiles(id, name, avatarColor, kids, createdAt, pin, avatarIcon, maturity) VALUES(?,?,?,?,?,?,?,?)",
            [p.id, p.name, p.avatarColor, p.kids, p.createdAt, p.pin, p.avatarIcon, p.maturity], touch: "profiles")
    }
    /// Everything personal of a deleted profile goes with it.
    func deleteProfileCascade(_ id: Int64) {
        tx {
            for t in ["favorites", "recents", "usage", "reminders", "progress", "watch_event", "list_item", "downloads"] { try sql.run("DELETE FROM \(t) WHERE profileId = ?", [id]) }
            try sql.run("DELETE FROM profiles WHERE id = ?", [id])
        }
        for t in ["profiles", "favorites", "recents", "reminders", "progress", "list_item"] { changes.send(t) }
    }

    // ---------------------------------------------------------------------------------------------------- channels

    static let channelCols = "streamId, num, providerNum, name, baseName, quality, icon, epgId, lineEpgId, categoryId, providerCategory, shiftMin, event, eventSub, eventStart, archive, archiveDays, variants, logo"
    static func channel(_ r: SQLRow) -> ChannelEntity {
        ChannelEntity(streamId: r.string(0), num: r.int(1), providerNum: r.int(2), name: r.string(3), baseName: r.string(4), quality: r.string(5), icon: r.stringOrNil(6),
                      epgId: r.stringOrNil(7), lineEpgId: r.stringOrNil(8), categoryId: r.string(9), providerCategory: r.string(10), shiftMin: r.int(11), event: r.stringOrNil(12),
                      eventSub: r.stringOrNil(13), eventStart: r.int64OrNil(14), archive: r.bool(15), archiveDays: r.int(16), variants: r.string(17), logo: r.stringOrNil(18))
    }
    private static let channelColsC = channelCols.split(separator: ",").map { "c." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")

    func channels() -> [ChannelEntity] { rows("SELECT \(AppDB.channelCols) FROM channels ORDER BY num", [], AppDB.channel) }
    func channel(_ id: String) -> ChannelEntity? { one("SELECT \(AppDB.channelCols) FROM channels WHERE streamId = ?", [id], AppDB.channel) }
    func channelCount() -> Int { count("SELECT COUNT(*) FROM channels") }
    func setEpgId(_ id: String, _ epgId: String?) { run("UPDATE channels SET epgId = ? WHERE streamId = ?", [epgId, id]) }
    func setIcon(_ id: String, _ icon: String?) { run("UPDATE channels SET icon = ? WHERE streamId = ?", [icon, id]) }
    func setLogo(_ id: String, _ logo: String?) { run("UPDATE channels SET logo = ? WHERE streamId = ?", [logo, id]) }
    func touchChannels() { changes.send("channels") }

    private static func category(_ r: SQLRow) -> CategoryEntity { CategoryEntity(id: r.string(0), categoryId: r.string(1), kind: r.string(2), name: r.string(3), rawName: r.string(4), order: r.int(5)) }
    func categories(_ kind: String) -> [CategoryEntity] { rows("SELECT id, categoryId, kind, name, rawName, \"order\" FROM categories WHERE kind = ? ORDER BY \"order\"", [kind], AppDB.category) }

    func replaceLive(_ cats: [CategoryEntity], _ chans: [ChannelEntity]) {
        tx {
            try sql.run("DELETE FROM categories WHERE kind = 'live'")
            try sql.run("DELETE FROM channels")
            for c in cats { try sql.run("INSERT OR REPLACE INTO categories(id, categoryId, kind, name, rawName, \"order\") VALUES(?,?,?,?,?,?)", [c.id, c.categoryId, c.kind, c.name, c.rawName, c.order]) }
            for c in chans {
                try sql.run("INSERT OR REPLACE INTO channels(\(AppDB.channelCols)) VALUES(\(AppDB.marks(19)))",
                            [c.streamId, c.num, c.providerNum, c.name, c.baseName, c.quality, c.icon, c.epgId, c.lineEpgId, c.categoryId, c.providerCategory, c.shiftMin, c.event, c.eventSub,
                             c.eventStart, c.archive, c.archiveDays, c.variants, c.logo])
            }
        }
        changes.send("channels")
    }

    func favorites(_ pid: Int64) -> [ChannelEntity] {
        rows("SELECT \(AppDB.channelColsC) FROM channels c JOIN favorites f ON f.streamId = c.streamId WHERE f.profileId = ? ORDER BY f.addedAt DESC", [pid], AppDB.channel)
    }
    func favoriteIds(_ pid: Int64) -> [String] { rows("SELECT streamId FROM favorites WHERE profileId = ?", [pid]) { $0.string(0) } }
    func isFavorite(_ pid: Int64, _ id: String) -> Bool { count("SELECT COUNT(*) FROM favorites WHERE profileId = ? AND streamId = ?", [pid, id]) > 0 }
    func addFavorite(_ pid: Int64, _ id: String, at: Millis = Clock.now) { run("INSERT OR REPLACE INTO favorites(profileId, streamId, addedAt) VALUES(?,?,?)", [pid, id, at], touch: "favorites") }
    func removeFavorite(_ pid: Int64, _ id: String) { run("DELETE FROM favorites WHERE profileId = ? AND streamId = ?", [pid, id], touch: "favorites") }
    func recents(_ pid: Int64) -> [ChannelEntity] {
        rows("SELECT \(AppDB.channelColsC) FROM channels c JOIN recents r ON r.streamId = c.streamId WHERE r.profileId = ? ORDER BY r.watchedAt DESC LIMIT 20", [pid], AppDB.channel)
    }
    func touchRecent(_ pid: Int64, _ id: String) { run("INSERT OR REPLACE INTO recents(profileId, streamId, watchedAt) VALUES(?,?,?)", [pid, id, Clock.now], touch: "recents") }

    // ---------------------------------------------------------------------------------------------------- programmes (EPG)

    static let progCols = "id, epgId, start, stop, title, \"desc\", icon, category, subtitle, episode, year, poster, kind, show, firstRun, highlight, live, src"
    static func programme(_ r: SQLRow) -> ProgrammeEntity {
        ProgrammeEntity(id: r.int64(0), epgId: r.string(1), start: r.int64(2), stop: r.int64(3), title: r.string(4), desc: r.stringOrNil(5), icon: r.stringOrNil(6), category: r.stringOrNil(7),
                        subtitle: r.stringOrNil(8), episode: r.stringOrNil(9), year: r.intOrNil(10), poster: r.stringOrNil(11), kind: r.stringOrNil(12), show: r.stringOrNil(13),
                        firstRun: r.bool(14), highlight: r.bool(15), live: r.bool(16), src: r.string(17))
    }
    private func progs(_ whereOrder: String, _ args: [Any?]) -> [ProgrammeEntity] { rows("SELECT \(AppDB.progCols) FROM programmes \(whereOrder)", args, AppDB.programme) }

    /// Current and following programmes for one channel.
    func upcoming(_ epgId: String, now: Millis = Clock.now, limit: Int = 2) -> [ProgrammeEntity] { progs("WHERE epgId = ? AND stop > ? ORDER BY start LIMIT ?", [epgId, now, limit]) }
    /// Programmes on air at an instant, for all channels.
    func programmesAt(_ at: Millis) -> [ProgrammeEntity] { progs("WHERE start <= ? AND stop > ?", [at, at]) }
    func programmesBetween(_ epgId: String, _ from: Millis, _ to: Millis) -> [ProgrammeEntity] { progs("WHERE epgId = ? AND stop > ? AND start < ? ORDER BY start", [epgId, from, to]) }
    func allProgrammesBetween(_ from: Millis, _ to: Millis) -> [ProgrammeEntity] { progs("WHERE stop > ? AND start < ? ORDER BY epgId, start", [from, to]) }
    func programme(_ id: Int64) -> ProgrammeEntity? { progs("WHERE id = ?", [id]).first }
    /// Other airings of the same title (replicas / next episodes), soonest first.
    func sameTitle(_ title: String, show: String?, exceptId: Int64, from: Millis, limit: Int = 12) -> [ProgrammeEntity] {
        progs("WHERE (title = ? OR (show IS NOT NULL AND show = ?)) AND id != ? AND stop > ? ORDER BY start LIMIT ?", [title, show, exceptId, from, limit])
    }
    func programmesForChannels(_ ids: [String], _ from: Millis, _ to: Millis) -> [ProgrammeEntity] {
        var out = [ProgrammeEntity]()
        for chunk in ids.chunked(400) {
            var args: [Any?] = chunk; args.append(from); args.append(to)
            out += progs("WHERE epgId IN (\(AppDB.marks(chunk.count))) AND stop > ? AND start < ? ORDER BY epgId, start", args)
        }
        return out
    }
    /// Search by title / show name (LIKE patterns), soonest first.
    func searchProgrammes(_ p1: String, _ p2: String, from: Millis, to: Millis, limit: Int = 80) -> [ProgrammeEntity] {
        progs("WHERE (title LIKE ? OR title LIKE ? OR show LIKE ? OR show LIKE ?) AND stop > ? AND start < ? ORDER BY start LIMIT ?", [p1, p2, p1, p2, from, to, limit])
    }
    /// "Segui la tua squadra": sport (or unknown) programmes naming a team in the title, show or subtitle.
    func sportNaming(_ p: String, from: Millis, to: Millis) -> [ProgrammeEntity] {
        progs("WHERE (kind = 'sport' OR kind IS NULL) AND (title LIKE ? OR show LIKE ? OR subtitle LIKE ?) AND stop > ? AND start < ? ORDER BY start LIMIT 400", [p, p, p, from, to])
    }
    func programmeCount() -> Int { count("SELECT COUNT(*) FROM programmes") }

    func replaceProgrammes(_ items: [ProgrammeEntity]) {
        tx {
            try sql.run("DELETE FROM programmes")
            let q = "INSERT INTO programmes(epgId, start, stop, title, \"desc\", icon, category, subtitle, episode, year, poster, kind, show, firstRun, highlight, live, src) VALUES(\(AppDB.marks(17)))"
            for p in items {
                try sql.run(q, [p.epgId, p.start, p.stop, p.title, p.desc, p.icon, p.category, p.subtitle, p.episode, p.year, p.poster, p.kind, p.show, p.firstRun, p.highlight, p.live, p.src])
            }
        }
        changes.send("programmes")
    }

    // ---------------------------------------------------------------------------------------------------- programme meta (TMDB dressing)

    private static let metaCols = "\"key\", found, fetchedAt, tmdbId, media, title, overview, tagline, backdrop, poster, logo, \"cast\", genres, vote, popularity, year, runtime, seasons, episodes"
    private static func pmeta(_ r: SQLRow) -> ProgrammeMetaEntity {
        ProgrammeMetaEntity(key: r.string(0), found: r.bool(1), fetchedAt: r.int64(2), tmdbId: r.int(3), media: r.string(4), title: r.string(5), overview: r.stringOrNil(6), tagline: r.stringOrNil(7),
                            backdrop: r.stringOrNil(8), poster: r.stringOrNil(9), logo: r.stringOrNil(10), cast: r.string(11), genres: r.string(12), vote: r.double(13), popularity: r.double(14),
                            year: r.int(15), runtime: r.int(16), seasons: r.int(17), episodes: r.int(18))
    }
    func foundMetas() -> [ProgrammeMetaEntity] { rows("SELECT \(AppDB.metaCols) FROM programme_meta WHERE found = 1", [], AppDB.pmeta) }
    func programmeMeta(_ key: String) -> ProgrammeMetaEntity? { one("SELECT \(AppDB.metaCols) FROM programme_meta WHERE \"key\" = ?", [key], AppDB.pmeta) }
    func metaKeysFor(_ id: Int, _ media: String) -> [String] { rows("SELECT \"key\" FROM programme_meta WHERE tmdbId = ? AND media = ? AND found = 1", [id, media]) { $0.string(0) } }
    func upsertProgrammeMeta(_ m: ProgrammeMetaEntity) {
        run("INSERT OR REPLACE INTO programme_meta(\(AppDB.metaCols)) VALUES(\(AppDB.marks(19)))",
            [m.key, m.found, m.fetchedAt, m.tmdbId, m.media, m.title, m.overview, m.tagline, m.backdrop, m.poster, m.logo, m.cast, m.genres, m.vote, m.popularity, m.year, m.runtime, m.seasons, m.episodes],
            touch: m.found ? "programme_meta" : nil)
    }
    func purgeMetaMisses(before: Millis) { run("DELETE FROM programme_meta WHERE found = 0 AND fetchedAt < ?", [before]) }

    // ---------------------------------------------------------------------------------------------------- usage + trending

    func usage(_ pid: Int64) -> [UsageEntity] { rows("SELECT profileId, \"key\", seconds, updatedAt FROM usage WHERE profileId = ?", [pid]) { UsageEntity(profileId: $0.int64(0), key: $0.string(1), seconds: $0.double(2), updatedAt: $0.int64(3)) } }
    func usage(_ pid: Int64, _ key: String) -> UsageEntity? {
        one("SELECT profileId, \"key\", seconds, updatedAt FROM usage WHERE profileId = ? AND \"key\" = ?", [pid, key]) { UsageEntity(profileId: $0.int64(0), key: $0.string(1), seconds: $0.double(2), updatedAt: $0.int64(3)) }
    }
    func upsertUsage(_ u: UsageEntity) { run("INSERT OR REPLACE INTO usage(profileId, \"key\", seconds, updatedAt) VALUES(?,?,?,?)", [u.profileId, u.key, u.seconds, u.updatedAt]) }
    func trending() -> [String: Int] { Dictionary(rows("SELECT id, rank FROM trending") { ($0.string(0), $0.int(1)) }, uniquingKeysWith: { a, _ in a }) }
    func trendingAt() -> Millis { one("SELECT MAX(fetchedAt) FROM trending") { $0.int64OrNil(0) }.flatMap { $0 } ?? 0 }
    func replaceTrending(_ items: [TrendingEntity]) {
        tx {
            try sql.run("DELETE FROM trending")
            for t in items { try sql.run("INSERT OR REPLACE INTO trending(id, rank, fetchedAt) VALUES(?,?,?)", [t.id, t.rank, t.fetchedAt]) }
        }
        changes.send("trending")
    }

    // ---------------------------------------------------------------------------------------------------- reminders

    private static func reminder(_ r: SQLRow) -> ReminderEntity { ReminderEntity(profileId: r.int64(0), streamId: r.string(1), at: r.int64(2), title: r.string(3), sub: r.stringOrNil(4), createdAt: r.int64(5)) }
    private static let reminderCols = "profileId, streamId, at, title, sub, createdAt"
    func reminders() -> [ReminderEntity] { rows("SELECT \(AppDB.reminderCols) FROM reminders ORDER BY at", [], AppDB.reminder) }
    func reminderIds(_ pid: Int64) -> [String] { rows("SELECT streamId FROM reminders WHERE profileId = ?", [pid]) { $0.string(0) } }
    func reminder(_ pid: Int64, _ id: String) -> ReminderEntity? { one("SELECT \(AppDB.reminderCols) FROM reminders WHERE profileId = ? AND streamId = ?", [pid, id], AppDB.reminder) }
    func upsertReminder(_ r: ReminderEntity) { run("INSERT OR REPLACE INTO reminders(\(AppDB.reminderCols)) VALUES(?,?,?,?,?,?)", [r.profileId, r.streamId, r.at, r.title, r.sub, r.createdAt], touch: "reminders") }
    func deleteReminder(_ pid: Int64, _ id: String) { run("DELETE FROM reminders WHERE profileId = ? AND streamId = ?", [pid, id], touch: "reminders") }
    func purgeReminders(before: Millis) { run("DELETE FROM reminders WHERE at < ?", [before], touch: "reminders") }

    // ---------------------------------------------------------------------------------------------------- VOD: titles

    private static let titleCols = "tmdbId, media, title, originalTitle, year, posterPath, backdropPath, logoPath, overview, genreIds, keywordIds, castIds, directorIds, originalLanguage, runtimeMin, voteAverage, popularity, certification, seasons, updatedAt, lastAirDate, nextAirDate, status, lastEpisode, lastSeason"
    private static func title(_ r: SQLRow) -> TitleEntity {
        TitleEntity(tmdbId: r.int(0), media: r.string(1), title: r.string(2), originalTitle: r.string(3), year: r.int(4), posterPath: r.stringOrNil(5), backdropPath: r.stringOrNil(6), logoPath: r.stringOrNil(7),
                    overview: r.stringOrNil(8), genreIds: r.string(9), keywordIds: r.string(10), castIds: r.string(11), directorIds: r.string(12), originalLanguage: r.stringOrNil(13), runtimeMin: r.int(14),
                    voteAverage: r.double(15), popularity: r.double(16), certification: r.stringOrNil(17), seasons: r.int(18), updatedAt: r.int64(19), lastAirDate: r.stringOrNil(20), nextAirDate: r.stringOrNil(21),
                    status: r.stringOrNil(22), lastEpisode: r.int(23), lastSeason: r.int(24))
    }
    func upsertTitle(_ t: TitleEntity) {
        run("INSERT OR REPLACE INTO title(\(AppDB.titleCols)) VALUES(\(AppDB.marks(25)))",
            [t.tmdbId, t.media, t.title, t.originalTitle, t.year, t.posterPath, t.backdropPath, t.logoPath, t.overview, t.genreIds, t.keywordIds, t.castIds, t.directorIds, t.originalLanguage, t.runtimeMin,
             t.voteAverage, t.popularity, t.certification, t.seasons, t.updatedAt, t.lastAirDate, t.nextAirDate, t.status, t.lastEpisode, t.lastSeason])
    }
    func title(_ id: Int, _ media: String) -> TitleEntity? { one("SELECT \(AppDB.titleCols) FROM title WHERE tmdbId = ? AND media = ?", [id, media], AppDB.title) }
    /// keys = "<tmdbId>-<media>"
    func titles(_ keys: [String]) -> [TitleEntity] {
        var out = [TitleEntity]()
        for chunk in keys.chunked(400) { out += rows("SELECT \(AppDB.titleCols) FROM title WHERE (tmdbId || '-' || media) IN (\(AppDB.marks(chunk.count)))", chunk, AppDB.title) }
        return out
    }

    // ---------------------------------------------------------------------------------------------------- VOD: progress

    private static let progressCols = "profileId, tmdbId, media, season, episode, positionMs, durationMs, completed, updatedAt"
    private static func progress(_ r: SQLRow) -> ProgressEntity {
        ProgressEntity(profileId: r.int64(0), tmdbId: r.int(1), media: r.string(2), season: r.int(3), episode: r.int(4), positionMs: r.int64(5), durationMs: r.int64(6), completed: r.bool(7), updatedAt: r.int64(8))
    }
    func upsertProgress(_ p: ProgressEntity) {
        run("INSERT OR REPLACE INTO progress(\(AppDB.progressCols)) VALUES(?,?,?,?,?,?,?,?,?)", [p.profileId, p.tmdbId, p.media, p.season, p.episode, p.positionMs, p.durationMs, p.completed, p.updatedAt], touch: "progress")
    }
    func progressForTitle(_ pid: Int64, _ id: Int, _ media: String) -> [ProgressEntity] {
        rows("SELECT \(AppDB.progressCols) FROM progress WHERE profileId = ? AND tmdbId = ? AND media = ? ORDER BY updatedAt DESC", [pid, id, media], AppDB.progress)
    }
    func progressForEpisode(_ pid: Int64, _ id: Int, _ media: String, _ s: Int, _ e: Int) -> ProgressEntity? {
        one("SELECT \(AppDB.progressCols) FROM progress WHERE profileId = ? AND tmdbId = ? AND media = ? AND season = ? AND episode = ?", [pid, id, media, s, e], AppDB.progress)
    }
    /// Latest position per title, for "Continua a guardare".
    func continueWatching(_ pid: Int64) -> [ProgressEntity] {
        rows("SELECT \(AppDB.progressCols) FROM progress WHERE profileId = ? AND updatedAt IN (SELECT MAX(updatedAt) FROM progress WHERE profileId = ? GROUP BY tmdbId, media) ORDER BY updatedAt DESC LIMIT 30", [pid, pid], AppDB.progress)
    }
    func allProgress(_ pid: Int64) -> [ProgressEntity] { rows("SELECT \(AppDB.progressCols) FROM progress WHERE profileId = ? ORDER BY updatedAt DESC LIMIT 400", [pid], AppDB.progress) }
    func clearProgressTitle(_ pid: Int64, _ id: Int, _ media: String) { run("DELETE FROM progress WHERE profileId = ? AND tmdbId = ? AND media = ?", [pid, id, media], touch: "progress") }
    func deleteProgressEpisode(_ pid: Int64, _ id: Int, _ media: String, _ s: Int, _ e: Int) {
        run("DELETE FROM progress WHERE profileId = ? AND tmdbId = ? AND media = ? AND season = ? AND episode = ?", [pid, id, media, s, e], touch: "progress")
    }
    func clearProgress(_ pid: Int64, unfinishedOnly: Bool = false) { run("DELETE FROM progress WHERE profileId = ?" + (unfinishedOnly ? " AND completed = 0" : ""), [pid], touch: "progress") }

    // ---------------------------------------------------------------------------------------------------- VOD: events, list, sources

    func insertEvent(_ e: WatchEventEntity) {
        run("INSERT INTO watch_event(profileId, tmdbId, media, kind, weight, at) VALUES(?,?,?,?,?,?)", [e.profileId, e.tmdbId, e.media, e.kind, e.weight, e.at], touch: "watch_event")
    }
    private static func event(_ r: SQLRow) -> WatchEventEntity { WatchEventEntity(id: r.int64(0), profileId: r.int64(1), tmdbId: r.int(2), media: r.string(3), kind: r.string(4), weight: r.double(5), at: r.int64(6)) }
    func recentEvents(_ pid: Int64, limit: Int = 400) -> [WatchEventEntity] { rows("SELECT id, profileId, tmdbId, media, kind, weight, at FROM watch_event WHERE profileId = ? ORDER BY at DESC LIMIT ?", [pid, limit], AppDB.event) }
    func signalCount(_ pid: Int64) -> Int { count("SELECT COUNT(*) FROM watch_event WHERE profileId = ? AND kind IN ('completed','liked','progress')", [pid]) }
    func recentCompleted(_ pid: Int64, limit: Int = 10) -> [WatchEventEntity] {
        rows("SELECT id, profileId, tmdbId, media, kind, weight, at FROM watch_event WHERE profileId = ? AND kind = 'completed' ORDER BY at DESC LIMIT ?", [pid, limit], AppDB.event)
    }
    func clearEvents(_ pid: Int64) { run("DELETE FROM watch_event WHERE profileId = ?", [pid], touch: "watch_event") }
    /// Latest explicit opinion on a title: liked / disliked / unliked / undisliked (nil = none).
    func feedback(_ pid: Int64, _ id: Int, _ media: String) -> String? {
        one("SELECT kind FROM watch_event WHERE profileId = ? AND tmdbId = ? AND media = ? AND kind IN ('liked','disliked','unliked','undisliked') ORDER BY at DESC, id DESC LIMIT 1", [pid, id, media]) { $0.string(0) }
    }

    func list(_ pid: Int64) -> [ListItemEntity] {
        rows("SELECT profileId, tmdbId, media, addedAt FROM list_item WHERE profileId = ? ORDER BY addedAt DESC", [pid]) { ListItemEntity(profileId: $0.int64(0), tmdbId: $0.int(1), media: $0.string(2), addedAt: $0.int64(3)) }
    }
    func inList(_ pid: Int64, _ id: Int, _ media: String) -> Bool { count("SELECT COUNT(*) FROM list_item WHERE profileId = ? AND tmdbId = ? AND media = ?", [pid, id, media]) > 0 }
    func addToList(_ i: ListItemEntity) { run("INSERT OR IGNORE INTO list_item(profileId, tmdbId, media, addedAt) VALUES(?,?,?,?)", [i.profileId, i.tmdbId, i.media, i.addedAt], touch: "list_item") }
    func removeFromList(_ pid: Int64, _ id: Int, _ media: String) { run("DELETE FROM list_item WHERE profileId = ? AND tmdbId = ? AND media = ?", [pid, id, media], touch: "list_item") }

    func sourceCache(_ id: Int, _ media: String) -> SourceCacheEntity? {
        one("SELECT tmdbId, media, channel, item, title, updatedAt FROM source_cache WHERE tmdbId = ? AND media = ?", [id, media]) {
            SourceCacheEntity(tmdbId: $0.int(0), media: $0.string(1), channel: $0.string(2), item: $0.string(3), title: $0.string(4), updatedAt: $0.int64(5))
        }
    }
    func upsertSourceCache(_ s: SourceCacheEntity) { run("INSERT OR REPLACE INTO source_cache(tmdbId, media, channel, item, title, updatedAt) VALUES(?,?,?,?,?,?)", [s.tmdbId, s.media, s.channel, s.item, s.title, s.updatedAt]) }
    func clearSourceCache(_ id: Int, _ media: String) { run("DELETE FROM source_cache WHERE tmdbId = ? AND media = ?", [id, media]) }

    func vodIndex(_ id: Int, _ media: String) -> VodIndexEntity? {
        one("SELECT tmdbId, media, available, checkedAt FROM vod_index WHERE tmdbId = ? AND media = ?", [id, media]) { VodIndexEntity(tmdbId: $0.int(0), media: $0.string(1), available: $0.bool(2), checkedAt: $0.int64(3)) }
    }
    func upsertVodIndex(_ v: VodIndexEntity) { run("INSERT OR REPLACE INTO vod_index(tmdbId, media, available, checkedAt) VALUES(?,?,?,?)", [v.tmdbId, v.media, v.available, v.checkedAt]) }

    // ---------------------------------------------------------------------------------------------------- downloads

    private static let downloadCols = "id, profileId, tmdbId, media, season, episode, title, sub, poster, backdrop, state, progress, bytes, file, createdAt, error"
    private static func download(_ r: SQLRow) -> DownloadEntity {
        DownloadEntity(id: r.string(0), profileId: r.int64(1), tmdbId: r.int(2), media: r.string(3), season: r.int(4), episode: r.int(5), title: r.string(6), sub: r.stringOrNil(7), poster: r.stringOrNil(8),
                       backdrop: r.stringOrNil(9), state: r.string(10), progress: r.double(11), bytes: r.int64(12), file: r.stringOrNil(13), createdAt: r.int64(14), error: r.stringOrNil(15))
    }
    func downloads() -> [DownloadEntity] { rows("SELECT \(AppDB.downloadCols) FROM downloads ORDER BY createdAt DESC", [], AppDB.download) }
    func download(_ id: String) -> DownloadEntity? { one("SELECT \(AppDB.downloadCols) FROM downloads WHERE id = ?", [id], AppDB.download) }
    func upsertDownload(_ d: DownloadEntity) {
        run("INSERT OR REPLACE INTO downloads(\(AppDB.downloadCols)) VALUES(\(AppDB.marks(16)))",
            [d.id, d.profileId, d.tmdbId, d.media, d.season, d.episode, d.title, d.sub, d.poster, d.backdrop, d.state, d.progress, d.bytes, d.file, d.createdAt, d.error], touch: "downloads")
    }
    func deleteDownload(_ id: String) { run("DELETE FROM downloads WHERE id = ?", [id], touch: "downloads") }
}
