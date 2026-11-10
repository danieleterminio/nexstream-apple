import Foundation

/// Public web guides of the Italian broadcasters (no keys, no sign-up). Not official APIs: every call is wrapped so a change
/// on their side only drops that source and the EPG falls back to the next one (see `EpgRepository`).
///
///  - Sky Guida TV  (apid.sky.it/gtv)            : ~140 channels incl. Rai/Mediaset/La7/Discovery, clean stills, synopsis,
///                                                  typed URLs (/film/, /serie-tv/, /sport/) that tell what a programme is.
///  - RaiPlay palinsesto (raiplay.it/palinsesto)  : Rai channels, big images, clean programme names.
///  - Mediaset Infinity listings (theplatform feed): Mediaset channels, stills, descriptions.
enum Broadcasters {
    static let skyImg = "https://guidatv.sky.it"

    private static func get(_ url: String) async throws -> Data {
        try await Http.data(url, headers: ["User-Agent": Http.browserUA, "Accept": "application/json"])
    }

    // ------------------------------------------------------------------------------------------------------------------ Sky

    struct SkyChannel { var id: Int; var name: String; var number: Int; var logoDark: String? }

    static func skyChannels() async throws -> [SkyChannel] {
        J.parse(try await get("https://apid.sky.it/gtv/v1/channels?env=DTH"))["channels"].array.map {
            SkyChannel(id: $0["id"].int, name: $0["name"].string, number: $0["number"].int, logoDark: $0["logoDark"].stringOrNil)
        }
    }

    /// Our channel name -> Sky channel, by loose name key (Sky has nine "Sky Sport" named after their number).
    static func skyIndex(_ chs: [SkyChannel]) -> [String: SkyChannel] {
        var out = [String: SkyChannel]()
        for c in chs.sortedBy({ $0.number }) {
            let name = c.name.trimmed.equalsIgnoringCase("Sky Sport") && (251...259).contains(c.number) ? "Sky Sport \(c.number)" : c.name
            let k = key(name)
            if out[k] == nil { out[k] = c }
        }
        return out
    }
    private static let dtt = Rx.i(#"\b(dtt|\(dtt\))"#)
    static func key(_ name: String) -> String { ChannelCatalog.epgKey(dtt.replace(name, "")) }

    /// Our names whose Sky name differs beyond the loose key.
    static let skyAlias: [String: String] = [
        "Discovery Channel": "Discovery", "Sky Sport NBA": "Sky Sport Basket", "EQU TV": "EQUtv", "Italia 2": "Mediaset Italia2 HD",
        "Sky Sport 24": "Sky Sport24", "Rai 4K": "Rai 1 HD", "Sky Cinema Due": "Sky Cinema Stories",
    ]

    private static func isoFmt() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f
    }

