import Foundation

/// "Milan - Ferencváros", "Toledo @ Michigan State", "Fuoriclasse | Fiorentina - Juventus" → the two sides.
struct Match: Hashable {
    let home: String
    let away: String
    let text: String

    private static let sep = Rx.i(#"\s+(?:-|–|vs\.?|v\.?|@)\s+"#)
    private static let bad = Rx.i(#"[:/|]|\bep\.?\s*\d|\b(19|20)\d\d\b|\bstag\.|\bpuntata\b"#)

    static func parse(_ s: String?) -> Match? {
        guard let s = s, !s.isBlank else { return nil }
        guard let part = s.split(separator: "|").map({ String($0).trimmed }).first(where: { sep.contains($0) }) else { return nil }
        let sides = sep.split(part)
        if sides.count != 2 { return nil }
        let a = sides[0].trimmed.removingPrefix("LIVE ").removingSuffix(" (Diretta)").trimmed
        let b = sides[1].trimmed.removingPrefix("LIVE ").removingSuffix(" (Diretta)").trimmed
        func ok(_ x: String) -> Bool { (2...32).contains(x.count) && x.split(separator: " ").count <= 4 && !bad.contains(x) && x.contains(where: { $0.isLetter }) }
        if !ok(a) || !ok(b) { return nil }
        return Match(home: a, away: b, text: part)
    }
}

enum TimeText {
    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = pattern; return f
    }
    private static let hm = fmt("HH:mm")
    private static let weekday = fmt("EEE d")
    private static let longDay = fmt("EEEE d MMMM")

    static func time(_ ms: Millis) -> String { hm.string(from: Date(ms: ms)) }
    /// "Domani" / "Ieri" / weekday for a timestamp, nil when today.
    static func dayLabel(_ ms: Millis) -> String? {
        let cal = Calendar.current
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: Date(ms: ms))).day ?? 0
        switch d {
        case 0: return nil
        case 1: return "Domani"
        case -1: return "Ieri"
        default: return weekday.string(from: Date(ms: ms)).capitalizedFirst
        }
    }
    static func longDayLabel(_ ms: Millis) -> String { longDay.string(from: Date(ms: ms)).capitalizedFirst }
    static func duration(minutes: Int) -> String { minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min" }
}

/// One "thing on TV": a channel plus the programme (EPG) or the event (channel name) it is showing, plus TMDB dressing when known.
struct Showing: Hashable, Identifiable {
    let channel: ChannelEntity
    let programme: ProgrammeEntity?
    var meta: ProgrammeMetaEntity? = nil

    var id: String { key }
    var key: String { channel.streamId + ":" + String(programme?.id ?? 0) }

