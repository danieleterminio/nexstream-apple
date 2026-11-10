import Foundation

/// DAZN's public day guide (the web app's "epg" discovery feed, no login): every event of the day with its Italian synopsis,
/// competition, sport, teams and pictures. The line's DAZN channels carry DAZN's own titles in their names, so they can be
/// matched here — and the same feed donates match pictures and synopses to the other channels' sport programmes, whose Sky
/// entries for DAZN-exclusive matches are a generic blue card and a promotional blurb.
enum Dazn {
    private static let epg = "https://epg.discovery.indazn.com/eu/v1/epg?country=it&languageCode=it&date="
    private static let img = "https://images.discovery.indazn.com/eu/v2/eu/image?id="
    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
    private static let vsRx = Rx.i(#"\s+vs\.?\s+"#)

    /// One DAZN event, already in our terms.
    struct Event {
        let id: String, title: String, desc: String?, competition: String, sport: String
        let start: Millis, stop: Millis
        let live: Bool, replay: Bool
        let image: String?, background: String?, poster: String?
        let teams: [String], teamLogos: [String?]
        let normTitle: String, normComp: String
        /// "Fuoriclasse | Fiorentina - Juventus" -> the match part.
        let match: String?
        let normMatch: String?

        init(id: String, title: String, desc: String?, competition: String, sport: String, start: Millis, stop: Millis, live: Bool, replay: Bool,
             image: String?, background: String?, poster: String?, teams: [String], teamLogos: [String?]) {
            self.id = id; self.title = title; self.desc = desc; self.competition = competition; self.sport = sport; self.start = start; self.stop = stop
            self.live = live; self.replay = replay; self.image = image; self.background = background; self.poster = poster; self.teams = teams; self.teamLogos = teamLogos
            normTitle = MetaText.norm(title); normComp = MetaText.norm(competition)
            let m = title.split(separator: "|").map { String($0).trimmed }.first { $0.contains(" - ") || $0.contains(" vs") }
            match = m
            normMatch = m.map { MetaText.norm(Dazn.vsRx.replace($0, " ")) }
        }
    }

    static func image(_ id: String?, width: Int = 720, format: String = "jpg") -> String? {
        guard let i = id, !i.isBlank else { return nil }
        return "\(img)\(i)&quality=70&width=\(width)&format=\(format)"
    }

    /// The guide for `days` days from today (one request per day, in parallel), de-duplicated by event id.
    static func events(days: Int = 5) async -> [Event] {
        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.timeZone = Broadcasters.rome; dayFmt.dateFormat = "yyyy-MM-dd"
        let dates = (0..<days).map { dayFmt.string(from: Date().addingTimeInterval(Double($0) * 86_400)) }
        let pages = await mapConcurrent(dates, limit: 5) { d -> [J] in
            do { return J.parse(try await Http.data(epg + d, headers: ["User-Agent": ua, "Accept": "application/json"]))["Tiles"].array }
            catch { NxLog.w("NxDazn", "day \(d) failed: \(error)"); return [] }
        }
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.timeZone = TimeZone(identifier: "UTC"); iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        var seen = Set<String>(); var out = [Event]()
        for t in pages.flatMap({ $0 }) {
            let title = t["Title"].string
            if t["IsLinear"].bool || title.isBlank { continue }
            guard let start = iso.date(from: t["Start"].string)?.ms else { continue }
            var stop = iso.date(from: t["End"].string)?.ms ?? 0
            if stop <= start || stop - start > 6 * Clock.hour { stop = start + 2 * Clock.hour }
            let eid = t["EventId"].string.isBlank ? t["Id"].string : t["EventId"].string
            if !seen.insert(eid).inserted { continue }
            let type = t["Type"].string
            let compImages = t["Competition"]["Images"].array
            func compImg(_ kind: String) -> String? { compImages.first { $0["ImageType"].string == kind }?["Id"].stringOrNil }
            let contestants = t["Contestants"].array
            out.append(Event(
                id: eid, title: Broadcasters.fixText(title.trimmed), desc: t["Description"].stringOrNil?.trimmed.nilIfBlank.map { Broadcasters.fixText($0) },
                competition: t["Competition"]["Title"].string.trimmed, sport: t["Sport"]["Title"].string.trimmed, start: start, stop: stop,
                live: type.equalsIgnoringCase("Live") || type.equalsIgnoringCase("UpComing"), replay: type.equalsIgnoringCase("CatchUp"),
                image: image(t["Image"]["Id"].stringOrNil), background: image(compImg("image-background"), width: 1280), poster: image(compImg("image-portrait"), width: 480),
                teams: contestants.map { $0["Title"].string.trimmed },
                teamLogos: contestants.map { c in
                    let imgs = c["Images"].array
                    return image(imgs.first { $0["ImageType"].string == "image-tile" }?["Id"].stringOrNil ?? imgs.first?["Id"].stringOrNil, width: 240, format: "png")
                }))
        }
        NxLog.i("NxDazn", "\(out.count) events over \(dates.count) days")
        return out.sortedBy { $0.start }
    }

    private static func programme(_ e: Event, start: Millis? = nil, stop: Millis? = nil) -> ProgrammeEntity {
        ProgrammeEntity(epgId: "", start: start ?? e.start, stop: stop ?? e.stop, title: e.title, desc: e.desc, icon: e.image ?? e.background, category: e.sport.nilIfBlank,
                        subtitle: e.competition.nilIfBlank, poster: e.poster, kind: "sport", show: e.match ?? e.title, live: e.live && !e.replay, src: "dazn")
    }

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init).filter { $0.count >= 3 }) }
    private static func overlap(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        if x.isEmpty || y.isEmpty { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    /// The schedule of one of the line's DAZN channels, from its parsed name:
    ///  - "DAZN Evento N" (one event, title + competition + start in the name) → that event;
    ///  - "DAZN Serie A/B N <team>" → every match of the team in the days fetched;
    ///  - "Zona DAZN Serie A" / "Zona Gol Serie A|B" → DAZN's multi-match programmes.
    static func forChannel(_ c: ChannelEntity, _ events: [Event]) -> [ProgrammeEntity] {
        let name = c.name
        if name.hasPrefix("DAZN Evento"), let ev = c.event {
            let t = MetaText.norm(ev.replacingOccurrences(of: " · ", with: " "))
            let sub = c.eventSub.map { MetaText.norm($0.replacingOccurrences(of: " · ", with: " ")) } ?? ""
            let at = c.eventStart
            func near(_ e: Event) -> Bool { at == nil || abs(e.start - at!) <= 3 * Clock.hour }
            let hit = events.first { e in near(e) && (e.normTitle == t || (e.normMatch != nil && e.normMatch == t)) && (sub.isEmpty || e.normComp == sub || sub.hasSuffix(e.normComp) || e.normComp.hasSuffix(sub)) }
                ?? events.first { e in near(e) && (e.normTitle == t || e.normTitle.hasPrefix(t) || t.hasPrefix(e.normTitle)) }
                ?? events.first { e in at != nil && abs(e.start - at!) <= 2 * Clock.minute && overlap(e.normTitle, t) >= 0.5 }
            guard let h = hit else { return [] }
            let s = at ?? h.start
            return [programme(h, start: s, stop: max(h.stop, s + Clock.hour))]
        }
        if (name.hasPrefix("DAZN Serie A ") || name.hasPrefix("DAZN Serie B ")), let ev = c.event {
            let team = MetaText.norm(ev)
            let league = name.hasPrefix("DAZN Serie A") ? "serie a enilive" : "serie bkt"
            return events.filter { e in e.normComp == league && e.normMatch != nil && e.teams.contains { teamMatches(team, MetaText.norm($0)) } && !e.replay }.map { programme($0) }
        }
        if name == "Zona DAZN Serie A" || name == "Zona DAZN" { return events.filter { $0.normTitle.hasPrefix("zona serie a") }.map { programme($0) } }
        if name == "Zona Gol Serie A" { return events.filter { $0.normTitle.hasPrefix("zona gol") && $0.normComp.contains("serie a") }.map { programme($0) } }
        if name == "Zona Gol Serie B" { return events.filter { $0.normTitle.hasPrefix("zona gol") && $0.normComp.contains("serie b") }.map { programme($0) } }
        return []
    }

    private static let teamStop: Set<String> = ["calcio", "fc", "ssc", "us", "ac", "as", "1913", "1898", "1907", "1909", "1919", "spa"]
    /// "juventus" vs "juventus", "lr vicenza" vs "vicenza", "sudtirol" vs "fc sudtirol".
    private static func teamMatches(_ ours: String, _ theirs: String) -> Bool {
        if ours == theirs { return true }
        let x = words(ours).subtracting(teamStop), y = words(theirs).subtracting(teamStop)
        return !x.isEmpty && !y.isEmpty && (x.isSuperset(of: y) || y.isSuperset(of: x))
    }

    /// Sky's placeholder for matches it does not cover itself: a flat blue card and the same promotional text for every match.
    static func genericArt(_ p: ProgrammeEntity) -> Bool {
        guard let i = p.icon else { return true }
        return i.containsIgnoringCase("HERO_CLEAN") || i.containsIgnoringCase("CLEAN_WIDE")
    }
    static func genericText(_ p: ProgrammeEntity) -> Bool {
        guard let d = p.desc else { return true }
        return d.containsIgnoringCase("Ogni weekend una nuova storia") || d.containsIgnoringCase("ti aspetta su DAZN") || d.containsIgnoringCase("disponibile su DAZN")
    }

    /// The DAZN event that is the same match as `p` (same teams, kick-off within 45 min), if any.
    static func sameEvent(_ p: ProgrammeEntity, _ events: [Event]) -> Event? {
        let source = p.show ?? p.title
        let t = MetaText.norm(vsRx.replace(source, " "))
        if t.count < 6 { return nil }
        func same(_ e: Event) -> Bool { e.normMatch == t || e.normTitle == t || (e.normMatch != nil && overlap(e.normMatch!, t) >= 0.99 && words(t).count >= 2) }
        // the live match at the same time; else (a replay on a linear channel) the same match on any day DAZN lists
        if let e = events.first(where: { abs($0.start - p.start) <= 45 * Clock.minute && !$0.replay && same($0) }) { return e }
        if t.contains(" ") && (source.contains(" - ") || source.lowercased().contains(" vs")) {
            return events.filter { same($0) }.min { abs($0.start - p.start) < abs($1.start - p.start) }
        }
        return nil
    }
}
