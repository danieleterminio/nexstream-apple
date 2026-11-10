import Foundation

// Windows-side smoke test of the platform-neutral data layer against the real public sources.
setvbuf(stdout, nil, _IONBF, 0)
Vpn.shared.start()
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "  ok   " : "  FAIL ") + name + (detail.isEmpty ? "" : "  -> " + detail)) }

print("== text")
check("norm", MetaText.norm("Caffè & Città!") == "caffe and citta", MetaText.norm("Caffè & Città!"))
let p1 = ChannelCatalog.parse("IT| RAI 1 FHD")
check("parse rai", p1.name == "Rai 1" && p1.quality == "FHD", "\(p1)")
let p2 = ChannelCatalog.parse("DAZN EVENTO 47 [Hellas Verona - Carrarese | Serie BKT (2026-11-01 16:15:00)]")
check("parse dazn evento", p2.name == "DAZN Evento 47" && p2.event == "Hellas Verona - Carrarese" && p2.eventSub == "Serie BKT" && p2.eventStart != nil, "\(p2)")
let p3 = ChannelCatalog.parse("IT| SKY SPORT CALCIO +1 HD")
check("parse +1", p3.name == "Sky Sport Calcio +1" && p3.shiftMin == 60, "\(p3)")
let p4 = ChannelCatalog.parse("DAZN : SERIE A 3 JUVENTUS")
check("parse dazn serie", p4.name == "DAZN Serie A 3" && p4.event == "Juventus", "\(p4)")
check("number", ChannelCatalog.knownNumber("Rai 1", shiftMin: 0) == 1 && ChannelCatalog.knownNumber("DAZN Evento 47", shiftMin: 0) == 907 && ChannelCatalog.knownNumber("Sky Sport 252", shiftMin: 0) == 252)
check("genre", ChannelCatalog.genreOf("Sky Cinema Uno", providerCategory: "", isEvent: false) == "cinema")
check("epgKey", ChannelCatalog.epgKey("Rai 1 HD  101") == "rai1", ChannelCatalog.epgKey("Rai 1 HD  101"))
check("separator", ChannelCatalog.isSeparator("✦●✦ SPORT ✦●✦") && !ChannelCatalog.isSeparator("Rai 1"))
check("cleanShow", Broadcasters.cleanShowTitle("Un posto al sole - Stag. 30 Ep. 7063 - Puntata del 04/11/2026") == "Un posto al sole", Broadcasters.cleanShowTitle("Un posto al sole - Stag. 30 Ep. 7063 - Puntata del 04/11/2026"))
check("smartCase", Broadcasters.smartCase("SPORT MEDIASET EDIZIONE ORE 13") == "Sport mediaset edizione ore 13", Broadcasters.smartCase("SPORT MEDIASET EDIZIONE ORE 13"))
check("cleanTitle", MetaRepository.cleanTitle("Blade Runner : Director's Cut") == "Blade Runner" && MetaRepository.cleanTitle("Il Padrino (1972)") == "Il Padrino", MetaRepository.cleanTitle("Blade Runner : Director's Cut"))
let m = Match.parse("Fuoriclasse | Fiorentina - Juventus")
check("match", m?.home == "Fiorentina" && m?.away == "Juventus", "\(String(describing: m))")
check("match no", Match.parse("Juventus Story") == nil && Match.parse("Ep. 3 - Qualcosa") == nil)
check("timestamp", XmltvParser.timestamp("20261110203000 +0100") == 1_794_339_000_000, "\(String(describing: XmltvParser.timestamp("20261110203000 +0100")))")
check("variant", Prefs.pickVariant("1|FHD,2|HD,3|HEVC", fallbackId: "1", want: "HD", hevc: true).0 == "2")
check("flag", Crests.flag("Italia") == "https://flagcdn.com/w320/it.png")
check("rx matches", Rx.i(#"(no data plan|n/?a|\W*)"#).matches("N/A") && !Rx.i(#"(no data plan|n/?a|\W*)"#).matches("N/A film"))

print("== database")
let dbUrl = FileManager.default.temporaryDirectory.appendingPathComponent("nxtest-\(UUID().uuidString).sqlite")
let db = try AppDB(url: dbUrl)
let pid = db.insertProfile(ProfileEntity(name: "Daniele", avatarColor: 2))
check("profile insert", pid > 0 && db.profiles().first?.name == "Daniele")
let streams = [
    LiveStream(num: "1", name: "IT| RAI 1 FHD", streamId: "101", streamIcon: nil, epgChannelId: "rai1.it", categoryId: "1", tvArchive: 0),
    LiveStream(num: "2", name: "IT| RAI 1 HD", streamId: "102", streamIcon: nil, epgChannelId: "rai1.it", categoryId: "1", tvArchive: 0),
    LiveStream(num: "3", name: "IT| CANALE 5 HD", streamId: "105", streamIcon: nil, epgChannelId: nil, categoryId: "1", tvArchive: 0),
    LiveStream(num: "4", name: "IT| SKY SPORT UNO FHD", streamId: "201", streamIcon: nil, epgChannelId: nil, categoryId: "2", tvArchive: 0),
    LiveStream(num: "5", name: "IT| SKY CINEMA UNO FHD", streamId: "301", streamIcon: nil, epgChannelId: nil, categoryId: "3", tvArchive: 0),
    LiveStream(num: "6", name: "IT| ITALIA 1 HD", streamId: "106", streamIcon: nil, epgChannelId: nil, categoryId: "1", tvArchive: 0),
    LiveStream(num: "7", name: "IT| RAI 1 +1 HD", streamId: "111", streamIcon: nil, epgChannelId: nil, categoryId: "1", tvArchive: 0),
    LiveStream(num: "8", name: "DAZN : SERIE A 1 JUVENTUS", streamId: "801", streamIcon: nil, epgChannelId: nil, categoryId: "4", tvArchive: 0),
    LiveStream(num: "9", name: "IT| TV8 HD", streamId: "108", streamIcon: nil, epgChannelId: nil, categoryId: "1", tvArchive: 0),
]
let built = ChannelRepository.build(streams, providerCats: ["1": "GENERALE", "2": "SPORT", "3": "CINEMA", "4": "DAZN"], hevcOk: true)
check("build channels", built.count == 8 && built.first?.name == "Rai 1" && built.first?.streamId == "101" && built.first?.variants == "101|FHD,102|HD", built.map { "\($0.num) \($0.name)" }.joined(separator: ", "))
db.replaceLive(ChannelCatalog.genres.enumerated().map { CategoryEntity(id: "live:\($1.id)", categoryId: $1.id, kind: "live", name: $1.label, rawName: $1.id, order: $0) }, built)
check("channels stored", db.channels().count == 8 && db.categories("live").count == 10)
db.addFavorite(pid, "101")
check("favorites", db.favorites(pid).first?.name == "Rai 1" && db.isFavorite(pid, "101"))

let sem = DispatchSemaphore(value: 0)
Task {
    print("== guide sources (network)")
    do {
        let sky = try await Broadcasters.skyChannels()
        check("sky channels", sky.count > 80, "\(sky.count)")
    } catch { check("sky channels", false, "\(error)") }
    let epg = EpgRepository(db: db)
    do {
        let n = try await epg.sync(lineXmltvUrl: "http://127.0.0.1:9/none", channels: db.channels()) { print("     · \($0)") }
        check("epg sync", n > 200, "\(n) programmes — \(epg.lastReport() ?? "")")
    } catch { check("epg sync", false, "\(error)") }
    let chans = db.channels()
    for c in chans {
        let up = c.epgId.map { db.upcoming($0, limit: 2) } ?? []
        let s = up.first.map { Showing(channel: c, programme: $0) }
        print("     \(c.num) \(c.name) [\(c.epgId ?? "-")] logo=\(c.logo != nil): \(s?.cardTitle ?? "—") | \(s?.cardLine ?? "") | \(s?.whenLabel() ?? "") | kind=\(up.first?.kind ?? "?") img=\(up.first?.icon != nil)")
    }
    check("crests", Crests.find("Juventus") != nil && Crests.find("Inter") != nil, "\(Crests.find("Juventus") ?? "nil")")
    check("competition", Crests.competition("Juventus", "Milan") == "Serie A", "\(Crests.competition("Juventus", "Milan") ?? "nil")")
    check("catalog", Crests.catalog().count > 200, "\(Crests.catalog().count) teams; first: \(Crests.catalog().prefix(3).map { $0.name })")

    print("== TMDB / recognition")
    let key = ProcessInfo.processInfo.environment["NX_TMDB"] ?? ""
    if key.isEmpty { print("  (no NX_TMDB key: skipped)") } else {
        let tmdb = TmdbApi(apiKey: key)
        let metaRepo = MetaRepository(db: db, tmdb: tmdb)
        do {
            let tr = try await tmdb.trending("all", window: "day")
            check("trending", tr.count > 10, "\(tr.prefix(3).map { "\($0.displayTitle) [\($0.media)]" })")
            let d = try await tmdb.details("tv", 1396)
            check("details", d.displayTitle == "Breaking Bad" && d.numberOfSeasons == 5 && d.logoPath != nil, "\(d.displayTitle) seasons=\(d.numberOfSeasons) cert=\(d.certification ?? "-") cast=\(d.cast.first?.name ?? "-")")
            let s1 = try await tmdb.season(1396, 1)
            check("season", (s1.episodes?.count ?? 0) == 7, "\(s1.episodes?.count ?? 0)")
            let cat = CatalogRepository(tmdb: tmdb, db: db)
            let rows = await cat.publicRows(false)
            check("public rows", rows.count >= 8, rows.map { "\($0.id):\($0.items.count)" }.joined(separator: " "))
            let recipes = cat.recipes(tvGenres: await cat.genres("tv"), movieGenres: await cat.genres("movie"), kids: false, media: nil)
            check("recipes", recipes.count > 40, "\(recipes.count)")
            let idx = SearchIndex(tmdb: tmdb, dir: FileManager.default.temporaryDirectory)
            await idx.ensure(force: true)
            cat.index = idx
            check("search index", idx.entries.count > 500, "\(idx.entries.count); 'bre' -> \(cat.searchLocal("bre", false).prefix(3).map { $0.displayTitle })")
            var recognised = 0, tried = 0
            let now = Clock.now
            for c in db.channels() {
                guard let e = c.epgId else { continue }
                for p in db.programmesBetween(e, now, now + 8 * Clock.hour).prefix(4) where metaRepo.wantsMeta(p, c) {
                    tried += 1
                    if let m = await metaRepo.enrich(p, c) { recognised += 1; if recognised <= 5 { print("     \(p.title) -> \(m.title) (\(m.media) \(m.year)) logo=\(m.logo != nil)") } }
                }
            }
            check("recognition", tried == 0 || recognised > 0, "\(recognised)/\(tried)")
            await metaRepo.refreshTrending(force: true)
            check("trending table", db.trending().count > 50, "\(db.trending().count)")
        } catch { check("tmdb", false, "\(error)") }
    }
    sem.signal()
}
sem.wait()
try? FileManager.default.removeItem(at: dbUrl)
print("done")
