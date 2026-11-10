import Foundation

/// Team crests and national flags for the match cards, so a match shows the two teams instead of the broadcaster's
/// graphic. Sources, all public and key-less:
///  - ESPN's team lists (Serie A/B, Coppa Italia, the three UEFA cups, the main European leagues, NBA, EuroLeague);
///  - DAZN's guide (its contestants come with their crests, Italian names included);
///  - flagcdn.com for national teams, from their Italian names ("Belgio - Italia").
/// The list is kept in the `meta` table (refreshed weekly with the guide) and held in memory for the cards.
enum Crests {
    private static let key = "crests.v2"
    private static let keyAt = "crests.at"
    private static let espn = "https://site.api.espn.com/apis/site/v2/sports/"
    private static let leagues = [
        "soccer/ita.1", "soccer/ita.2", "soccer/ita.coppa_italia", "soccer/uefa.champions", "soccer/uefa.europa", "soccer/uefa.europa.conf",
        "soccer/eng.1", "soccer/esp.1", "soccer/ger.1", "soccer/fra.1", "soccer/por.1", "soccer/ned.1", "soccer/tur.1", "soccer/sco.1",
        "soccer/bel.1", "soccer/sui.1", "soccer/gre.1", "soccer/aut.1", "soccer/den.1", "soccer/nor.1", "basketball/nba", "basketball/euroleague",
    ]

    final class Team {
        let names: [String], url: String, leagues: [String]
        let tokens: [Set<String>]
        init(names: [String], url: String, leagues: [String] = []) { self.names = names; self.url = url; self.leagues = leagues; tokens = names.map { Crests.tokens($0) } }
    }

    /// ESPN league → the competition name our cards show.
    private static let leagueName: [String: String] = [
        "soccer/ita.1": "Serie A", "soccer/ita.2": "Serie B", "soccer/ita.coppa_italia": "Coppa Italia", "soccer/uefa.champions": "UEFA Champions League",
        "soccer/uefa.europa": "UEFA Europa League", "soccer/uefa.europa.conf": "UEFA Conference League", "soccer/eng.1": "Premier League",
        "soccer/esp.1": "LaLiga", "soccer/ger.1": "Bundesliga", "soccer/fra.1": "Ligue 1", "soccer/por.1": "Liga Portugal", "soccer/ned.1": "Eredivisie",
        "soccer/tur.1": "Süper Lig", "soccer/sco.1": "Scottish Premiership", "soccer/bel.1": "Jupiler Pro League", "soccer/sui.1": "Super League svizzera",
        "soccer/gre.1": "Super League greca", "soccer/aut.1": "Bundesliga austriaca", "soccer/den.1": "Superliga danese", "soccer/nor.1": "Eliteserien",
        "basketball/nba": "NBA", "basketball/euroleague": "EuroLeague",
    ]
    /// The cups, in order: two teams of different leagues that meet are playing one of these.
    private static let leagueOrder = ["soccer/uefa.champions", "soccer/uefa.europa", "soccer/uefa.europa.conf"]

    private static let lock = NSLock()
    private static var teams: [Team] = []
    private static var exact: [String: String] = [:]
    private static var cache: [String: String] = [:]
    /// Bumped when the list changes, so the cards that read it refresh.
    static let version = Observable<Int>(0)

    private static let stop: Set<String> = ["fc", "ac", "as", "ss", "ssc", "us", "sc", "cf", "afc", "calcio", "club", "de", "del", "la", "sv", "vfb", "tsg", "rb", "cd", "ud", "sd", "fk", "sk", "if", "bk", "1", "spa", "the"]
    fileprivate static func tokens(_ n: String) -> Set<String> { Set(n.split(separator: " ").map(String.init).filter { !$0.isEmpty && !stop.contains($0) }) }

