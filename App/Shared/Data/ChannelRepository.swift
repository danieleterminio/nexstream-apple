import Foundation

/// Live channels: syncs the Xtream live list into the database through `ChannelCatalog` — clean names, our genres and
/// numbering, per-quality duplicates merged into one channel with the best variant chosen.
///
/// Everything read here is already **per profile**: favourites and recents belong to the current profile, and for a kids
/// profile only what a child may see comes back — the "Bambini" genre always, any other channel only while it is airing a
/// programme the guide classifies as for kids (never news, sport, events, cinema).
final class ChannelRepository {
    private let db: AppDB
    private let profiles: Profiles
    init(db: AppDB, profiles: Profiles) { self.db = db; self.profiles = profiles }

    private func kidsEpgNow() -> Set<String> {
        Set(db.programmesAt(Clock.now).filter { ChannelRepository.isKidsProgramme($0) }.map { $0.epgId })
    }
    private func forProfile(_ list: [ChannelEntity]) -> [ChannelEntity] {
        if !profiles.isKids { return list }
        let k = kidsEpgNow()
        return list.filter { ChannelRepository.allowedForKids($0, k) }
    }

    /// All channels the current profile may see, in number order.
    func visible() -> [ChannelEntity] { forProfile(db.channels()) }
    /// All channels, unfiltered (sync, EPG, metadata).
    func all() -> [ChannelEntity] { db.channels() }
    func get(_ id: String) -> ChannelEntity? { db.channel(id) }
    func favorites() -> [ChannelEntity] { forProfile(db.favorites(profiles.id)) }
    func favoriteIds() -> Set<String> { Set(db.favoriteIds(profiles.id)) }
    func recents() -> [ChannelEntity] { forProfile(db.recents(profiles.id)) }
    /// Genres that have at least one visible channel.
    func categories(of chans: [ChannelEntity]) -> [CategoryEntity] {
        let used = Set(chans.map { $0.categoryId })
        return db.categories("live").filter { used.contains($0.categoryId) }
    }
    /// May the current profile open this channel? (deep links, reminders, zapping lists).
    func isVisible(_ c: ChannelEntity) -> Bool { !profiles.isKids || ChannelRepository.allowedForKids(c, kidsEpgNow()) }
    /// For a kids profile, a programme on a non-kids channel is shown only if it is for kids itself.
    func allowedProgramme(_ c: ChannelEntity, _ p: ProgrammeEntity?) -> Bool {
        if !profiles.isKids || c.categoryId == "kids" { return true }
        guard let p = p else { return false }
        return ChannelRepository.isKidsProgramme(p) && !ChannelRepository.kidsBlocked.contains(c.categoryId)
    }
    func hasChannels() -> Bool { db.channelCount() > 0 }

    func isFavorite(_ id: String) -> Bool { db.isFavorite(profiles.id, id) }
    @discardableResult
    func toggleFavorite(_ id: String) -> Bool {
        let pid = profiles.id
        if pid == 0 { return false }
        let now = db.isFavorite(pid, id)
        if now { db.removeFavorite(pid, id) } else { db.addFavorite(pid, id) }
        return !now
    }
    func touchRecent(_ id: String) { let pid = profiles.id; if pid > 0 { db.touchRecent(pid, id) } }
    func lastSync() -> Millis { db.metaInt64("live_sync") }

