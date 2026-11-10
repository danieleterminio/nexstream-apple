import Foundation

/// Turns the provider's raw channel list ("IT| RAI 1 FHD", "DAZN EVENTO 47 [Hellas Verona - Carrarese | Serie BKT (2026-11-01 16:15:00)]")
/// into our own catalogue: clean display names (alias table + smart title case), fixed Sky-style genres, DTT/Sky-like numbering,
/// per-quality variants merged, PPV/event channels with the event title parsed out.
enum ChannelCatalog {

    struct Genre { let id: String; let label: String; let base: Int; let fallbackFrom: Int }

    /// Fixed genre list, in display order. `base` = numbering block; unknown channels get numbers from `fallbackFrom`.
    static let genres: [Genre] = [
        Genre(id: "general", label: "Generalisti", base: 1, fallbackFrom: 70),
        Genre(id: "sport", label: "Sport", base: 200, fallbackFrom: 270),
        Genre(id: "events", label: "Calcio ed eventi", base: 800, fallbackFrom: 980),
        Genre(id: "cinema", label: "Cinema", base: 300, fallbackFrom: 370),
        Genre(id: "entertainment", label: "Intrattenimento", base: 100, fallbackFrom: 170),
        Genre(id: "docs", label: "Documentari", base: 400, fallbackFrom: 470),
        Genre(id: "news", label: "News", base: 500, fallbackFrom: 560),
        Genre(id: "kids", label: "Bambini", base: 600, fallbackFrom: 660),
        Genre(id: "music", label: "Musica", base: 700, fallbackFrom: 760),
        Genre(id: "local", label: "Locali e altri", base: 1000, fallbackFrom: 1000),
    ]
    static let genreById: [String: Genre] = Dictionary(uniqueKeysWithValues: genres.map { ($0.id, $0) })

    struct Parsed {
        var name: String            // clean display name
        var quality: String         // UHD / FHD / HD / HEVC / SD
        var shiftMin: Int = 0       // 60 for "+1" timeshift channels
        var event: String? = nil
        var eventSub: String? = nil
        var eventStart: Millis? = nil
    }