    /// Italian names → the names ESPN uses.
    private static let alias: [String: String] = [
        "inter": "internazionale", "bayern monaco": "bayern munich", "siviglia": "sevilla", "stella rossa": "crvena zvezda",
        "psg": "paris saint germain", "lipsia": "rb leipzig", "stoccarda": "stuttgart", "friburgo": "freiburg", "colonia": "koln",
        "francoforte": "eintracht frankfurt", "lione": "lyon", "marsiglia": "marseille", "nizza": "nice", "tolosa": "toulouse", "lilla": "lille",
        "salisburgo": "salzburg", "copenaghen": "copenhagen", "bruges": "club brugge", "anversa": "antwerp", "aek atene": "aek athens",
        "olympiakos": "olympiacos", "basilea": "basel", "zurigo": "zurich", "manchester utd": "manchester united", "man utd": "manchester united",
        "man city": "manchester city", "glasgow rangers": "rangers", "dinamo zagabria": "dinamo zagreb", "sporting lisbona": "sporting cp",
        "betis": "real betis", "athletic bilbao": "athletic club", "atletico": "atletico madrid", "monchengladbach": "borussia monchengladbach",
        "hellas verona": "verona", "dortmund": "borussia dortmund", "leverkusen": "bayer leverkusen", "psv": "psv eindhoven",
        "sparta praga": "sparta prague", "slavia praga": "slavia prague", "viktoria plzen": "viktoria plzen", "steaua bucarest": "fcsb",
        "dinamo kiev": "dynamo kyiv", "shakhtar donetsk": "shakhtar donetsk", "legia varsavia": "legia warsaw", "lech poznan": "lech poznan",
        "rapid vienna": "rapid wien", "austria vienna": "austria wien", "maccabi tel aviv": "maccabi tel aviv", "paok salonicco": "paok", "union saint gilloise": "union st gilloise",
    ]

    /// National teams by their Italian (and English) names → flagcdn codes.
    private static let nations: [String: String] = [
        "italia": "it", "italy": "it", "francia": "fr", "germania": "de", "spagna": "es", "inghilterra": "gb-eng", "scozia": "gb-sct",
        "galles": "gb-wls", "irlanda del nord": "gb-nir", "irlanda": "ie", "portogallo": "pt", "olanda": "nl", "paesi bassi": "nl",
        "belgio": "be", "svizzera": "ch", "austria": "at", "croazia": "hr", "serbia": "rs", "slovenia": "si", "slovacchia": "sk",
        "repubblica ceca": "cz", "cechia": "cz", "polonia": "pl", "ungheria": "hu", "romania": "ro", "bulgaria": "bg", "grecia": "gr",
        "turchia": "tr", "ucraina": "ua", "russia": "ru", "norvegia": "no", "svezia": "se", "danimarca": "dk", "finlandia": "fi",
        "islanda": "is", "albania": "al", "macedonia del nord": "mk", "montenegro": "me", "bosnia": "ba", "bosnia erzegovina": "ba",
        "kosovo": "xk", "georgia": "ge", "armenia": "am", "azerbaigian": "az", "israele": "il", "cipro": "cy", "malta": "mt",
        "lussemburgo": "lu", "estonia": "ee", "lettonia": "lv", "lituania": "lt", "moldavia": "md", "bielorussia": "by", "kazakistan": "kz",
        "san marino": "sm", "andorra": "ad", "liechtenstein": "li", "far oer": "fo", "gibilterra": "gi", "argentina": "ar", "brasile": "br",
        "uruguay": "uy", "colombia": "co", "cile": "cl", "peru": "pe", "ecuador": "ec", "paraguay": "py", "messico": "mx",
        "stati uniti": "us", "usa": "us", "canada": "ca", "giappone": "jp", "corea del sud": "kr", "australia": "au",
        "nuova zelanda": "nz", "sudafrica": "za", "marocco": "ma", "egitto": "eg", "senegal": "sn", "nigeria": "ng", "camerun": "cm",
        "ghana": "gh", "costa d avorio": "ci", "tunisia": "tn", "algeria": "dz", "arabia saudita": "sa", "qatar": "qa", "iran": "ir",
        "cina": "cn", "india": "in", "figi": "fj", "samoa": "ws", "tonga": "to", "giamaica": "jm",
    ]

    static func flag(_ name: String) -> String? { nations[MetaText.norm(name)].map { "https://flagcdn.com/w320/\($0).png" } }