    private static let junkTitle = Rx.i(#"(no data plan|no information|no info|no epg|no programme|no program|n/?a|nessuna informazione|\W*)"#)
    private static let episodeEcho = Rx.i(#"(st|stag|stagione|s)\.?\s*\d+\s*[,·-]?\s*(ep|episodio|e)\.?\s*\d+"#)
    private static let synopsisDate = Rx(#"^\s*\d{1,2}/\d{1,2}/\d{4}\s*[-–:]\s*"#)
    private static let dots = Rx(#"\s*-\s*\.\.\.\s*"#)
    /// Feed-internal ids that some guides put in the episode field ("S92120000 E2026110558").
    private static let junkEpisode = Rx(#"S\d{4,}\s*E\d{4,}"#)
    private static let genericSport: Set<String> = ["sport", "calcio", "sport generico", "altri sport", "eventi", "evento", "live"]
    /// Competitions recognised in a synopsis ("…gara valida per la UEFA Europa League…").
    private static let competitions: [(Rx, String)] = [
        ("champions league", "UEFA Champions League"), ("europa league", "UEFA Europa League"), ("conference league", "UEFA Conference League"),
        ("coppa italia", "Coppa Italia"), (#"serie a\b"#, "Serie A"), (#"serie b\b"#, "Serie B"), (#"serie c\b"#, "Serie C"), ("premier league", "Premier League"),
        ("laliga|liga spagnola", "LaLiga"), ("bundesliga", "Bundesliga"), ("ligue 1", "Ligue 1"), ("nations league", "UEFA Nations League"),
        (#"\bnba\b"#, "NBA"), ("eurolega|euroleague", "EuroLeague"), (#"formula 1|\bf1\b"#, "Formula 1"), ("motogp", "MotoGP"), (#"\batp\b"#, "ATP"), (#"\bwta\b"#, "WTA"),
    ].map { (Rx.i($0.0), $0.1) }

    /// A guide synopsis without the feed's leftovers: a leading broadcast date ("07/11/2026 - …"), ellipses used as separators.
    static func cleanSynopsis(_ raw: String) -> String? {
        var t = dots.replace(synopsisDate.replace(raw, ""), " · ").trimmed
        while let f = t.first, ".… ·".contains(f) { t.removeFirst() }
        return t.trimmed.nilIfBlank
    }

    /// Some feeds fill empty slots with a placeholder ("No Data Plan", "No information"): that is not a programme.
    private var placeholder: Bool { programme.map { Showing.junkTitle.matches($0.title.trimmed) } ?? false }
    var title: String {
        if let t = meta?.title, !t.isBlank { return t }
        if let p = programme, !placeholder { return p.title }
        return channel.event ?? channel.name
    }
    /// Episode line: "S2 E5 · Nome episodio" (a subtitle that only repeats the numbers, "St.6 Ep.1", is dropped).
    var episodeLine: String? {
        guard let p = programme else { return nil }
        var parts = [String]()
        if let e = p.episode, !Showing.junkEpisode.matches(e) { parts.append(e) }
        if let s = p.subtitle, !(p.episode != nil && Showing.episodeEcho.matches(s.trimmed)) { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var sub: String? {
        if let g = meta?.genres, !g.isBlank { return g.components(separatedBy: ", ").prefix(2).joined(separator: " · ") }
        return programme?.category ?? channel.eventSub
    }
    var start: Millis? { programme?.start ?? channel.eventStart }
    var stop: Millis? { programme?.stop ?? channel.eventStart.map { $0 + 2 * Clock.hour } }
    /// Wide art: TMDB textless backdrop for recognised films/series, else the broadcaster's still.
    var image: String? { meta?.backdrop ?? (placeholder ? nil : programme?.icon) }
    /// Sport: the guide says so, or it is an event channel with no guide.
    var isSport: Bool { programme?.kind == "sport" || (programme != nil && programme?.kind == nil && channel.categoryId == "sport") || (programme == nil && channel.event != nil) || (programme == nil && channel.categoryId == "sport") }
    /// The two sides when the sport programme is a match, from the show, title, subtitle or event.
    var match: Match? {
        if !isSport { return nil }
        return Match.parse(programme?.show) ?? Match.parse(programme?.title) ?? Match.parse(programme?.subtitle) ?? Match.parse(channel.event)
    }
    /// The competition of a sport programme: whichever of title / subtitle is not the match, else the event's line.
    var competition: String? {
        if !isSport { return nil }
        let named = [programme?.subtitle, programme?.title, channel.eventSub].compactMap { $0 }
            .first { !$0.isBlank && Match.parse($0) == nil && $0 != programme?.show && !Showing.genericSport.contains($0.lowercased()) }
        if let n = named {
            if let c = Showing.competitions.first(where: { $0.0.contains(n) })?.1, n.count <= c.count + 10 { return c }
            return n
        }
        let text = [programme?.desc, programme?.category].compactMap { $0 }.joined(separator: " ")
        if let c = Showing.competitions.first(where: { $0.0.contains(text) })?.1 { return c }
        if let m = match, let c = Crests.competition(m.home, m.away) { return c }
        return programme?.category?.nilIfBlank
    }
    /// What a card shows as its title: the match for a match.
    var cardTitle: String { match?.text ?? title }
    /// The card's second line next to the time: the competition for a match, else episode / genre.
    var cardLine: String? {
        if match != nil { if let c = competition, c != cardTitle { return c }; return sub }
        return episodeLine ?? sub
    }
    var poster: String? { meta?.poster ?? programme?.poster }
    var logo: String? { meta?.logo?.replacingOccurrences(of: ".svg", with: ".png") }
    var overview: String? {
        if let o = meta?.overview { return o }
        if placeholder { return nil }
        return programme?.desc.flatMap { Showing.cleanSynopsis($0) }
    }
    var isEvent: Bool { programme == nil && channel.event != nil }
    var firstRun: Bool { programme?.firstRun == true }
    var highlight: Bool { programme?.highlight == true }
    /// A real live broadcast (Sky marks them) or a PPV event channel — the only things that get the red DIRETTA badge.
    var isLiveBroadcast: Bool { programme?.live == true || channel.event != nil || channel.categoryId == "events" || (programme != nil && programme!.id < 0) }
    /// Sport we know is a replay (Sky gives live flags for its whole sport schedule).
    var isReplay: Bool { programme != nil && programme!.src == "sky" && programme!.kind == "sport" && !programme!.live }
    /// "Film", "Serie TV", "Sport"… from what the guide or TMDB says.
    var kindLabel: String? {
        switch meta?.media ?? programme?.kind {
        case "movie": return "Film"
        case "tv", "series": return "Serie TV"
        case "sport": return "Sport"
        case "news": return "News"
        case "kids": return "Bambini"
        case "doc": return "Documentario"
        case "music": return "Musica"
        case "show": return "Intrattenimento"
        default: return isEvent ? "Evento" : nil
        }
    }
    func progress(_ now: Millis = Clock.now) -> Double? {
        guard let s = start, let e = stop, e > s else { return nil }
        let v = Double(now - s) / Double(e - s)
        return (0...1).contains(v) ? v : nil
    }
    func isLive(_ now: Millis = Clock.now) -> Bool {
        guard let s = start else { return false }
        return s <= now && (stop ?? Millis.max) > now
    }
    func timeLabel() -> String? {
        guard let s = start else { return nil }
        let day = TimeText.dayLabel(s)
        return (day.map { "\($0) · " } ?? "") + TimeText.time(s) + (stop.map { " – \(TimeText.time($0))" } ?? "")
    }
    /// "Ancora 35 min" for what is on air, "Alle 21:30" / "Domani 21:30" for what is coming.
    func whenLabel(_ now: Millis = Clock.now) -> String? {
        guard let s = start else { return nil }
        if isLive(now) {
            guard let e = stop else { return "In onda" }
            let left = (e - now) / Clock.minute
            return left >= 60 ? "Ancora \(left / 60) h \(left % 60) min" : (left < 1 ? "Ultimo minuto" : "Ancora \(left) min")
        }
        if s > now {
            if let day = TimeText.dayLabel(s) { return "\(day) \(TimeText.time(s))" }
            return s - now < Clock.hour ? "Tra \((s - now) / Clock.minute + 1) min" : "Alle \(TimeText.time(s))"
        }
        return timeLabel()
    }
    /// "Rai 1 · 21:20 – 23:30"
    var metaLine: String { [channel.name, timeLabel()].compactMap { $0 }.joined(separator: "  ·  ") }
}

/// Image URLs at the size a surface needs (Sky resizes on its CDN; TMDB has fixed buckets).
enum Img {
    static func card(_ url: String?) -> String? {
        guard let u = url else { return nil }
        if u.hasPrefix(Broadcasters.skyImg) { return Broadcasters.sized(u, 640, 360) }
        if u.contains("image.tmdb.org") { return u.replacingOccurrences(of: "/w1280/", with: "/w780/").replacingOccurrences(of: "/original/", with: "/w780/") }
        return u
    }
    static func hero(_ url: String?) -> String? {
        guard let u = url else { return nil }
        return u.hasPrefix(Broadcasters.skyImg) ? Broadcasters.sized(u, 1280, 720) : u
    }
    static func tmdb(_ path: String?, _ size: String = "w500") -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/\(size)\(p.replacingOccurrences(of: ".svg", with: ".png"))"
    }
}
