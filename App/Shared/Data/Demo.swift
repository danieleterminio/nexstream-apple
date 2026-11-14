import Foundation

/// Launch arguments used by the build pipeline to look at the app without a real line (the build machines have neither
/// the VPN nor a subscription): `-nxDemo` fills the channel list with well-known channels and lets the public guides and
/// TMDB dress them. Nothing here runs unless the argument is given.
enum Demo {
    static let args = ProcessInfo.processInfo.arguments
    static var enabled: Bool { args.contains("-nxDemo") }
    static func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// Player screenshots: the `-nxPlayerPanel` state is applied once per run (the next episode or channel must not
    /// apply it again).
    @MainActor static var playerPanelDone = false
    /// A stream to play instead of the line's channels (player tests).
    static var liveTestUrl: String? { value("-nxLiveTest") }

    private static let names = [
        "RAI 1 FHD", "RAI 1 HD", "RAI 2 FHD", "RAI 3 FHD", "RETE 4 HD", "CANALE 5 FHD", "CANALE 5 HD", "ITALIA 1 FHD", "LA 7 HD", "TV8 HD", "NOVE HD",
        "20 MEDIASET HD", "RAI 4 HD", "IRIS HD", "RAI 5 HD", "RAI MOVIE HD", "RAI PREMIUM HD", "CIELO HD", "LA 5 MEDIASET HD", "DISCOVERY REAL TIME HD",
        "CINE 34 HD", "FOCUS HD", "TOP CRIME HD", "BOING HD", "RAI GULP HD", "RAI YOYO HD", "CARTOONITO HD", "RAI NEWS 24 HD", "SKY TG 24 HD", "TGCOM24 HD", "DMAX HD",
        "SKY UNO FHD", "SKY ATLANTIC FHD", "SKY SERIES FHD", "SKY CINEMA UNO FHD", "SKY CINEMA DUE FHD", "SKY CINEMA COLLECTION FHD", "SKY CINEMA FAMILY FHD", "SKY CINEMA ACTION FHD",
        "SKY CINEMA SUSPENSE FHD", "SKY CINEMA ROMANCE FHD", "SKY CINEMA DRAMA FHD", "SKY CINEMA COMEDY FHD", "SKY SPORT 24 FHD", "SKY SPORT UNO FHD", "SKY SPORT CALCIO FHD",
        "SKY SPORT TENNIS FHD", "SKY SPORT ARENA FHD", "SKY SPORT MAX FHD", "SKY SPORT F1 FHD", "SKY SPORT MOTOGP FHD", "SKY SPORT NBA FHD", "EUROSPORT 1 FHD", "EUROSPORT 2 FHD",
        "SKY DOCUMENTARIES HD", "SKY NATURE HD", "DISCOVERY CHANNEL HD", "HISTORY HD", "COMEDY CENTRAL HD", "MTV HD", "DEA KIDS HD", "NICK JR HD", "CARTOON NETWORK HD",
        "RAI 1 +1 HD", "CANALE 5 +1 HD", "DAZN 1 FHD", "DAZN : SERIE A 1 JUVENTUS", "DAZN : SERIE A 2 INTER", "DAZN : SERIE A 3 MILAN", "DAZN : ZONA DAZN SERIE A",
    ]