    /// Crest of a club, by the name a guide uses; nil when not known.
    static func find(_ name: String) -> String? {
        let n0 = MetaText.norm(name)
        if n0.count < 2 { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[n0] { return c.isEmpty ? nil : c }
        let n = alias[n0] ?? n0
        var hit: String? = exact[n] ?? exact[n0]
        if hit == nil {
            let q = tokens(n)
            if !q.isEmpty {
                let hits = teams.filter { t in t.tokens.contains { s in !s.isEmpty && (s.isSuperset(of: q) || q.isSuperset(of: s)) } }.map { $0.url }.distinct
                if hits.count == 1 && (q.count > 1 || (q.first?.count ?? 0) >= 4 || teams.filter({ t in t.tokens.contains { $0.isSuperset(of: q) } }).count == 1) { hit = hits[0] }
                else if hits.count > 1 { hit = teams.first { t in t.tokens.contains { $0 == q } }?.url }   // "real madrid" among the "real *"
            }
        }
        cache[n0] = hit ?? ""
        return hit
    }

    private static func team(_ name: String) -> Team? {
        guard let u = find(name) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return teams.first { $0.url == u }
    }

    /// A team you can follow: its crest (or flag) is its identity, `group` is where the picker lists it.
    struct Pick: Hashable, Identifiable { let name: String, crest: String, group: String, search: String; var id: String { crest } }

    /// Domestic leagues first (Serie A, Serie B, the big five…), then the clubs met in the UEFA cups, then the national teams.
    private static let groupOrder = ["soccer/ita.1", "soccer/ita.2", "soccer/eng.1", "soccer/esp.1", "soccer/ger.1", "soccer/fra.1", "soccer/por.1", "soccer/ned.1",
                                     "soccer/tur.1", "soccer/sco.1", "soccer/bel.1", "soccer/sui.1", "soccer/gre.1", "soccer/aut.1", "soccer/den.1", "soccer/nor.1"]
    private static let upperWords: Set<String> = ["fc", "ac", "as", "ss", "ssc", "us", "sc", "cf", "afc", "rb", "psv", "az", "aek", "paok", "fcsb", "bk", "fk", "sk", "if", "sv", "vfb", "vfl", "tsg", "ud", "cd", "sd", "ogc", "rc", "losc"]
    /// Club prefixes / suffixes Italians leave out ("AC Milan" → "Milan", "SSC Napoli" → "Napoli", "Liverpool FC" → "Liverpool").
    private static let legal: Set<String> = ["ac", "as", "ss", "ssc", "us", "fc", "afc", "sc", "cf", "cd", "ud", "sd", "acf", "bc"]
    private static func pretty(_ n: String) -> String {
        var w = n.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if w.count > 1, legal.contains(w[0]) { w.removeFirst() }
        if w.count > 1, let l = w.last, legal.contains(l) { w.removeLast() }
        return w.map { upperWords.contains($0) ? $0.uppercased() : $0.capitalizedFirst }.joined(separator: " ")
    }

    /// Football clubs and national teams for "Segui la tua squadra", Italian names where we have one. Empty until the list is loaded.
    static func catalog() -> [Pick] {
        lock.lock(); let all = teams; lock.unlock()
        var reverse = [String: [String]]()
        for (k, v) in alias { reverse[v, default: []].append(k) }
        let clubs = all.filter { t in t.url.contains("espncdn") && t.leagues.contains { $0.hasPrefix("soccer/") } }.map { t -> Pick in
            let it = t.names.compactMap { reverse[$0]?.sorted().first }.first
            let name = it ?? t.names[0]
            let league = groupOrder.first { t.leagues.contains($0) }
            return Pick(name: pretty(name), crest: t.url, group: league.flatMap { leagueName[$0] } ?? "Altre squadre europee", search: (t.names + (it.map { [$0] } ?? [])).joined(separator: " "))
        }.distinct { $0.crest }
        var byCode = [String: [String]]()
        for (k, v) in nations { byCode[v, default: []].append(k) }
        let nats = byCode.map { code, names -> Pick in
            let sortedNames = names.sorted()
            return Pick(name: pretty(sortedNames.first { $0 != "italy" && $0 != "usa" } ?? sortedNames[0]), crest: "https://flagcdn.com/w320/\(code).png", group: "Nazionali", search: sortedNames.joined(separator: " "))
        }
        let order = groupOrder.compactMap { leagueName[$0] } + ["Altre squadre europee", "Nazionali"]
        return (clubs.sortedBy { $0.name } + nats.sortedBy { $0.name }).sortedBy { order.firstIndex(of: $0.group) ?? 99 }
    }

    /// The crest (or flag) a guide's team name stands for, the same way the match cards find it.
    static func identity(_ name: String) -> String? { flag(name) ?? find(name) }

    /// The competition two teams share (the domestic league when they share one, else the cup).
    static func competition(_ home: String, _ away: String) -> String? {
        guard let a = team(home)?.leagues, let b = team(away)?.leagues else { return nil }
        let common = a.filter { b.contains($0) }
        if common.isEmpty { return nil }
        let l = common.first { !leagueOrder.contains($0) && $0 != "soccer/ita.coppa_italia" } ?? leagueOrder.first { common.contains($0) } ?? common[0]
        return leagueName[l]
    }

    /// Both sides of a match: flags when both are national teams, crests otherwise.
    static func pair(_ home: String, _ away: String) -> (String?, String?) {
        if let fh = flag(home), let fa = flag(away) { return (fh, fa) }
        return (find(home), find(away))
    }

    private static func merge(_ list: [Team]) -> [Team] {
        var order = [String](); var by = [String: [Team]]()
        for t in list { if by[t.url] == nil { order.append(t.url) }; by[t.url, default: []].append(t) }
        return order.map { u in
            let l = by[u]!
            return l.count == 1 ? l[0] : Team(names: l.flatMap { $0.names }.distinct, url: u, leagues: l.flatMap { $0.leagues }.distinct)
        }
    }

    private static func index(_ all: [Team]) {
        let list = merge(all)
        var m = [String: String]()
        for t in list { for n in t.names where m[n] == nil { m[n] = t.url } }
        lock.lock(); exact = m; teams = list; cache.removeAll(); lock.unlock()
        version.value += 1
    }

    static func load(_ db: AppDB) {
        if let raw = db.meta(key) { index(decode(raw)) }
    }

    /// Weekly ESPN refresh + the DAZN contestants of the guide just fetched.
    static func sync(_ db: AppDB, _ dazn: [Dazn.Event]) async {
        let at = db.metaInt64(keyAt)
        let old = db.meta(key).map { decode($0) } ?? []
        let due = Clock.now - at > 7 * Clock.day || old.isEmpty
        var espnTeams: [Team]
        if due {
            let lists = await mapConcurrent(leagues, limit: 6) { l -> [Team] in
                do { return try await fetchEspn(l) } catch { NxLog.w("NxCrests", "\(l): \(error)"); return [] }
            }
            // the same club in several competitions → one entry with all of them (for "which competition do they share")
            espnTeams = merge(lists.flatMap { $0 })
        } else { espnTeams = old.filter { $0.url.contains("espncdn") } }
        if espnTeams.isEmpty { espnTeams = old.filter { $0.url.contains("espncdn") } }
        let fresh = due && !espnTeams.isEmpty
        var fromDazn = [Team]()
        for e in dazn { for (n, u) in zip(e.teams, e.teamLogos) { if let u = u { fromDazn.append(Team(names: [MetaText.norm(n)], url: u)) } } }
        fromDazn = fromDazn.distinct { $0.names[0] }
        let known = Set(espnTeams.flatMap { $0.names })
        let daznNames = Set(fromDazn.map { $0.names[0] })
        let all = espnTeams + fromDazn.filter { !known.contains($0.names[0]) } + old.filter { !$0.url.contains("espncdn") && !known.contains($0.names[0]) && !daznNames.contains($0.names[0]) }
        if all.isEmpty { return }
        db.setMeta(key, encode(all))
        if fresh { db.setMeta(keyAt, String(Clock.now)) }
        index(all)
        NxLog.i("NxCrests", "\(espnTeams.count) ESPN + \(fromDazn.count) DAZN crests")
    }

    private static func fetchEspn(_ league: String) async throws -> [Team] {
        let root = J.parse(try await Http.data("\(espn)\(league)/teams?limit=200", headers: ["User-Agent": "Mozilla/5.0"]))
        var out = [Team]()
        for s in root["sports"].array { for l in s["leagues"].array { for x in l["teams"].array {
            let t = x["team"]
            guard let logo = t["logos"][0]["href"].stringOrNil else { continue }
            var raw = [t["displayName"].stringOrNil, t["shortDisplayName"].stringOrNil, t["name"].stringOrNil].compactMap { $0 }
            if league.hasPrefix("soccer"), let loc = t["location"].stringOrNil, loc == t["name"].stringOrNil { raw.append(loc) }
            let names = raw.map { MetaText.norm($0) }.filter { $0.count >= 2 }.distinct
            if !names.isEmpty { out.append(Team(names: names, url: logo, leagues: [league])) }
        } } }
        return out
    }

    private static func encode(_ list: [Team]) -> String { jsonString(list.map { ["n": $0.names, "u": $0.url, "l": $0.leagues] as [String: Any] }) }
    private static func decode(_ s: String) -> [Team] {
        J.parse(s).array.compactMap { o in
            guard let u = o["u"].stringOrNil else { return nil }
            let names = o["n"].array.compactMap { $0.stringOrNil }
            return names.isEmpty ? nil : Team(names: names, url: u, leagues: o["l"].array.compactMap { $0.stringOrNil })
        }
    }
}
