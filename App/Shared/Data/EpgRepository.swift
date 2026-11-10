import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// EPG from a chain of sources, tried in order for every channel; the first one that knows a channel gives its schedule and
/// the following ones only extend it beyond the days already covered:
///  1. Sky Guida TV (broadcaster web guide: stills, synopsis, typed content) — ~140 channels incl. Rai / Mediaset / La7;
///  2. RaiPlay / Mediaset Infinity official schedules — for their own channels when Sky does not answer;
///  3. epgshare01 IT (XMLTV, 5 days); 4. iptv-epg.org IT (XMLTV); 5. the line's own xmltv.php; 6. DAZN's guide.
/// Every channel's programmes are stored under one id "nx:<streamId>"; "+1" channels get a shifted copy "<id>@60".
/// Cached in the database, refreshed every 6 h.
final class EpgRepository {
    private let db: AppDB
    init(db: AppDB) { self.db = db }

    func lastSync() -> Millis { db.metaInt64("epg_sync") }
    func isStale(maxAgeMs: Millis = 6 * Clock.hour) -> Bool { Clock.now - lastSync() > maxAgeMs || db.programmeCount() == 0 }
    /// Source stats of the last sync, for the settings page: "Sky 92 · epgshare01 31 · …".
    func lastReport() -> String? { db.meta("epg_report") }

    /// Per channel: the programmes gathered so far and the time span they cover.
    private final class Acc {
        var items = [ProgrammeEntity](); var from = Millis.max; var to = Millis.min; var src: String? = nil
        @discardableResult
        func add(_ list: [ProgrammeEntity], _ source: String) -> Bool {
            if list.isEmpty { return false }
            let sorted = list.sortedBy { $0.start }
            let fresh = items.isEmpty ? sorted : sorted.filter { $0.start >= to - Clock.minute || $0.stop <= from + Clock.minute }
            if fresh.isEmpty { return false }
            items += fresh
            from = min(from, fresh[0].start); to = max(to, fresh.map { $0.stop }.max() ?? to)
            if src == nil { src = source }
            return true
        }
    }

    private struct Feed {
        let name: String, url: String, prefix: String
        let namePrefix: Rx?
        func cleanName(_ n: String) -> String { namePrefix.map { $0.replace(n, "") } ?? n }
    }