    /// Sky events for `ids` from `from` for `days` days. Sky returns only events *starting* inside the window, caps a response
    /// at ~14 channels, and — the catch — silently drops the free-to-air channels (Rai, Mediaset, La7…) from any request that
    /// also names a pay channel. So: day 1 is asked in groups of 8; the channels that did not answer are asked again among
    /// themselves; the following days keep those two tiers apart. 4 calls in parallel.
    static func skyEvents(_ ids: [Int], from: Millis, days: Int) async -> [ProgrammeEntity] {
        func fetch(_ group: [Int], _ day: Int) async -> [ProgrammeEntity] {
            let f = isoFmt()
            let a = f.string(from: Date(ms: from + Millis(day) * Clock.day)), b = f.string(from: Date(ms: from + Millis(day + 1) * Clock.day))
            let url = "https://apid.sky.it/gtv/v1/events?from=\(a)&to=\(b)&pageSize=999&pageNum=0&env=DTH&channels=\(group.map(String.init).joined(separator: ","))"
            do { return J.parse(try await get(url))["events"].array.compactMap { skyProgramme($0, f) } }
            catch { NxLog.w("NxEpg", "sky \(group.count) ch day \(day): \(error)"); return [] }
        }
        func fetchAll(_ tier: [Int], _ day: Int) async -> [ProgrammeEntity] {
            await mapConcurrent(tier.chunked(8), limit: 4) { g in await fetch(g, day) }.flatMap { $0 }
        }
        func idsOf(_ l: [ProgrammeEntity]) -> Set<Int> { Set(l.compactMap { Int($0.epgId.removingPrefix("sky:")) }) }

        let all = ids.distinct
        let first = await fetchAll(all, 0)
        let pay = idsOf(first)
        let second = await fetchAll(all.filter { !pay.contains($0) }, 0)
        let free = idsOf(second)
        NxLog.i("NxEpg", "sky: \(pay.count) pay + \(free.count) free channels answer, \(all.count - pay.count - free.count) without data")
        let tiers = [all.filter { pay.contains($0) }, all.filter { free.contains($0) }].filter { !$0.isEmpty }
        var jobs = [([Int], Int)]()
        if days > 1 { for d in 1..<days { for t in tiers { jobs.append((t, d)) } } }
        let rest = await mapConcurrent(jobs, limit: 2) { j in await fetchAll(j.0, j.1) }.flatMap { $0 }
        return first + second + rest
    }