    private static let prefix = Rx(#"^[A-Z]{2,3}\s*\|\s*"#)
    private static let qualityRx = Rx.i(#"\b(FHD|UHD|4K|HEVC|HD|SD|H265|H\.265)\b"#)
    private static let sep = Rx(#"^[\s✦●★■▬=\-#*|]+.*[✦●★■▬=\-#*|]+\s*$"#)
    private static let eventParen = Rx.i(#"\(\s*[^)]*EVENT[^)]*\)"#)
    private static let eventTime = Rx(#"\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\)\s*$"#)
    private static let multiSpace = Rx(#"\s{2,}"#)
    private static let plusN = Rx(#"\s*\+\s*(\d+)"#)
    private static let plusOne = Rx(#"^(.*?)\s*\+\s*1$"#)
    private static let vs = Rx.i(#"\s+vs\.?\s+"#)
    private static let rxDaznEvento = Rx.i(#"^DAZN EVENTO (\d+)\s*\[(.*)\]\s*$"#)
    private static let rxPrimeIt = Rx.i(#"^PRIME IT (\d+)\s*\[(.*)\]\s*$"#)
    private static let rxDaznSerie = Rx.i(#"^DAZN\s*:\s*SERIE ([AB])\s+(\d+)\s+(.+)$"#)
    private static let rxLba = Rx.i(#"^LBATV\s*:\s*(.+)$"#)
    private static let rxInfinity = Rx.i(#"^INFINITY\s*\+\s*(\d+)"#)
    private static let rxAmazon = Rx.i(#"^AMAZON PRIME (\d+)"#)
    private static let rxSkyCalcio = Rx.i(#"^SKY CALCIO (\d)\b"#)
    private static let rxPrimafila = Rx.i(#"^SKY PRIMAFILA (\d+)"#)
    private static let rxDaznN = Rx.i(#"^DAZN (\d+)$"#)

    /// Event times in the provider's names are UTC (a Serie B 17:15 CET kick-off is listed as "16:15:00").
    private static let eventFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func isSeparator(_ name: String) -> Bool {
        name.isBlank || sep.matches(name.trimmed) || name.contains("✦") || name.equalsIgnoringCase("Account Information")
    }
    static func isJunkCategory(_ raw: String) -> Bool { raw.containsIgnoringCase("accou") || raw.containsIgnoringCase("info") }

    static func qualityOf(_ raw: String) -> String {
        guard let m = qualityRx.find(raw)?.value.uppercased() else { return "SD" }
        switch m { case "4K", "UHD": return "UHD"; case "H265", "H.265": return "HEVC"; default: return m }
    }

    static func parse(_ raw: String) -> Parsed {
        let quality = qualityOf(raw)
        var s = prefix.replace(raw.trimmed, "").trimmed

        // --- event / PPV families (keep the bracket text before stripping anything)
        if let m = rxDaznEvento.find(s) { let e = parseEvent(m[2]); return Parsed(name: "DAZN Evento \(Int(m[1]) ?? 0)", quality: quality, event: e.0, eventSub: e.1, eventStart: e.2) }
        if let m = rxPrimeIt.find(s) { let e = parseEvent(m[2]); return Parsed(name: "Prime Video \(Int(m[1]) ?? 0)", quality: quality, event: e.0, eventSub: e.1, eventStart: e.2) }
        if let m = rxDaznSerie.find(s) {
            let league = "Serie \(m[1].uppercased())"
            return Parsed(name: "DAZN \(league) \(Int(m[2]) ?? 0)", quality: quality, event: titleCase(m[3]), eventSub: league)
        }
        if let m = rxLba.find(s) { return Parsed(name: "LBA TV", quality: quality, event: m[1].trimmed, eventSub: "Basket Serie A") }
        if let m = rxInfinity.find(s) { return Parsed(name: "Infinity+ \(Int(m[1]) ?? 0)", quality: quality, eventSub: "Solo eventi") }
        if let m = rxAmazon.find(s) { return Parsed(name: "Prime Video Eventi \(Int(m[1]) ?? 0)", quality: quality, eventSub: "Solo eventi") }
        if let m = rxSkyCalcio.find(s) { return Parsed(name: "Sky Sport 25\(m[1])", quality: quality) }
        if let m = rxPrimafila.find(s) { return Parsed(name: "Sky Primafila \(Int(m[1]) ?? 0)", quality: quality) }
        if let m = rxDaznN.find(s) { return Parsed(name: "DAZN \(Int(m[1]) ?? 0)", quality: quality) }

        // --- ordinary channel
        s = multiSpace.replace(plusN.replace(qualityRx.replace(eventParen.replace(s, ""), ""), " +$1"), " ").trimmed.trimmingEnd("-|:").trimmed
        var shift = 0
        if let m = plusOne.find(s) { shift = 60; s = m[1].trimmed }
        let key = multiSpace.replace(s.uppercased(), " ")
        let name = alias[key] ?? titleCase(s)
        return Parsed(name: shift > 0 ? "\(name) +1" : name, quality: quality, shiftMin: shift)
    }

    /// "Hellas Verona - Carrarese | Serie BKT (2026-11-01 16:15:00)" -> (title, sub, start)
    private static func parseEvent(_ text: String) -> (String?, String?, Millis?) {
        var t = text.trimmed
        var at: Millis? = nil
        if let m = eventTime.find(t) {
            at = eventFmt.date(from: m[1])?.ms
            t.removeSubrange(m.range)
            t = t.trimmed
        }
        if t.isBlank || t.equalsIgnoringCase("EVENT ONLY") || t.equalsIgnoringCase("EVENTS ONLY") { return (nil, nil, nil) }
        let parts = t.components(separatedBy: " | ").map { $0.trimmed }.filter { !$0.isEmpty }
        let title = unshout(vs.replace(parts.first ?? t, " - "))
        let sub = parts.count > 1 ? parts.dropFirst().map { unshout($0) }.joined(separator: " · ") : nil
        return (title, sub, at)
    }

    /// "ZONA SERIE B MD10_2" -> "Zona Serie B MD10 2"; text that is not all caps is left alone.
    private static func unshout(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        return letters.count > 3 && letters.allSatisfy({ $0.isUppercase }) ? titleCase(s.replacingOccurrences(of: "_", with: " ")) : s
    }

    // ---------------------------------------------------------------- naming

    /// Exact renames (key = raw name without prefix/quality, upper-case).
    private static let alias: [String: String] = [
        "RAI ITALY": "Rai Italia", "RAI WORLD PREMIUM": "Rai Premium", "RAI UHD": "Rai 4K", "RAI": "Rai 4K", "RAI NEWS 24": "Rai News 24",
        "LA 5 MEDIASET": "La5", "LA 7": "La7", "LA 7D": "La7d", "20 MEDIASET": "20 Mediaset", "27 MEDIASET": "27 Twentyseven",
        "MEDIASET IRIS": "Iris", "MEDIASET EXTRA": "Mediaset Extra", "MEDIASET ITALIA 2": "Italia 2", "MEDIASET ITALIA": "Mediaset Italia",
        "SKY TG 24": "Sky TG24", "TGCOM24": "TGcom24", "TG NORBA 24": "TG Norba 24", "LAC NEWS 24": "LaC News 24", "TV 2000": "TV2000",
        "CINE 34": "Cine34", "PRIMO CANALE": "Primocanale", "DISCOVERY REAL TIME": "Real Time", "DISCOVERY HGTV": "HGTV", "DISCOVERY K2": "K2",
        "DISCOVERY CHANNEL": "Discovery Channel", "CRIME+INVESTIGATION": "Crime+Investigation", "SKY CACCIA": "Caccia e Pesca", "CACCIA E PESCA": "Caccia e Pesca",
        "SKY SERIES": "Sky Serie", "SKY SPORT BAR PRIMEVIDEO": "Sky Sport Bar", "SPORT ITALIA": "Sportitalia", "SPORT ITALIA LIVE 24": "Sportitalia Live 24",
        "SUPER TENNIS": "SuperTennis", "LAZIO CH": "Lazio Style Channel", "MILAN CHANNEL": "Milan TV", "INTER TV": "Inter TV",
        "DEA KIDS": "DeA Kids", "DEA JUNIOR": "DeA Junior", "NICK JR": "Nick Jr", "BABY TV": "BabyTV", "RADIO BELLLA & MONELLA TV": "Radio Bella & Monella TV",
        "TELE ROMAGNA": "Teleromagna", "ALTOADIGE TV": "Alto Adige TV", "ELIVE TV BRESCIA": "Elive TV Brescia", "JUWELO ITALIA": "Juwelo",
        "SKY SPORT MOTOGP": "Sky Sport MotoGP", "SKY SPORT F1": "Sky Sport F1", "SKY SPORT NBA": "Sky Sport NBA", "RTL 102.5": "RTL 102.5", "PADRE PIO": "Padre Pio TV",
        "VETRINA DAZN F2": "DAZN Vetrina", "ZONA DAZN": "Zona DAZN", "DAZN : ZONA DAZN SERIE A": "Zona DAZN Serie A", "DAZN : ZONA GOAL SERIE A": "Zona Gol Serie A",
        "VETRINA DAZN SERIE A": "DAZN Vetrina Serie A", "DAZN ZONA GOAL SERIE B": "Zona Gol Serie B", "VETRINA DAZN SERIE B": "DAZN Vetrina Serie B",
        "EQU TV": "EQU TV", "EURO INDIE MUSIC CHART TV": "Euro Indie Music Chart", "GRANDE FRATELLO PARTY": "Grande Fratello Party",
        "GRANDE FRATELL UN ORA FA": "Grande Fratello Un'ora fa", "GRANDE FRATELL REGIA 1": "Grande Fratello Regia 1", "GRANDE FRATELL REGIA 2": "Grande Fratello Regia 2",
        "RADIO MONTE CARLO": "Radio Monte Carlo", "CAFÈ TV 24": "Cafè TV 24", "ICARO TV": "Icaro TV", "TV QUI MODENA": "TV Qui Modena", "RTC TELECALABRIA": "RTC Telecalabria",
        "TELEVIDEO AGRIGENTO": "Televideo Agrigento", "RSI LA1": "RSI La1", "RSI LA2": "RSI La2", "TOP CALCIO 24": "Top Calcio 24", "RADIO ZETA": "Radio Zeta",
        "VIDEO ITALIA": "Video Italia", "RADIO TICINO CHANNEL": "Radio Ticino", "CANALE ITALIA": "Canale Italia", "BOING PLUS": "Boing Plus", "SKY ARTE": "Sky Arte",
        "RAI GULP": "Rai Gulp", "RAI YOYO": "Rai Yoyo", "SUPER!": "Super!", "MOTOR TREND": "Motor Trend", "FOOD NETWORK": "Food Network", "GAMBERO ROSSO": "Gambero Rosso",
    ]

    private static let upper: Set<String> = ["TV", "DAZN", "NBA", "F1", "RTL", "MTV", "VH1", "RSI", "DMAX", "HGTV", "RDS", "RMC", "LBA", "K2", "TVRS", "TR24", "RTC", "EQU", "NOVE", "TV8", "FC", "SS", "LR", "CB", "US", "TG", "AC", "4K", "EA", "NCAA", "NFL", "NHL", "MLB", "UFC", "WTA", "ATP", "MD", "BKT", "DFB", "LPB", "ASVEL", "CLAI", "SMI", "JV", "OH", "MLTT", "UTR", "PTT"]
    private static let special: [String: String] = ["motogp": "MotoGP", "dea": "DeA", "la7": "La7", "la7d": "La7d", "la5": "La5", "tgcom24": "TGcom24", "deejay": "Deejay",
        "super!": "Super!", "cafè": "Cafè", "tv2000": "TV2000", "supertennis": "SuperTennis", "lac": "LaC", "babytv": "BabyTV", "laliga": "LaLiga", "superlega": "SuperLega"]
    private static let lower: Set<String> = ["e", "di", "del", "della", "dei", "da", "&"]
    private static let ws = Rx(#"\s+"#)

    /// "SKY SPORT CALCIO" -> "Sky Sport Calcio"; keeps brand acronyms.
    static func titleCase(_ s: String) -> String {
        let ws = s.trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var out = [String]()
        for (i, w) in ws.enumerated() {
            let lw = w.lowercased()
            if let sp = special[lw] { out.append(sp) }
            else if upper.contains(w.uppercased()) || (w.contains(".") && w.count <= 5) { out.append(w.uppercased()) }
            else if i > 0 && lower.contains(lw) { out.append(lw) }
            else { out.append(lw.split(separator: "-", omittingEmptySubsequences: false).map { String($0).capitalizedFirst }.joined(separator: "-")) }
        }
        return out.joined(separator: " ")
    }

    // ---------------------------------------------------------------- numbering

    /// Known numbers: DTT LCN for the national channels (what people type on any Italian TV), Sky-like blocks for the rest.
    private static let numbers: [String: Int] = [
        "Rai 1": 1, "Rai 2": 2, "Rai 3": 3, "Rete 4": 4, "Canale 5": 5, "Italia 1": 6, "La7": 7, "TV8": 8, "NOVE": 9,
        "20 Mediaset": 20, "Rai 4": 21, "Iris": 22, "Rai 5": 23, "Rai Movie": 24, "Rai Premium": 25, "Cielo": 26, "27 Twentyseven": 27, "TV2000": 28,
        "La7d": 29, "La5": 30, "Real Time": 31, "Food Network": 33, "Cine34": 34, "Focus": 35, "RTL 102.5": 36, "Giallo": 38, "Top Crime": 39,
        "Boing": 40, "K2": 41, "Rai Gulp": 42, "Rai Yoyo": 43, "Frisbee": 44, "Boing Plus": 45, "Cartoonito": 46, "Super!": 47, "Rai News 24": 48,
        "Italia 2": 49, "Sky TG24": 50, "TGcom24": 51, "DMAX": 52, "Rai Storia": 54, "Mediaset Extra": 55, "HGTV": 56, "Rai Scuola": 57, "Rai Sport": 58,
        "Motor Trend": 59, "Sportitalia": 60, "Rai Italia": 61, "Rai 4K": 62, "RSI La1": 63, "RSI La2": 64, "Canale Italia": 65, "Mediaset Italia": 66,
        "Sky Uno": 108, "Sky Atlantic": 110, "Sky Serie": 112, "Sky Arte": 120, "Comedy Central": 128, "Alice": 131,
        "Grande Fratello Regia 1": 150, "Grande Fratello Regia 2": 151, "Grande Fratello Un'ora fa": 152, "Grande Fratello Party": 153,
        "Sky Sport 24": 200, "Sky Sport Uno": 201, "Sky Sport Calcio": 202, "Sky Sport Tennis": 203, "Sky Sport Arena": 204, "Sky Sport Max": 205,
        "Sky Sport Golf": 206, "Sky Sport F1": 207, "Sky Sport MotoGP": 208, "Sky Sport NBA": 209, "Eurosport 1": 210, "Eurosport 2": 211, "SuperTennis": 212,
        "Sky Sport Football": 213, "Sky Sport Bar": 214, "EQU TV": 215, "Top Calcio 24": 216, "Sportitalia Live 24": 217,
        "Inter TV": 230, "Milan TV": 231, "Lazio Style Channel": 232,
        "Sky Cinema Uno": 301, "Sky Cinema Uno +24": 302, "Sky Cinema Due": 303, "Sky Cinema Due +24": 304, "Sky Cinema Collection": 305, "Sky Cinema Family": 306,
        "Sky Cinema Action": 307, "Sky Cinema Suspense": 308, "Sky Cinema Romance": 309, "Sky Cinema Drama": 310, "Sky Cinema Comedy": 311,
        "Sky Documentaries": 401, "Sky Nature": 402, "Sky Investigation": 403, "Discovery Channel": 404, "History": 405, "Crime+Investigation": 406,
        "Caccia e Pesca": 407, "Italian Fishing TV": 408, "Gambero Rosso": 409,
        "TG Norba 24": 501, "LaC News 24": 502, "Primocanale": 503,
        "DeA Kids": 601, "DeA Junior": 602, "Cartoon Network": 603, "Boomerang": 604, "Nickelodeon": 605, "Nick Jr": 606, "BabyTV": 607, "Telebimbi": 608,
        "MTV": 701, "VH1": 702, "Deejay TV": 703, "Radio Italia TV": 704, "Radio Zeta": 705, "Radio Monte Carlo": 706, "Radio Kiss Kiss TV": 707,
        "Radio Capital TV": 708, "Video Italia": 709, "Radio Birikina TV": 710, "Radio Bella & Monella TV": 711, "Radio 51": 712, "Radio Ticino": 713,
        "Radio Iglesias": 714, "RDS Social TV": 715, "Euro Indie Music Chart": 716,
        "Zona DAZN": 800, "DAZN Vetrina": 812, "Zona DAZN Serie A": 815, "Zona Gol Serie A": 816, "DAZN Vetrina Serie A": 817, "Zona Gol Serie B": 818, "DAZN Vetrina Serie B": 819,
    ]

    private static let numbered: [(Rx, Int)] = [
        (Rx(#"^DAZN (\d+)$"#), 800), (Rx(#"^DAZN Serie A (\d+)$"#), 820), (Rx(#"^DAZN Serie B (\d+)$"#), 840), (Rx(#"^DAZN Evento (\d+)$"#), 860),
        (Rx(#"^Prime Video (\d+)$"#), 920), (Rx(#"^Prime Video Eventi (\d+)$"#), 940), (Rx(#"^Infinity\+ (\d+)$"#), 950),
        (Rx(#"^Sky Sport (25\d)$"#), 0), (Rx(#"^Sky Primafila (\d+)$"#), 350),
    ]

    /// Explicit number for a clean name, or nil. Handles the numbered families by pattern.
    static func knownNumber(_ name: String, shiftMin: Int) -> Int? {
        if shiftMin > 0 {
            guard let base = numbers[name.removingSuffix(" +1")] else { return nil }
            return base < 100 ? base + 100 : nil
        }
        if let n = numbers[name] { return n }
        for (rx, base) in numbered { if let m = rx.find(name), let n = Int(m[1]) { return base + n } }
        return nil
    }

    // ---------------------------------------------------------------- genres

    private static let genreByName: [String: String] = [
        "Rai 1": "general", "Rai 2": "general", "Rai 3": "general", "Rete 4": "general", "Canale 5": "general", "Italia 1": "general", "La7": "general",
        "TV8": "general", "NOVE": "general", "20 Mediaset": "general", "Rai 4": "general", "Rai 5": "general", "Cielo": "general", "TV2000": "general",
        "La7d": "general", "Rai Italia": "general", "Rai 4K": "general", "RSI La1": "general", "RSI La2": "general", "Canale Italia": "general", "Mediaset Italia": "general",
        "Iris": "cinema", "Rai Movie": "cinema", "Cine34": "cinema",
        "Rai Premium": "entertainment", "27 Twentyseven": "entertainment", "La5": "entertainment", "Giallo": "entertainment", "Top Crime": "entertainment",
        "Italia 2": "entertainment", "Mediaset Extra": "entertainment", "Sky Uno": "entertainment", "Sky Atlantic": "entertainment", "Sky Serie": "entertainment",
        "Sky Arte": "entertainment", "Comedy Central": "entertainment", "Alice": "entertainment", "Warner TV": "entertainment",
        "Real Time": "docs", "Food Network": "docs", "Focus": "docs", "DMAX": "docs", "Rai Storia": "docs", "HGTV": "docs", "Rai Scuola": "docs", "Motor Trend": "docs",
        "Sky Documentaries": "docs", "Sky Nature": "docs", "Sky Investigation": "docs", "Discovery Channel": "docs", "History": "docs", "Crime+Investigation": "docs",
        "Caccia e Pesca": "docs", "Italian Fishing TV": "docs", "Gambero Rosso": "docs",
        "Rai News 24": "news", "Sky TG24": "news", "TGcom24": "news", "TG Norba 24": "news", "LaC News 24": "news", "Primocanale": "news",
        "Rai Sport": "sport", "Sportitalia": "sport", "Sportitalia Live 24": "sport", "Eurosport 1": "sport", "Eurosport 2": "sport", "SuperTennis": "sport",
        "EQU TV": "sport", "Top Calcio 24": "sport", "Inter TV": "sport", "Milan TV": "sport", "Lazio Style Channel": "sport",
        "RTL 102.5": "music", "MTV": "music", "VH1": "music", "Deejay TV": "music", "Radio Italia TV": "music", "Video Italia": "music", "RDS Social TV": "music",
        "Euro Indie Music Chart": "music",
        "Boing": "kids", "K2": "kids", "Rai Gulp": "kids", "Rai Yoyo": "kids", "Frisbee": "kids", "Boing Plus": "kids", "Cartoonito": "kids", "Super!": "kids",
        "DeA Kids": "kids", "DeA Junior": "kids", "Cartoon Network": "kids", "Boomerang": "kids", "Nickelodeon": "kids", "Nick Jr": "kids", "BabyTV": "kids", "Telebimbi": "kids",
        "Juwelo": "local", "Padre Pio TV": "local", "Uniresat": "local",
    ]

    private static let providerGenre: [(String, String)] = [
        ("GENERALE", "general"), ("SPORT", "sport"), ("ENTERTA", "entertainment"), ("PPV", "events"), ("EVENT", "events"), ("DAZN", "events"), ("CINEMA", "cinema"),
        ("DOCUMENT", "docs"), ("KIDS", "kids"), ("BAMBINI", "kids"), ("MUSIC", "music"), ("MUSICA", "music"), ("NEWS", "news"), ("RADIO", "music"),
    ]
    private static let digits = Rx(#"\d+"#)

    static func genreOf(_ name: String, providerCategory: String, isEvent: Bool) -> String {
        let base = name.removingSuffix(" +1")
        if let g = genreByName[base] { return g }
        if isEvent { return "events" }
        let u = base.uppercased()
        if u.hasPrefix("SKY CINEMA") { return "cinema" }
        if u.hasPrefix("SKY PRIMAFILA") { return (Int(digits.find(u)?.value ?? "") ?? 0) <= 5 ? "cinema" : "sport" }
        if u.hasPrefix("SKY SPORT") { return "sport" }
        if u.hasPrefix("DAZN") || u.hasPrefix("ZONA") || u.hasPrefix("PRIME VIDEO") || u.hasPrefix("INFINITY") || u.hasPrefix("LBA") { return "events" }
        if u.hasPrefix("RADIO") || u.contains("MUSIC") { return "music" }
        if u.contains("NEWS") || u.hasPrefix("TG") { return "news" }
        if u.hasPrefix("TELE") || u.hasSuffix(" TV") || u.hasPrefix("TV ") || u.hasPrefix("CANALE") || u.hasPrefix("RETE") || u.contains("REGGIO") || u.contains("BRESCIA") { return "local" }
        let pc = providerCategory.uppercased()
        let fromProvider = providerGenre.first { pc.contains($0.0) }?.1 ?? "local"
        // the provider's MUSIC bucket is mostly regional stations: only real music names stay there
        return fromProvider == "music" ? "local" : fromProvider
    }

    // ---------------------------------------------------------------- external EPG (epgshare01 IT)

    /// Our clean name -> channel id in the epgshare01 Italian XMLTV (5 days, posters, categories).
    static let extEpg: [String: String] = [
        "Rai 1": "Rai1.it", "Rai 2": "Rai2.it", "Rai 3": "Rai3.it", "Rai 4": "Rai4.it", "Rai 5": "Rai5.it", "Rai Movie": "RaiMovie.it", "Rai Premium": "RaiPremium.it",
        "Rai Gulp": "RaiGulp.it", "Rai Yoyo": "RaiYoyo.it", "Rai Storia": "RaiStoria.it", "Rai Scuola": "RaiScuola.it", "Rai News 24": "RaiNews24.it", "Rai Sport": "RaiSport.it",
        "Rai 4K": "Rai1.it", "Rete 4": "Rete.4.it", "Canale 5": "Canale.5.it", "Italia 1": "Italia.1.it", "Italia 2": "Italia.2.it", "La7": "LA7.HD.it", "La7d": "LA7D.it",
        "TV8": "TV8.HD.it", "NOVE": "Nove.it", "20 Mediaset": "20.it", "Iris": "Iris.it", "Cielo": "cielo.it", "27 Twentyseven": "27.Twentyseven.it", "La5": "La.5.it",
        "Real Time": "Real.Time.it", "Food Network": "Food.Network.it", "Cine34": "Cine34.it", "Focus": "Focus.it", "RTL 102.5": "RTL.102.5.HD.it", "Giallo": "Giallo.TV.it",
        "Top Crime": "Top.Crime.it", "Boing": "Boing.it", "K2": "K2.it", "Frisbee": "Frisbee.it", "Cartoonito": "Cartoonito.it", "Super!": "Super!.it", "TGcom24": "TGCom.it",
        "DMAX": "DMAX.it", "Mediaset Extra": "Mediaset.Extra.it", "HGTV": "HGTV.it", "Motor Trend": "Motor.Trend.it", "Sky TG24": "Sky.TG24.it", "Sky Uno": "Sky.Uno.it",
        "Sky Atlantic": "Sky.Atlantic.it", "Sky Serie": "Sky.Serie.it", "Sky Arte": "Sky.Arte.it", "Sky Documentaries": "Sky.Documentaries.it", "Sky Nature": "Sky.Nature.it",
        "Sky Investigation": "Sky.Investigation.it", "Comedy Central": "Comedy.Central.it", "MTV": "MTV.HD.it", "Gambero Rosso": "Gambero.Rosso.HD.it",
        "Sky Cinema Uno": "Sky.Cinema.Uno.it", "Sky Cinema Uno +24": "Sky.Cinema.Uno.+24.it", "Sky Cinema Due": "Sky.Cinema.Due.it", "Sky Cinema Due +24": "Sky.Cinema.Due.+24.it",
        "Sky Cinema Collection": "Sky.Cinema.Collection.it", "Sky Cinema Family": "Sky.Cinema.Family.it", "Sky Cinema Action": "Sky.Cinema.Action.it",
        "Sky Cinema Suspense": "Sky.Cinema.Suspense.it", "Sky Cinema Romance": "Sky.Cinema.Romance.it", "Sky Cinema Drama": "Sky.Cinema.Drama.it", "Sky Cinema Comedy": "Sky.Cinema.Comedy.it",
        "Sky Sport Uno": "Sky.Sport.Uno.it", "Sky Sport Calcio": "Sky.Sport.Calcio.it", "Sky Sport Tennis": "Sky.Sport.Tennis.it", "Sky Sport Golf": "Sky.Sport.Golf.it",
        "Sky Sport F1": "Sky.Sport.F1.it", "Sky Sport MotoGP": "Sky.Sport.MotoGP.it", "Sky Sport NBA": "Sky.Sport.NBA.it", "Sky Sport Max": "Sky.Sport.Max.it",
        "Sky Sport Arena": "Sky.Sport.Arena.it", "Sky Sport 24": "Sky.Sport.24.it", "Sky Sport 251": "Sky.Sport..251.it", "Sky Sport 252": "Sky.Sport..252.it",
        "Sky Sport 253": "Sky.Sport..253.it", "Sky Sport 254": "Sky.Sport..254.it", "Sky Sport 255": "Sky.Sport..255.it", "Sky Sport 256": "Sky.Sport..256.it",
        "Sky Sport 257": "Sky.Sport..257.it", "SuperTennis": "SuperTennis.HD.it", "DAZN 1": "DAZN.1.it.it", "DAZN 2": "DAZN.2.it.it", "EQU TV": "EQUtv.it",
        "Milan TV": "Milan.TV.it", "Inter TV": "Inter.TV.it", "Caccia e Pesca": "CACCIA.e.Pesca.it", "History": "History.it", "TG Norba 24": "TG.NORBA.24.it",
        "DeA Kids": "DeAKids.it", "Nick Jr": "Nick.Jr.it", "Nickelodeon": "Nickelodeon.it", "Cartoon Network": "Cartoon.Network.it", "Boomerang": "Boomerang.it",
        "DeA Junior": "DeAJunior.it", "Deejay TV": "Deejay.TV.it", "Radio Italia TV": "Radio.Italia.TV.HD.it", "Radio Monte Carlo": "RMC.it",
        "Grande Fratello Un'ora fa": "GF.VIP.-.Un’ora.fa.it", "Grande Fratello Regia 1": "GF.VIP.-.Regia.1.it", "Grande Fratello Regia 2": "GF.VIP.-.Regia.2.it",
        "Mediaset Italia": "Mediaset.Italia.-.Europa.e.Africa.it", "Eurosport 1": "Eurosport.Italia.it", "Eurosport 2": "Eurosport.2.Italia.it", "Sportitalia": "Sportitalia.HD.it",
        "Discovery Channel": "Discovery.Channel.it", "TR24": "TRM.h24.it",
    ]

    private static let keyTail = Rx(#"\s{2,}\d{3,4}\s*$"#)
    private static let keyWords = Rx(#"\b(hd|fhd|uhd|4k|sd|tv|channel|italia)\b"#)
    private static let keyJunk = Rx(#"[^a-z0-9+!]"#)
    /// Loose key used to match our names against any XMLTV display-name: "Rai 1 HD  101" / "Rai1" / "RAI 1" -> "rai1".
    static func epgKey(_ s: String) -> String { keyJunk.replace(keyWords.replace(keyTail.replace(s.lowercased(), ""), ""), "") }
}