    static let extUrl = "https://epgshare01.online/epgshare01/epg_ripper_IT1.xml.gz"
    static let extPrefix = "ext:"
    /// Bump when the source chain or the stored format changes: the guide is re-downloaded at the next start.
    static let version = "6.1"
    /// Placeholders the feeds put on idle event channels, in any language: shown as one Italian line.
    private static let noEvent = Rx.i(#"\s*(no game today|no games? scheduled|no event( today)?|no live event|nessun evento( in onda)?|offline|event only|events only|coming soon)\s*"#)
    private static let feeds = [
        Feed(name: "epgshare01", url: extUrl, prefix: extPrefix, namePrefix: nil),
        Feed(name: "iptvepg", url: "https://iptv-epg.org/files/epg-it.xml.gz", prefix: "iptvepg:", namePrefix: Rx(#"^IT\s*-\s*"#)),
    ]
    static let srcLabel: [String: String] = ["sky": "Sky", "rai": "RaiPlay", "mediaset": "Mediaset", "epgshare01": "epgshare01", "iptvepg": "iptv-epg.org", "dazn": "DAZN", "line": "linea"]

    /// Download the sources, resolve each channel, store everything. Returns programmes kept.
    func sync(lineXmltvUrl: String, channels: [ChannelEntity], onStatus: @escaping (String) -> Void = { _ in }) async throws -> Int {
        let bases = channels.filter { $0.shiftMin == 0 && !($0.event != nil && $0.categoryId == "events") }
        var acc = [String: Acc]()                       // streamId -> programmes
        var donors = [String: [ProgrammeEntity]]()     // streamId -> other sources' programmes (images, synopses)
        func accOf(_ c: ChannelEntity) -> Acc { if let a = acc[c.streamId] { return a }; let a = Acc(); acc[c.streamId] = a; return a }
        func donate(_ c: ChannelEntity, _ l: [ProgrammeEntity]) { if !l.isEmpty { donors[c.streamId, default: []] += l } }
        let now = Clock.now
        let from = now - 6 * Clock.hour
        let horizon = now + 5 * Clock.day

        // 1) Sky Guida TV
        onStatus("Aggiorno la guida TV (Sky)…")
        do {
            let idx = Broadcasters.skyIndex(try await Broadcasters.skyChannels())
            var bySky = [Int: [ChannelEntity]]()
            for c in bases {
                guard let sky = Broadcasters.skyAlias[c.name].flatMap({ idx[Broadcasters.key($0)] }) ?? idx[Broadcasters.key(c.name)] else { continue }
                bySky[sky.id, default: []].append(c)
                if let l = sky.logoDark { db.setLogo(c.streamId, Broadcasters.skyImg + l.substringBefore("?")) }
            }
            let events = await Broadcasters.skyEvents(Array(bySky.keys), from: from, days: 4).grouped { $0.epgId }
            NxLog.i("NxEpg", "sky: \(bySky.values.map { $0.count }.reduce(0, +)) channels matched on \(bySky.count) ids, events for \(events.count) ids")
            for (id, chs) in bySky { if let l = events["sky:\(id)"] { for c in chs { accOf(c).add(l, "sky") } } }
        } catch { NxLog.w("NxEpg", "sky failed: \(error)") }

        // 2) Rai / Mediaset official schedules: the schedule for their channels Sky did not cover, the pictures where Sky has none
        onStatus("Aggiorno la guida TV (Rai, Mediaset)…")
        func missingArt(_ c: ChannelEntity) -> Bool {
            guard let l = acc[c.streamId]?.items, !l.isEmpty else { return true }
            return Double(l.filter { $0.icon == nil }.count) > Double(l.count) * 0.3
        }
        let official: [(ChannelEntity, String, String)] = bases.filter { missingArt($0) }.compactMap { c in
            if let rai = Broadcasters.raiSlug[c.name] { return (c, "rai", rai) }
            if let ms = Broadcasters.mediasetCallSign[c.name] { return (c, "mediaset", ms) }
            return nil
        }
        let officialLists = await mapConcurrent(official, limit: 6) { o -> [ProgrammeEntity] in
            o.1 == "rai" ? await Broadcasters.rai(o.2, days: 4) : await Broadcasters.mediaset(o.2, from: from, days: 4)
        }
        for (o, list) in zip(official, officialLists) {
            if acc[o.0.streamId]?.items.isEmpty ?? true { accOf(o.0).add(list, o.1) } else { donate(o.0, list) }
        }

        // 3) epgshare01 IT, 4) iptv-epg.org IT: name-matched XMLTV feeds (they also extend the days of channels already covered)
        var iconCount = [String: Set<String>]()
        for c in channels { if let i = c.icon { iconCount[i, default: []].insert(c.name.removingSuffix(" +1")) } }
        let ambiguousIcons = Set(iconCount.filter { $0.value.count > 1 }.keys)
        for (n, feed) in EpgRepository.feeds.enumerated() {
            onStatus("Aggiorno la guida TV (\(n + 3)/5)…")
            var matched = [String: [ChannelEntity]]()      // feed channel id -> our channels
            var icons = [String: String]()
            var got = [ProgrammeEntity]()
            do {
                got = try await fetchXmltv(feed.url, prefix: feed.prefix) { index in
                    var byKey = [String: String]()
                    for (id, info) in index { for nm in info.names { let k = ChannelCatalog.epgKey(feed.cleanName(nm)); if byKey[k] == nil { byKey[k] = id } } }
                    for c in bases {
                        var id: String? = nil
                        if feed.prefix == EpgRepository.extPrefix, let e = ChannelCatalog.extEpg[c.name], index[e] != nil { id = e }
                        if id == nil { id = byKey[ChannelCatalog.epgKey(c.name)] }
                        guard let fid = id else { continue }
                        matched[fid, default: []].append(c)
                        if let icon = index[fid]?.icon, c.icon == nil || ambiguousIcons.contains(c.icon!) { icons[c.streamId] = icon }
                    }
                    return Set(matched.keys)
                }
            } catch { NxLog.w("NxEpg", "\(feed.name) failed: \(error)") }
            let byId = got.grouped { $0.epgId.removingPrefix(feed.prefix) }
            for (id, chs) in matched { if let l = byId[id] { for c in chs { accOf(c).add(l, feed.name); donate(c, l) } } }
            if n == 0 { for (sid, icon) in icons { db.setIcon(sid, icon) } }
        }

        // 5) the line's own feed for whatever is still unknown
        let lineWanted = bases.filter { (acc[$0.streamId]?.items.isEmpty ?? true) && $0.lineEpgId != nil }
        if !lineWanted.isEmpty {
            onStatus("Aggiorno la guida TV (5/5)…")
            let ids = Set(lineWanted.compactMap { $0.lineEpgId })
            do {
                let line = try await fetchXmltv(lineXmltvUrl, prefix: "") { _ in ids }.grouped { $0.epgId }
                for c in lineWanted { if let l = line[c.lineEpgId ?? ""] { accOf(c).add(l, "line") } }
            } catch { NxLog.w("NxEpg", "line feed failed: \(error)") }
        }

        // pictures and synopses from the other sources where the first one had none (same channel, same slot)
        var filled = 0
        for (sid, a) in acc {
            guard let d = donors[sid]?.filter({ $0.icon != nil || $0.desc != nil }).sortedBy({ $0.start }), !d.isEmpty else { continue }
            for i in a.items.indices {
                let p = a.items[i]
                if p.icon != nil && p.desc != nil { continue }
                guard let m = d.first(where: { o in abs(o.start - p.start) <= 10 * Clock.minute && (o.src == "rai" || o.src == "mediaset" || EpgRepository.sameShow(o, p)) }) else { continue }
                var x = p; x.icon = p.icon ?? m.icon; x.desc = p.desc ?? m.desc; x.poster = p.poster ?? m.poster
                a.items[i] = x
                if p.icon == nil && m.icon != nil { filled += 1 }
            }
        }
        NxLog.i("NxEpg", "pictures borrowed from other sources: \(filled)")

        // 6) DAZN: the line's DAZN channels (events, Serie A/B team feeds, Zona) get DAZN's own guide; every other channel's
        //    sport programme that is the same match takes DAZN's picture and synopsis where its source had only a placeholder
        onStatus("Aggiorno la guida TV (DAZN)…")
        let daznChannels = channels.filter { $0.shiftMin == 0 && ($0.name.hasPrefix("DAZN") || $0.name.hasPrefix("Zona")) }
        let daznEvents = await Dazn.events(days: 5)
        if !daznEvents.isEmpty {
            var own = 0
            for c in daznChannels {
                let l = Dazn.forChannel(c, daznEvents)
                if !l.isEmpty { accOf(c).add(l, "dazn"); own += 1 }
            }
            var dressed = 0
            for (_, a) in acc where a.src != "dazn" {
                for i in a.items.indices {
                    let p = a.items[i]
                    if p.kind != nil && p.kind != "sport" { continue }
                    let gArt = Dazn.genericArt(p), gText = Dazn.genericText(p)
                    if !gArt && !gText { continue }
                    guard let e = Dazn.sameEvent(p, daznEvents) else { continue }
                    var x = p
                    if gArt { x.icon = e.image ?? e.background ?? p.icon }
                    if gText { x.desc = e.desc ?? p.desc }
                    x.poster = p.poster ?? e.poster; x.kind = p.kind ?? "sport"; x.category = p.category ?? e.sport.nilIfBlank; x.subtitle = p.subtitle ?? e.competition.nilIfBlank
                    a.items[i] = x
                    dressed += 1
                }
            }
            NxLog.i("NxEpg", "dazn: \(daznEvents.count) events, \(own)/\(daznChannels.count) DAZN channels with a schedule, \(dressed) sport programmes dressed")
        }
        // team crests / flags for the match cards (ESPN weekly + the DAZN contestants just fetched)
        await Crests.sync(db, daznEvents)

        // store under "nx:<streamId>", "+1" channels as shifted copies of their base
        var all = [ProgrammeEntity](); all.reserveCapacity(40_000)
        var resolved = [String: String]()
        let baseIds = Set(bases.map { $0.streamId })
        for c in bases + daznChannels.filter({ !baseIds.contains($0.streamId) }) {
            guard let a = acc[c.streamId], !a.items.isEmpty else { continue }
            let id = "nx:\(c.streamId)"
            for p in a.items where p.stop > from && p.start < horizon + Clock.day {
                var x = p; x.id = 0; x.epgId = id
                if EpgRepository.noEvent.matches(p.title) { x.title = "Nessun evento in onda"; x.desc = nil }
                all.append(x)
            }
            resolved[c.streamId] = id
        }
        if all.isEmpty { throw HttpError(status: 0, url: "no EPG data from any source") }
        let baseByName = Dictionary(bases.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for c in channels where c.shiftMin > 0 {
            guard let base = baseByName[c.name.removingSuffix(" +1")], let a = acc[base.streamId] else { continue }
            let vid = "nx:\(base.streamId)@\(c.shiftMin)"; let shift = Millis(c.shiftMin) * Clock.minute
            for p in a.items { var x = p; x.id = 0; x.epgId = vid; x.start = p.start + shift; x.stop = p.stop + shift; all.append(x) }
            resolved[c.streamId] = vid
            if let logo = db.channel(base.streamId)?.logo { db.setLogo(c.streamId, logo) }
        }

        db.replaceProgrammes(all)
        for c in channels { let id = resolved[c.streamId]; if id != c.epgId { db.setEpgId(c.streamId, id) } }
        var counts = [String: Int]()
        for a in acc.values { if let s = a.src { counts[s, default: 0] += 1 } }
        let report = counts.sorted { $0.value > $1.value }.map { "\(EpgRepository.srcLabel[$0.key] ?? $0.key) \($0.value)" }.joined(separator: " · ")
        db.setMeta("epg_report", "\(report) · \(channels.count - resolved.count) senza guida")
        db.setMeta("epg_sync", String(Clock.now))
        db.touchChannels()
        NxLog.i("NxEpg", "stored \(all.count) programmes, \(resolved.count)/\(channels.count) channels with EPG — \(report)")
        return all.count
    }

    /// Same slot, plausibly the same programme: a shared meaningful word, or one title containing the other.
    private static func sameShow(_ a: ProgrammeEntity, _ b: ProgrammeEntity) -> Bool {
        let x = MetaText.norm(a.show ?? a.title), y = MetaText.norm(b.show ?? b.title)
        if x.isEmpty || y.isEmpty { return false }
        if x.contains(y) || y.contains(x) { return true }
        let wx = Set(x.split(separator: " ").filter { $0.count >= 4 })
        return y.split(separator: " ").contains { $0.count >= 4 && wx.contains($0) }
    }

    /// Downloads an XMLTV document (gzip or plain) to a temporary file and parses it as a stream.
    private func fetchXmltv(_ url: String, prefix: String, select: @escaping ([String: XmltvParser.ChannelInfo]) -> Set<String>) async throws -> [ProgrammeEntity] {
        let id = UUID().uuidString
        let raw = Paths.tmp.appendingPathComponent("xmltv-\(id).bin"), xml = Paths.tmp.appendingPathComponent("xmltv-\(id).xml")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: xml) }
        try await Http.download(url, to: raw)
        var source = raw
        if Gzip.isGzip(raw) { try Gzip.expand(raw, to: xml); source = xml }
        let parser = XmltvParser(prefix: prefix, select: select)
        return try parser.parse(source)
    }
}

/// Streams an XMLTV document. `<channel>` elements (which precede programmes) are collected into an index id -> display names;
/// `select` receives the index once and returns the channel ids to keep. Kept programmes get `prefix` + id as epgId.
final class XmltvParser: NSObject, XMLParserDelegate {
    final class ChannelInfo { var names = [String](); var icon: String? = nil }

    private let prefix: String
    private let select: ([String: ChannelInfo]) -> Set<String>
    private var index = [String: ChannelInfo]()
    private var wanted: Set<String>? = nil
    private var out = [ProgrammeEntity]()

    // state
    private var channelId: String? = nil
    private var inProgramme = false, keep = false
    private var chan = "", start: Millis? = nil, stop: Millis? = nil
    private var title = "", desc: String? = nil, icon: String? = nil, cat: String? = nil, sub: String? = nil, epNum: String? = nil, year: Int? = nil
    private var epSystem: String? = nil
    private var text = ""
    private var collecting = false

    private static let seRx = Rx.i(#"^S\d+\s*E\d+$"#)
    private static let seFix = Rx(#"S(\d+)\s*E"#)
    private static let dateEp = Rx(#"S(19|20)\d\d\b"#)

    init(prefix: String, select: @escaping ([String: ChannelInfo]) -> Set<String>) { self.prefix = prefix; self.select = select }

    func parse(_ file: URL) throws -> [ProgrammeEntity] {
        guard let stream = InputStream(url: file) else { throw HttpError(status: 0, url: "xmltv open") }
        let p = XMLParser(stream: stream)
        p.delegate = self
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        if !p.parse() && out.isEmpty { throw p.parserError ?? HttpError(status: 0, url: "xmltv parse") }
        return out
    }

    /// "20261110203000 +0100" / "20261110203000" (UTC) -> epoch ms.
    static func timestamp(_ s: String?) -> Millis? {
        guard let s = s else { return nil }
        let u = Array(s.utf8)
        if u.count < 14 { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) { let c = Int(u[i]) - 48; if c < 0 || c > 9 { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let mi = num(10, 2), let se = num(12, 2) else { return nil }
        // days from civil (Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        var secs = Int64(days) * 86_400 + Int64(h * 3600 + mi * 60 + se)
        // optional zone " +0100"
        var i = 14
        while i < u.count && u[i] == 32 { i += 1 }
        if i + 4 < u.count, (u[i] == 43 || u[i] == 45), let zh = num(i + 1, 2), let zm = num(i + 3, 2) {
            let off = Int64(zh * 3600 + zm * 60)
            secs -= u[i] == 43 ? off : -off
        }
        return secs * 1000
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        if inProgramme {
            if !keep { return }
            switch name {
            case "title", "sub-title", "desc", "category", "date": text = ""; collecting = true
            case "episode-num": text = ""; collecting = true; epSystem = attrs["system"]
            case "icon": if icon == nil, let s = attrs["src"], !s.isBlank { icon = s }
            default: break
            }
            return
        }
        if let cid = channelId {
            if name == "display-name" { text = ""; collecting = true }
            else if name == "icon", let info = index[cid], info.icon == nil, let s = attrs["src"], !s.isBlank { info.icon = s }
            return
        }
        if name == "channel" {
            let id = attrs["id"] ?? ""
            channelId = id
            if index[id] == nil { index[id] = ChannelInfo() }
        } else if name == "programme" {
            if wanted == nil { wanted = select(index) }
            inProgramme = true
            chan = attrs["channel"] ?? ""
            keep = wanted?.contains(chan) ?? false
            if keep {
                start = XmltvParser.timestamp(attrs["start"]); stop = XmltvParser.timestamp(attrs["stop"])
                title = ""; desc = nil; icon = nil; cat = nil; sub = nil; epNum = nil; year = nil
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if inProgramme {
            if name == "programme" {
                if keep, let s = start, let e = stop, !title.isEmpty {
                    // the feed lists "S2026 E81" for sport: that is a date, not an episode
                    if let ep = epNum, XmltvParser.dateEp.contains(ep) { epNum = nil }
                    let src = prefix.isEmpty ? "line" : prefix.removingSuffix(":")
                    out.append(ProgrammeEntity(epgId: prefix + chan, start: s, stop: e, title: Broadcasters.fixText(title), desc: desc.map { Broadcasters.fixText($0) }, icon: icon, category: cat,
                                               subtitle: sub, episode: epNum, year: year, kind: Broadcasters.kindFromCategory(cat), show: Broadcasters.cleanShowTitle(title), src: src))
                }
                inProgramme = false; keep = false; collecting = false
                return
            }
            if !keep || !collecting { return }
            let v = text.trimmed
            collecting = false
            switch name {
            case "title": title = v
            case "sub-title": sub = v.isEmpty ? nil : v
            case "desc": desc = v.isEmpty ? nil : v
            case "category": if cat == nil && !v.isEmpty { cat = v }
            case "date": year = Int(v.prefix(4))
            case "episode-num":
                if epNum == nil && !v.isEmpty {
                    if epSystem == "xmltv_ns" {
                        let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { String($0).trimmed }
                        let s = parts.first.flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") }.map { $0 + 1 }
                        let e = parts[safe: 1].flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") }.map { $0 + 1 }
                        if let e = e { epNum = "S\(s ?? 1) E\(e)" }
                    } else if XmltvParser.seRx.matches(v) {
                        epNum = XmltvParser.seFix.replace(v.uppercased(), "S$1 E")
                    }
                }
            default: break
            }
            return
        }
        if channelId != nil {
            if name == "display-name" { collecting = false; if let cid = channelId { index[cid]?.names.append(text.trimmed) } }
            else if name == "channel" { channelId = nil }
        }
    }
}