    private static let uuidRx = Rx(#"^[0-9a-f-]{36}$"#)
    private static let epPrefix = Rx.i(#"^Ep\.?\s*\d+\s*-\s*"#)
    private static let epOnly = Rx.i(#"^Ep\.?\s*\d+$"#)
    private static let stagTail = Rx(#"-stag-\d+.*$"#)
    private static let epOrPuntata = Rx.i(#"^(ep\.?|puntata)\s*\d+$"#)
    private static let filmYear = Rx(#"\(\s*([A-Z]{2,4}(?:[/ -][A-Z]{2,4})*)\s+((?:19|20)\d\d)\s*\)\s*$"#)
    /// Real artwork lives under a content UUID; flat files like "/uuid/DTT_Scene_x.png" are generic genre art (and 403).
    private static let realArt = Rx(#"/uuid/[0-9a-f]{8}-[0-9a-f]{4}-"#)
    private static let genericSport = Rx.i(#"^(\d+\s*[aª°]?\s*(giornata|turno|tappa|round|day|sessione)|giornata|turno|qualifiche|prove libere|sprint|finale|semifinal[ei]|quarti|ottavi|day \d+|round \d+|tappa \d+|warm up|gara\b)"#)

    private static func skyProgramme(_ e: J, _ fmt: DateFormatter) -> ProgrammeEntity? {
        guard let start = fmt.date(from: e["starttime"].string)?.ms, let stop = fmt.date(from: e["endtime"].string)?.ms else { return nil }
        let c = e["content"]
        let path = (c["url"].stringOrNil ?? "").trimming("/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let type = path.first ?? ""
        let genre = c["genre"]["name"].string, sub = c["subgenre"]["name"].string
        let kind: String
        switch type {
        case "film": kind = "movie"
        case "serie-tv": kind = "series"
        case "sport": kind = "sport"
        default:
            if sub.equalsIgnoringCase("Fiction") || sub.equalsIgnoringCase("Telefilm") || sub.containsIgnoringCase("Sit") || sub.containsIgnoringCase("Soap") { kind = "series" }
            else if genre.equalsIgnoringCase("Film") { kind = "movie" }
            else if genre.equalsIgnoringCase("Sport") { kind = "sport" }
            else if genre.equalsIgnoringCase("Informazione") { kind = "news" }
            else if genre.containsIgnoringCase("Ragazzi") { kind = sub.containsIgnoringCase("Musica") ? "music" : "kids" }
            else if sub.containsIgnoringCase("Document") || sub.containsIgnoringCase("Natura") || sub.containsIgnoringCase("Storia") || sub.containsIgnoringCase("Arte") { kind = "doc" }
            else { kind = "show" }
        }
        let eventTitle = e["eventTitle"].stringOrNil
        let raw = fixText(c["contentTitle"].stringOrNil ?? eventTitle ?? "").trimmed
        let evTitle = fixText(eventTitle ?? "").trimmed
        // the show's own name: for series and programmes the URL slug is the reliable one ("/serie-tv/the-big-bang-theory/stagione-12/…")
        var slug: String? = nil
        if type == "serie-tv" { slug = path[safe: 1] }
        else if type == "programmi-tv", let s = path[safe: 2], !s.hasPrefix("stagione-"), !uuidRx.matches(s) { slug = s }
        let cleanRaw = cleanShowTitle(raw)
        var title: String; var subtitle: String? = nil
        switch kind {
        case "movie": title = cleanRaw.isEmpty ? evTitle : cleanRaw
        case "sport":
            var comp: String? = nil
            if type == "sport", let p1 = path[safe: 1], p1 != "calcio" { comp = prettySlug(p1) }
            let ev = evTitle.isEmpty ? raw : evTitle
            // "3a giornata", "Qualifiche", "Day 2": the competition is the real title then
            if let cp = comp, genericSport.contains(ev), !ev.contains(" - ") { title = cp; subtitle = ev } else { title = ev; subtitle = comp }
        case "series":
            let stripped = epPrefix.replace(raw, "")
            let epName: String? = (!stripped.isBlank && !epOnly.matches(stripped)) ? stripped : nil
            let show = slug.map { prettySlug(stagTail.replace($0, "")) }
            if let sh = show, (epName == nil || MetaText.norm(epName!) != MetaText.norm(sh)), !MetaText.norm(cleanRaw).hasPrefix(MetaText.norm(sh)) { title = sh; subtitle = epName }
            else { title = cleanRaw.isEmpty ? (show ?? evTitle) : cleanRaw }
        default:
            let t: String? = (!cleanRaw.isEmpty && !epOrPuntata.matches(cleanRaw)) ? cleanRaw : nil
            title = t ?? slug.map { prettySlug($0) } ?? evTitle
        }
        if title.isBlank { return nil }
        let epN = c["episodeNumber"].intOrNil ?? 0, seN = c["seasonNumber"].intOrNil ?? 0
        let ep: String? = (epN > 0 && (1...300).contains(seN)) ? "S\(seN) E\(epN)" : nil
        var desc: String? = e["eventSynopsis"].stringOrNil.map { cleanSynopsis(fixText($0).trimmed) }?.nilIfBlank
        // films end their synopsis with "(USA 2019)": production year for TMDB
        var year: Int? = nil
        if kind == "movie", let d = desc, let m = filmYear.find(d) {
            year = Int(m[2])
            var dd = d; dd.removeSubrange(m.range); desc = dd.trimmed
        }
        // Sky falls back to generic genre art ("/uuid/DTT_Background_SC_….png", which even answers 403): that is no image
        let images = c["imagesMap"].array
        func img(_ k: String) -> String? {
            guard let u = images.first(where: { $0["key"].string == k })?["img"]["url"].stringOrNil, !u.isBlank, realArt.contains(u) else { return nil }
            return skyImg + u
        }
        let image = img("background") ?? img("scene") ?? img("scene_key_art")
        let poster = img("cover_clean") ?? img("cover")
        let epgTitle = e["epgEventTitle"].stringOrNil ?? ""
        let firstRun = e["primeVision"].bool || epgTitle.containsIgnoringCase("1^TV") || epgTitle.containsIgnoringCase("1a TV")
        let hl = e["programHighlights"].stringOrNil
        let cat = sub.isBlank ? genre : sub
        return ProgrammeEntity(epgId: "sky:\(e["channel"]["id"].int)", start: start, stop: stop, title: title, desc: desc, icon: image, category: cat.nilIfBlank, subtitle: subtitle,
                               episode: ep, year: year, poster: poster, kind: kind, show: (kind == "sport" || kind == "news") ? nil : title,
                               firstRun: firstRun, highlight: hl == "1", live: hl == "L", src: "sky")
    }

    private static let sizeParams = Rx(#"&(w|h|crop)=[^&]*"#)
    /// Sky image URL at a given size (their CDN resizes on the fly). Other URLs pass through untouched.
    static func sized(_ url: String?, _ w: Int, _ h: Int) -> String? {
        guard let u = url, u.hasPrefix(skyImg), !u.contains("/logo/") else { return url }
        return "\(sizeParams.replace(u, ""))&w=\(w)&h=\(h)"
    }

    // ------------------------------------------------------------------------------------------------------------------ Rai

    static let raiSlug: [String: String] = [
        "Rai 1": "rai-1", "Rai 2": "rai-2", "Rai 3": "rai-3", "Rai 4": "rai-4", "Rai 5": "rai-5", "Rai Movie": "rai-movie", "Rai Premium": "rai-premium",
        "Rai Gulp": "rai-gulp", "Rai Yoyo": "rai-yoyo", "Rai Storia": "rai-storia", "Rai News 24": "rai-news-24", "Rai Sport": "rai-sport", "Rai 4K": "rai-4k",
    ]
    static let rome = TimeZone(identifier: "Europe/Rome") ?? TimeZone.current

    /// One Rai channel, `days` days from today (Italian time).
    static func rai(_ slug: String, days: Int) async -> [ProgrammeEntity] {
        var out = [ProgrammeEntity]()
        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.timeZone = rome; dayFmt.dateFormat = "dd-MM-yyyy"
        let tsFmt = DateFormatter(); tsFmt.locale = Locale(identifier: "en_US_POSIX"); tsFmt.timeZone = rome; tsFmt.dateFormat = "dd/MM/yyyy HH:mm"
        for d in 0..<days {
            let day = dayFmt.string(from: Date().addingTimeInterval(Double(d) * 86_400))
            do {
                let root = J.parse(try await get("https://www.raiplay.it/palinsesto/app/\(slug)/\(day).json"))
                for o in root["events"].array {
                    guard let start = tsFmt.date(from: "\(o["date"].string) \(o["hour"].string)")?.ms else { continue }
                    let parts = o["duration"].string.split(separator: ":").compactMap { Int($0) }
                    let dur = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : 0
                    if dur <= 0 { continue }
                    let show = o["program"]["name"].stringOrNil.map { fixText($0) }?.nilIfBlank
                    let name = fixText(o["name"].string)
                    let epT = fixText(o["episode_title"].string)
                    let ep: String? = (!epT.isBlank && epT != name && !epT.hasPrefix("Puntata del")) ? epT : nil
                    let imgRaw = o["image"].string
                    let img: String? = imgRaw.isBlank ? nil : (imgRaw.hasPrefix("http") ? imgRaw : "https://www.raiplay.it" + imgRaw)
                    let season = Int(o["season"].string), epn = Int(o["episode"].string)
                    let cleaned = cleanShowTitle(name)
                    out.append(ProgrammeEntity(epgId: "rai:\(slug)", start: start, stop: start + Millis(dur) * 1000, title: show ?? (cleaned.isBlank ? name : cleaned),
                                               desc: fixText(o["description"].string).nilIfBlank, icon: img, subtitle: ep,
                                               episode: (season != nil && epn != nil && season! < 300) ? "S\(season!) E\(epn!)" : nil, show: show ?? cleaned, src: "rai"))
                }
            } catch { NxLog.w("NxEpg", "rai \(slug) \(day): \(error)") }
        }
        return out
    }

    // ------------------------------------------------------------------------------------------------------------------ Mediaset

    static let mediasetCallSign: [String: String] = [
        "Canale 5": "C5", "Italia 1": "I1", "Rete 4": "R4", "20 Mediaset": "LB", "Iris": "KI", "La5": "KA", "Mediaset Extra": "KQ", "Top Crime": "LT",
        "Italia 2": "I2", "27 Twentyseven": "TS", "Cine34": "B6", "Focus": "FU", "Boing": "KB", "Cartoonito": "LA", "TGcom24": "KF", "Mediaset Italia": "MY",
        "Grande Fratello Regia 1": "B7", "Grande Fratello Regia 2": "B8", "Grande Fratello Un'ora fa": "B9", "Radio Monte Carlo": "BB",
    ]
    private static let msNotice = Rx(#"\n?(PUO' NUOCERE AI MINORI|QUESTO PROGRAMMA E' SOTTOTITOLATO)\.?"#)
    private static let msEp = Rx(#"^Ep\.?\s*\d+\s*-\s*"#)

    static func mediaset(_ callSign: String, from: Millis, days: Int) async -> [ProgrammeEntity] {
        var out = [ProgrammeEntity]()
        for d in 0..<days {
            let a = from + Millis(d) * Clock.day, b = a + Clock.day
            do {
                let root = J.parse(try await get("https://api-ott-prod-fe.mediaset.net/PROD/play/feed/allListingFeedEpg/v2.0?byListingTime=\(a)~\(b)&byCallSign=\(callSign)"))
                for en in root["response"]["entries"].array {
                    for o in en["listings"].array {
                        guard let start = o["startTime"].int64OrNil, let stop = o["endTime"].int64OrNil else { continue }
                        let p = o["program"]
                        let epgTitle = o["mediasetlisting$epgTitle"].string
                        let brand = p["mediasetprogram$brandTitle"].stringOrNil?.nilIfBlank
                        let ptitle = p["title"].string
                        var title = epgTitle.isBlank ? ptitle : epgTitle
                        if let br = brand, br.count > 1, br != "0" { title = br }
                        let thumbs = p["thumbnails"].dict
                        var thumb: String? = nil
                        for k in ["image_keyframe_poster-1280x720", "image_horizontal_cover-1920x1080", "image_horizontal_cover"] {
                            if let u = thumbs[k]?["url"].stringOrNil?.nilIfBlank { thumb = u; break }
                        }
                        if thumb == nil { thumb = thumbs.values.first?["url"].stringOrNil }
                        let genres = p["mediasetprogram$genres"].array.compactMap { $0.stringOrNil }
                        let rawDesc = o["description"].string.isBlank ? p["description"].string : o["description"].string
                        let desc = msNotice.replace(rawDesc, "").trimmed
                        let sub: String? = (!ptitle.isBlank && ptitle != title) ? msEp.replace(ptitle, "") : nil
                        out.append(ProgrammeEntity(epgId: "ms:\(callSign)", start: start, stop: stop, title: title, desc: desc.nilIfBlank, icon: thumb, category: genres.first,
                                                   subtitle: sub, kind: kindFromCategory(genres.first), show: title, src: "mediaset"))
                    }
                }
            } catch { NxLog.w("NxEpg", "mediaset \(callSign): \(error)") }
        }
        return out
    }

    // ------------------------------------------------------------------------------------------------------------------ text

    static func kindFromCategory(_ cat: String?) -> String? {
        let c = (cat ?? "").lowercased()
        if c.isEmpty { return nil }
        if c.hasPrefix("film") || c == "cinema" { return "movie" }
        if c.contains("serie") || c.contains("fiction") || c.contains("telefilm") || c.contains("sit") || c.contains("soap") { return "series" }
        if c.contains("sport") || c.contains("calcio") || c.contains("tennis") || c.contains("motori") || c.contains("basket") { return "sport" }
        if c.contains("tg") || c.contains("telegiornale") || c.contains("notizi") || c.contains("informazione") || c == "news" { return "news" }
        if c.contains("cartoni") || c.contains("bambini") || c.contains("ragazzi") || c.contains("animazione") { return "kids" }
        if c.contains("document") { return "doc" }
        return nil
    }

    /// "Stag. 2026 - Affari tuoi" / "Un posto al sole - Stag. 30 Ep. 7063 - Puntata del 04/11/2026" / "4 di sera '26/'27, 39" -> the show name.
    static func cleanShowTitle(_ s: String) -> String {
        var t = s.trimmed
        // the rules feed each other ("Forum '26 -'27, 45"): apply until nothing changes
        for _ in 0..<3 { let before = t; t = cleanOnce(t); if t == before { break } }
        return smartCase(t)
    }

    private static let cleanRules: [Rx] = [
        Rx.i(#"^Stag\.?\s*\d{2,4}\s*-\s*"#), Rx.i(#"\s*-\s*Stag\.?\s*\d+.*$"#), Rx.i(#"\s*-\s*Puntata del.*$"#), Rx(#"\s*-?\s*\d{2}/\d{2}/\d{4}\s*$"#),
        Rx.i(#"\s+S\.?\s*\d+\s*Ep\.?\s*\d+\s*$"#), Rx(#"\s+'\d\d\s*-\s*'\d\d\s*$"#), Rx(#"\s*,\s*\d+\s*$"#), Rx(#"\s+'\d\d(/'\d\d)?\s*$"#),
        Rx.i(#"\s+(1\^|1a)\s*TV\s*$"#), Rx(#"\s+(19|20)\d\d\s*$"#),
    ]
    private static func cleanOnce(_ s: String) -> String {
        var t = s.trimmed
        for r in cleanRules { t = r.replace(t, "") }
        return t.trimmed.trimmingEnd(",-:").trimmed
    }

    private static let acronyms: Set<String> = ["TG", "TG1", "TG2", "TG3", "TG4", "TG5", "VIP", "NBA", "NFL", "NHL", "MLS", "ATP", "WTA", "UFC", "WWE", "F1", "USA", "UK", "TV", "DAZN", "UEFA", "FIFA", "MTV", "RAI", "GP", "CSI", "NCIS", "FBI", "SOS"]

    /// "SPORT MEDIASET EDIZIONE ORE 13" -> "Sport Mediaset edizione ore 13"; short acronyms (TG, VIP, NBA) stay.
    static func smartCase(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        if letters.count < 8 || Double(letters.filter { $0.isUppercase }.count) < Double(letters.count) * 0.8 { return s }
        return s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, sub -> String in
            let w = String(sub)
            if acronyms.contains(w.trimming(",.:").uppercased()) { return w }
            return i == 0 ? w.lowercased().capitalizedFirst : w.lowercased()
        }.joined(separator: " ")
    }

    private static let synHead = Rx.i(#"^(S\d+\s*Ep\s*\d+|St\s*\d+(\s*Ep\s*\d+)?|Ep\s*\d+)\b[^-]{0,140}?\s-\s"#)
    /// "S12 Ep6 L'imitazione perturbativa - Leonard e Penny…" / "St2026 Puntata del 04/11/2026 - Bruno Vespa…" -> the synopsis proper.
    static func cleanSynopsis(_ s: String) -> String {
        var t = s
        if let m = synHead.find(s) { t = String(s[m.range.upperBound...]) }
        return t.trimmed.removingPrefix("...").trimmed
    }

    private static let small: Set<String> = ["e", "di", "da", "del", "della", "dei", "il", "la", "lo", "le", "gli", "un", "una", "a", "in", "con", "per", "of", "the", "and", "al", "alla"]
    /// "the-big-bang-theory" -> "The Big Bang Theory" (TMDB gives the proper spelling once recognised).
    static func prettySlug(_ slug: String) -> String {
        slug.split(separator: "-").map(String.init).filter { !$0.isBlank }.enumerated().map { i, w in (i > 0 && small.contains(w)) ? w : w.capitalizedFirst }.joined(separator: " ")
    }

    /// Some feeds double-encode UTF-8 ("UnitÃ " for "Unità").
    static func fixText(_ s: String) -> String {
        var t = s
        if t.contains("Ã") || t.contains("â€") {
            if let d = t.data(using: .isoLatin1), let fixed = String(data: d, encoding: .utf8), !fixed.contains("\u{FFFD}") { t = fixed }
        }
        return t.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