    /// Full refresh of categories + channels. Keeps the EPG ids already resolved for unchanged channels. Returns the number of logical channels.
    func sync(_ client: XtreamClient, hevcOk: Bool = true) async throws -> Int {
        let cats = try await client.liveCategories()
        let streams = try await client.liveStreams()
        let catName = Dictionary(cats.map { ($0.categoryId, $0.categoryName) }, uniquingKeysWith: { a, _ in a })
        let keep = Set(cats.filter { !ChannelCatalog.isJunkCategory($0.categoryName) }.map { $0.categoryId })
        let previous = Dictionary(db.channels().map { ($0.streamId, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = streams.filter { keep.contains($0.categoryId ?? "") && !ChannelCatalog.isSeparator($0.name) }
        let grouped = ChannelRepository.build(wanted, providerCats: catName, hevcOk: hevcOk).map { c -> ChannelEntity in
            guard let p = previous[c.streamId], p.lineEpgId == c.lineEpgId else { return c }
            var x = c; x.epgId = p.epgId; x.icon = p.icon ?? c.icon; x.logo = p.logo
            return x
        }
        let used = Set(grouped.map { $0.categoryId })
        let catEntities = ChannelCatalog.genres.filter { used.contains($0.id) }.enumerated().map { i, g in
            CategoryEntity(id: "live:\(g.id)", categoryId: g.id, kind: "live", name: g.label, rawName: g.id, order: i)
        }
        db.replaceLive(catEntities, grouped)
        db.setMeta("live_sync", String(Clock.now))
        return grouped.count
    }

    /// Guides sometimes file a newscast under "Cartoni animati": a news-looking title is never a kids programme.
    private static let newsy = Rx.i(#"\b(tg\d?|telegiornale|tgr|notiziario|meteo|news|edizione|rassegna|speciale tg)\b"#)
    static func isKidsProgramme(_ p: ProgrammeEntity) -> Bool { p.kind == "kids" && !newsy.contains(p.title) }
    /// Genres a child never sees, whatever the guide says about the programme.
    static let kidsBlocked: Set<String> = ["news", "sport", "events", "cinema"]
    static func allowedForKids(_ c: ChannelEntity, _ kidsEpg: Set<String>) -> Bool {
        if c.categoryId == "kids" { return true }
        guard let e = c.epgId else { return false }
        return !kidsBlocked.contains(c.categoryId) && kidsEpg.contains(e)
    }

    private static func rank(_ q: String, _ hevcOk: Bool) -> Int {
        switch q { case "UHD": return 5; case "FHD": return 4; case "HD": return 3; case "HEVC": return hevcOk ? 2 : 0; default: return 1 }
    }

    /// Parse, merge variants, classify, number. Pure.
    static func build(_ streams: [LiveStream], providerCats: [String: String], hevcOk: Bool) -> [ChannelEntity] {
        struct Var { let s: LiveStream; let p: ChannelCatalog.Parsed }
        var order = [String](); var byKey = [String: [Var]]()
        for s in streams {
            let p = ChannelCatalog.parse(s.name)
            // same clean name = same channel in several qualities; event channels that share a name (LBA TV per team) stay apart
            let key = p.name.lowercased() + (p.event.map { "|\($0)" } ?? "")
            if byKey[key] == nil { order.append(key); byKey[key] = [] }
            byKey[key]!.append(Var(s: s, p: p))
        }
        var out = [ChannelEntity]()
        for key in order {
            guard let vs = byKey[key], var best = vs.first else { continue }
            for v in vs where rank(v.p.quality, hevcOk) > rank(best.p.quality, hevcOk) { best = v }
            let p = best.p
            let provCat = providerCats[best.s.categoryId ?? ""] ?? ""
            let genre = ChannelCatalog.genreOf(p.name, providerCategory: provCat, isEvent: p.event != nil || p.eventSub != nil)
            let lineEpg = vs.compactMap { $0.s.epgChannelId?.nilIfBlank }.first
            out.append(ChannelEntity(
                streamId: best.s.streamId, num: ChannelCatalog.knownNumber(p.name, shiftMin: p.shiftMin) ?? 0, providerNum: Int(best.s.num ?? "") ?? 0,
                name: p.name, baseName: p.name.lowercased(), quality: p.quality, icon: vs.compactMap { $0.s.streamIcon?.nilIfBlank }.first,
                epgId: lineEpg, lineEpgId: lineEpg, categoryId: genre, providerCategory: provCat, shiftMin: p.shiftMin,
                event: p.event, eventSub: p.eventSub, eventStart: p.eventStart, archive: vs.contains { $0.s.tvArchive == 1 }, archiveDays: 2,
                variants: vs.map { "\($0.s.streamId)|\($0.p.quality)" }.joined(separator: ",")))
        }
        // numbering: explicit numbers first, then fill each genre's fallback range skipping used numbers
        var used = Set(out.filter { $0.num > 0 }.map { $0.num })
        var next = Dictionary(uniqueKeysWithValues: ChannelCatalog.genres.map { ($0.id, $0.fallbackFrom) })
        for i in out.indices where out[i].num <= 0 {
            var n = next[out[i].categoryId] ?? 1000
            while used.contains(n) { n += 1 }
            used.insert(n); next[out[i].categoryId] = n + 1
            out[i].num = n
        }
        return out.sortedBy { $0.num }
    }
}
