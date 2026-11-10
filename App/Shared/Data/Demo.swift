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
        if core.db.profiles().isEmpty {
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
        if !args.contains("-nxPicker"), core.profiles.current.value == nil, let p = core.db.profiles().first { core.profiles.select(p) }
    }
}