    /// Fake line + channels + a profile, once.
    static func prepare(_ core: NexCore) {
        guard enabled else { return }
        if core.session.current.value == nil { core.session.save(LineSession(username: "demo", password: "demo", base: "http://127.0.0.1:9", expiringAt: "2027-12-31")) }
        if !core.channels.hasChannels() {
            var streams = [LiveStream]()
            for (i, n) in names.enumerated() {
                let cat = n.contains("SPORT") || n.contains("DAZN") ? "2" : (n.contains("CINEMA") ? "3" : "1")
                streams.append(LiveStream(num: String(i + 1), name: "IT| " + n, streamId: String(1000 + i), streamIcon: nil, epgChannelId: nil, categoryId: cat, tvArchive: 0))
            }
            let built = ChannelRepository.build(streams, providerCats: ["1": "GENERALE", "2": "SPORT", "3": "CINEMA"], hevcOk: true)
            let used = Set(built.map { $0.categoryId })
            let cats = ChannelCatalog.genres.filter { used.contains($0.id) }.enumerated().map { CategoryEntity(id: "live:\($1.id)", categoryId: $1.id, kind: "live", name: $1.label, rawName: $1.id, order: $0) }
            core.db.replaceLive(cats, built)
        }
        core.db.setMeta("live_sync", String(Clock.now))
        if args.contains("-nxDemoEpg") { seedEpg(core) }
        // -nxNoProfiles: the very first start, before any profile exists
        if core.db.profiles().isEmpty && !args.contains("-nxNoProfiles") {
            let id = core.profiles.add(name: "Daniele", color: 1, kids: false, icon: 0, maturity: 2, pin: nil)
            _ = core.profiles.add(name: "Bimbi", color: 3, kids: true, icon: 2, maturity: 0, pin: nil)
            if args.contains("-nxSeed") {
                // a little history so the personal rows have something to show
                core.db.addFavorite(id, "1000"); core.db.addFavorite(id, "1005"); core.db.addFavorite(id, "1044")
                for (tid, media) in [(1396, "tv"), (1399, "tv"), (27205, "movie"), (603, "movie")] {
                    core.db.addToList(ListItemEntity(profileId: id, tmdbId: tid, media: media))
                    core.db.insertEvent(WatchEventEntity(profileId: id, tmdbId: tid, media: media, kind: "liked", weight: 0.8))
                }
                core.db.upsertProgress(ProgressEntity(profileId: id, tmdbId: 1396, media: "tv", season: 1, episode: 3, positionMs: 1_200_000, durationMs: 2_880_000, completed: false))
                core.db.upsertProgress(ProgressEntity(profileId: id, tmdbId: 27205, media: "movie", positionMs: 3_000_000, durationMs: 8_880_000, completed: false))
                core.db.setMeta("teams.\(id)", jsonString([["n": "Juventus", "c": "https://a.espncdn.com/i/teamlogos/soccer/500/111.png"]]))
            }
        }
        if args.contains("-nxSeedDownload") && core.db.downloads().isEmpty, let pid = core.db.profiles().first?.id {
            // the downloads page as the VPN gate shows it: one saved, one waiting for the VPN
            core.db.upsertDownload(DownloadEntity(id: "movie-603-0-0", profileId: pid, tmdbId: 603, media: "movie", season: 0, episode: 0, title: "Matrix", sub: "1999",
                                                  poster: "/aOIuZAjPaRIE6CMzbazvcHuHXDc.jpg", backdrop: nil, state: "done", progress: 1, bytes: 1_450_000_000, file: "movie-603-0-0.mp4"))
            core.db.upsertDownload(DownloadEntity(id: "tv-1396-1-4", profileId: pid, tmdbId: 1396, media: "tv", season: 1, episode: 4, title: "Breaking Bad", sub: "S1 E4 · Cancer Man",
                                                  poster: "/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg", backdrop: nil, state: "queued", progress: 0, bytes: 0, file: nil))
        }
        if !args.contains("-nxPicker"), core.profiles.current.value == nil, let p = core.db.profiles().first { core.profiles.select(p) }
    }

    /// `-nxDemoEpg`: a made-up guide for the demo channels (from 3 h ago to 12 h ahead), so the live player's info bar,
    /// zap banner, channel list, guide and programme panels have something to show on the build machines.
    static func seedEpg(_ core: NexCore) {
        let shows: [(String, String, String, String)] = [
            ("Il commissario Montalbano", "series", "Serie TV", "Montalbano indaga sulla scomparsa di un anziano professore: una vecchia fotografia lo porta lontano da Vigata."),
            ("Tg1", "news", "Notiziario", "Il telegiornale con le notizie del giorno, gli approfondimenti e il meteo."),
            ("Milan - Napoli", "sport", "Serie A", "Il big match della giornata in diretta da San Siro, con il pre partita e le interviste."),
            ("Interstellar", "movie", "Film", "Un gruppo di esploratori viaggia attraverso un wormhole alla ricerca di un nuovo pianeta per l'umanità."),
            ("Pechino Express", "show", "Intrattenimento", "Le coppie in gara attraversano l'Asia con un euro al giorno: oggi la tappa più lunga."),
            ("Superquark", "doc", "Documentario", "Piero Angela racconta la scienza: le stelle di neutroni, il sonno degli animali e la memoria."),
            ("Masterchef Italia", "show", "Intrattenimento", "La prova in esterna mette alla prova la brigata: cento coperti in una masseria pugliese."),
            ("Gomorra - La serie", "series", "Serie TV", "Genny deve scegliere da che parte stare mentre Secondigliano torna a bruciare."),
        ]
        let now = Clock.now
        let slot = 30 * Clock.minute
        var chans = [ChannelEntity]()
        var progs = [ProgrammeEntity]()
        for (i, c) in core.db.channels().enumerated() {
            var x = c
            let e = c.epgId ?? "demo.\(c.streamId)"
            x.epgId = e
            chans.append(x)
            var t = now - now % slot - Millis(i % 4 + 1) * 15 * Clock.minute - 3 * Clock.hour
            var j = i
            while t < now + 12 * Clock.hour {
                let s = shows[j % shows.count]
                let len = Millis([45, 60, 90, 120, 30][(j * 7 + i) % 5]) * Clock.minute
                progs.append(ProgrammeEntity(epgId: e, start: t, stop: t + len, title: s.0, desc: s.3, category: s.2, kind: s.1, live: s.1 == "sport", src: "demo"))
                t += len
                j += 1
            }
        }
        core.db.replaceLive(core.db.categories("live"), chans)
        core.db.replaceProgrammes(progs)
    }
}
