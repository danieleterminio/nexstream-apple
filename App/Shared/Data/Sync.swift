import Foundation

/// Keeps what belongs to the viewer the same on every device of the line: profiles, favourites, the list, positions,
/// tastes, reminders, teams, viewing settings. The line's username and password are the account; everything is
/// encrypted before it leaves the device. The rules are in docs/sync-protocol.md and are the same on Android.
final class SyncEngine {
    static let endpoint = "https://nexstream-sync.nexxst.workers.dev/v1/sync"

    /// Something left half way on another device of the line.
    struct Other: Hashable {
        let profileId: Int64
        let media: String
        let tmdbId: Int
        let season: Int
        let episode: Int
        let pos: Millis
        let dur: Millis
        let dev: String
        let at: Millis
    }

    let others = Observable<[Other]>([])
    /// When the last round ended well (0 = never).
    let lastSync = Observable<Millis>(0)
    /// How this device is called in "Stavi guardando su …".
    var deviceName: () -> String = { "Dispositivo" }
    /// Called after remote data changed the profiles.
    var onProfilesChanged: (() -> Void)?

    private let db: AppDB
    private let session: Session
    private let profiles: Profiles
    private let prefs: Prefs
    private let settings: Settings
    private let lock = AsyncLock()
    private var pending: Task<Void, Never>? = nil
    private var applying = false
    private let d = UserDefaults.standard

    /// What this device remembers about an account between rounds.
    private struct State {
        var seq = 0
        /// The first contact with the server has been made (online-wins decided).
        var started = false
        var snap = [String: String]()
        var times = [String: Int64]()
        /// Server name -> plain name, to understand deletes.
        var names = [String: String]()
        /// Device that last wrote each `prog` record.
        var devs = [String: String]()
        /// Records that arrived before their profile.
        var orphans = [String: [String: Any]]()
    }
    private var state = State()
    private var loadedFor = ""

    init(db: AppDB, session: Session, profiles: Profiles, prefs: Prefs, settings: Settings) {
        self.db = db; self.session = session; self.profiles = profiles; self.prefs = prefs; self.settings = settings
    }

    // MARK: when

    /// Asks for a round soon. Calls made while one is waiting are merged.
    func kick(after seconds: Double = 2) {
        if applying { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.run()
        }
    }

    /// The line was disconnected: forget where the sync was (the local data stays).
    func forgetAccount() {
        pending?.cancel()
        if !loadedFor.isEmpty { try? FileManager.default.removeItem(at: file(loadedFor)) }
        state = State(); loadedFor = ""
        others.value = []
    }

    func run() async {
        guard Vpn.shared.active.value, let s = session.current.value else { return }
        var user = s.username, pass = s.password
        if Demo.enabled {
            // the fake line of the build pipeline never syncs, unless a throw-away account is named on the command line
            guard let t = Demo.value("-nxSync") else { return }
            user = t; pass = "pipeline"
        }
        await lock.lock()
        defer { Task { await self.lock.unlock() } }
        let aid = SyncCrypto.accountId(user: user, pass: pass)
        let key = SyncCrypto.key(user: user, pass: pass)
        if loadedFor != aid { load(aid) }
        do {
            if !state.started { try await firstContact(aid, key) }
            try await round(aid, key)
            save(aid)
            lastSync.value = Clock.now
            publishOthers()
        } catch {
            NxLog.w("NxSync", "round failed: \(error)")
        }
    }

    // MARK: state on disk

    private func file(_ aid: String) -> URL { Paths.support.appendingPathComponent("sync-\(aid.prefix(16)).json") }

    private func load(_ aid: String) {
        state = State(); loadedFor = aid
        guard let data = try? Data(contentsOf: file(aid)), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        state.seq = (o["seq"] as? NSNumber)?.intValue ?? 0
        state.started = (o["started"] as? Bool) ?? false
        state.snap = (o["snap"] as? [String: String]) ?? [:]
        state.names = (o["names"] as? [String: String]) ?? [:]
        state.devs = (o["devs"] as? [String: String]) ?? [:]
        for (k, v) in (o["times"] as? [String: NSNumber]) ?? [:] { state.times[k] = v.int64Value }
        state.orphans = (o["orphans"] as? [String: [String: Any]]) ?? [:]
    }

    private func save(_ aid: String) {
        var times = [String: NSNumber]()
        for (k, v) in state.times { times[k] = NSNumber(value: v) }
        let o: [String: Any] = ["seq": state.seq, "started": state.started, "snap": state.snap, "names": state.names, "devs": state.devs, "times": times, "orphans": state.orphans]
        if let data = try? JSONSerialization.data(withJSONObject: o) { try? data.write(to: file(aid), options: Data.WritingOptions.atomic) }
    }

    // MARK: profile ids

    private func uuid(_ pid: Int64) -> String {
        if let u = db.meta("puid.\(pid)"), !u.isEmpty { return u }
        let u = UUID().uuidString.lowercased()
        db.setMeta("puid.\(pid)", u)
        return u
    }
    private func localId(_ uuid: String) -> Int64? {
        for p in db.profiles() where db.meta("puid.\(p.id)") == uuid { return p.id }
        return nil
    }

    // MARK: local records

    private func canonical(_ v: [String: Any]) -> String {
        var x = v
        x["dev"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys]) else { return "" }
        return String(SyncCrypto.hex(SyncCrypto.sha256(String(decoding: data, as: UTF8.self))).prefix(20))
    }

    private func textPref(_ pid: Int64) -> String { d.string(forKey: "prefs.p\(pid).text") ?? "" }

    /// Everything of this device that the protocol carries, by plain record name.
    private func localRecords() -> [String: [String: Any]] {
        var out = [String: [String: Any]]()
        var ids = [Int64: String]()
        for p in db.profiles() {
            let u = uuid(p.id)
            ids[p.id] = u
            var v: [String: Any] = ["name": p.name, "color": p.avatarColor, "icon": p.avatarIcon, "kids": p.kids, "maturity": p.maturity, "created": p.createdAt]
            if let pin = p.pin, !pin.isEmpty { v["pin"] = pin }
            out["profile/\(u)"] = v
            if let raw = db.meta("teams.\(p.id)") {
                let list: [[String: Any]] = J.parse(raw).array.map { ["n": $0["n"].string, "c": $0["c"].string] }
                if !list.isEmpty { out["teams/\(u)"] = ["list": list] }
            }
            out["set/\(u)"] = ["audio": settings.audioLang(p.id), "text": textPref(p.id), "autoplay": settings.autoplay(p.id), "credits": settings.creditsPrompt(p.id),
                               "swHours": settings.stillWatchingHours(p.id), "swEps": settings.stillWatchingEpisodes(p.id), "speed": Double(settings.speed(p.id))]
        }
        for r in db.rows("SELECT profileId, streamId, addedAt FROM favorites", [], { ($0.int64(0), $0.string(1), $0.int64(2)) }) {
            if let u = ids[r.0] { out["fav/\(u)/\(r.1)"] = ["at": r.2] }
        }
        for r in db.rows("SELECT profileId, streamId, watchedAt FROM recents", [], { ($0.int64(0), $0.string(1), $0.int64(2)) }) {
            if let u = ids[r.0] { out["recent/\(u)/\(r.1)"] = ["at": r.2] }
        }
        for r in db.rows("SELECT profileId, \"key\", seconds, updatedAt FROM usage", [], { ($0.int64(0), $0.string(1), $0.double(2), $0.int64(3)) }) {
            if let u = ids[r.0] { out["usage/\(u)/\(r.1)"] = ["s": (r.2 * 10).rounded() / 10, "at": r.3] }
        }
        for r in db.rows("SELECT profileId, tmdbId, media, addedAt FROM list_item", [], { ($0.int64(0), $0.int(1), $0.string(2), $0.int64(3)) }) {
            if let u = ids[r.0] { out["list/\(u)/\(r.2)/\(r.1)"] = ["at": r.3] }
        }
        for r in db.rows("SELECT profileId, tmdbId, media, season, episode, positionMs, durationMs, completed, updatedAt FROM progress", [],
                         { ($0.int64(0), $0.int(1), $0.string(2), $0.int(3), $0.int(4), $0.int64(5), $0.int64(6), $0.bool(7), $0.int64(8)) }) {
            if let u = ids[r.0] { out["prog/\(u)/\(r.2)/\(r.1)/\(r.3)/\(r.4)"] = ["pos": r.5, "dur": r.6, "done": r.7, "at": r.8] }
        }
        for (pid, u) in ids {
            for r in db.rows("SELECT tmdbId, media, kind, weight, at FROM watch_event WHERE profileId = ? ORDER BY at DESC LIMIT 1500", [pid],
                             { ($0.int(0), $0.string(1), $0.string(2), $0.double(3), $0.int64(4)) }) {
                out["ev/\(u)/\(r.4)/\(r.1)/\(r.0)/\(r.2)"] = ["w": r.3]
            }
        }
        for r in db.rows("SELECT profileId, streamId, at, title, sub, createdAt FROM reminders", [], { ($0.int64(0), $0.string(1), $0.int64(2), $0.string(3), $0.stringOrNil(4), $0.int64(5)) }) {
            guard let u = ids[r.0] else { continue }
            var v: [String: Any] = ["at": r.2, "title": r.3, "created": r.5]
            if let s = r.4 { v["sub"] = s }
            out["rem/\(u)/\(r.1)"] = v
        }
        return out
    }

    // MARK: applying what comes from the server

    /// Applies one record (nil = it was deleted). False when its profile is not known yet.
    private func apply(_ key: String, _ v: [String: Any]?) -> Bool {
        let p = key.components(separatedBy: "/")
        guard p.count >= 2 else { return true }
        let j = J(v)
        if p[0] == "profile" {
            let existing = localId(p[1])
            guard v != nil else {
                if let id = existing {
                    db.deleteProfileCascade(id)
                    db.run("DELETE FROM meta WHERE \"key\" IN (?, ?)", ["puid.\(id)", "teams.\(id)"], touch: "meta")
                    if profiles.id == id { profiles.deselect() }
                }
                return true
            }
            var e = existing.flatMap { db.profile($0) } ?? ProfileEntity(name: "")
            e.name = j["name"].string
            e.avatarColor = j["color"].int
            e.avatarIcon = j["icon"].int
            e.kids = j["kids"].boolOrNil ?? false
            e.maturity = j["maturity"].intOrNil ?? 2
            e.pin = j["pin"].stringOrNil?.nilIfBlank
            e.createdAt = j["created"].int64OrNil ?? e.createdAt
            if existing != nil { db.upsertProfile(e) } else {
                let id = db.insertProfile(e)
                if id > 0 { db.setMeta("puid.\(id)", p[1]) }
            }
            return true
        }
        guard let pid = localId(p[1]) else { return v == nil }
        switch p[0] {
        case "fav" where p.count >= 3:
            let sid = p[2...].joined(separator: "/")
            if v == nil { db.run("DELETE FROM favorites WHERE profileId = ? AND streamId = ?", [pid, sid], touch: "favorites") }
            else { db.run("INSERT OR REPLACE INTO favorites(profileId, streamId, addedAt) VALUES(?,?,?)", [pid, sid, j["at"].int64OrNil ?? Clock.now], touch: "favorites") }
        case "recent" where p.count >= 3:
            let sid = p[2...].joined(separator: "/")
            if v == nil { db.run("DELETE FROM recents WHERE profileId = ? AND streamId = ?", [pid, sid], touch: "recents") }
            else { db.run("INSERT OR REPLACE INTO recents(profileId, streamId, watchedAt) VALUES(?,?,?)", [pid, sid, j["at"].int64OrNil ?? Clock.now], touch: "recents") }
        case "usage" where p.count >= 3:
            let k = p[2...].joined(separator: "/")
            if v == nil { db.run("DELETE FROM usage WHERE profileId = ? AND \"key\" = ?", [pid, k], touch: "usage") }
            else { db.run("INSERT OR REPLACE INTO usage(profileId, \"key\", seconds, updatedAt) VALUES(?,?,?,?)", [pid, k, j["s"].double, j["at"].int64OrNil ?? Clock.now], touch: "usage") }
        case "list" where p.count == 4:
            guard let id = Int(p[3]) else { return true }
            if v == nil { db.run("DELETE FROM list_item WHERE profileId = ? AND tmdbId = ? AND media = ?", [pid, id, p[2]], touch: "list_item") }
            else { db.run("INSERT OR REPLACE INTO list_item(profileId, tmdbId, media, addedAt) VALUES(?,?,?,?)", [pid, id, p[2], j["at"].int64OrNil ?? Clock.now], touch: "list_item") }
        case "prog" where p.count == 6:
            guard let id = Int(p[3]), let s = Int(p[4]), let e = Int(p[5]) else { return true }
            if v == nil {
                db.run("DELETE FROM progress WHERE profileId = ? AND tmdbId = ? AND media = ? AND season = ? AND episode = ?", [pid, id, p[2], s, e], touch: "progress")
                state.devs[key] = nil
            } else {
                db.run("INSERT OR REPLACE INTO progress(profileId, tmdbId, media, season, episode, positionMs, durationMs, completed, updatedAt) VALUES(?,?,?,?,?,?,?,?,?)",
                       [pid, id, p[2], s, e, j["pos"].int64OrNil ?? 0, j["dur"].int64OrNil ?? 0, j["done"].boolOrNil ?? false, j["at"].int64OrNil ?? Clock.now], touch: "progress")
                state.devs[key] = j["dev"].stringOrNil
            }
        case "ev" where p.count == 6:
            guard let at = Int64(p[2]), let id = Int(p[4]) else { return true }
            db.run("DELETE FROM watch_event WHERE profileId = ? AND tmdbId = ? AND media = ? AND kind = ? AND at = ?", [pid, id, p[3], p[5], at])
            if v != nil { db.run("INSERT INTO watch_event(profileId, tmdbId, media, kind, weight, at) VALUES(?,?,?,?,?,?)", [pid, id, p[3], p[5], j["w"].double, at], touch: "watch_event") }
        case "rem" where p.count >= 3:
            let sid = p[2...].joined(separator: "/")
            if v == nil { db.run("DELETE FROM reminders WHERE profileId = ? AND streamId = ?", [pid, sid], touch: "reminders") }
            else {
                db.run("INSERT OR REPLACE INTO reminders(profileId, streamId, at, title, sub, createdAt) VALUES(?,?,?,?,?,?)",
                       [pid, sid, j["at"].int64OrNil ?? 0, j["title"].string, j["sub"].stringOrNil, j["created"].int64OrNil ?? Clock.now], touch: "reminders")
            }
        case "teams":
            if v == nil { db.run("DELETE FROM meta WHERE \"key\" = ?", ["teams.\(pid)"], touch: "meta") }
            else { db.setMeta("teams.\(pid)", jsonString(j["list"].array.map { ["n": $0["n"].string, "c": $0["c"].string] })) }
        case "set":
            guard v != nil else { return true }
            if let a = j["audio"].stringOrNil { settings.setAudioLang(pid, a) }
            if let b = j["autoplay"].boolOrNil { settings.setAutoplay(pid, b) }
            if let b = j["credits"].boolOrNil { settings.setCreditsPrompt(pid, b) }
            if let n = j["swHours"].intOrNil { settings.setStillWatchingHours(pid, n) }
            if let n = j["swEps"].intOrNil { settings.setStillWatchingEpisodes(pid, n) }
            if let s = j["speed"].doubleOrNil { settings.setSpeed(pid, Float(s)) }
            if let t = j["text"].stringOrNil {
                d.set(t, forKey: "prefs.p\(pid).text")
                if profiles.id == pid { prefs.setProfile(pid) }
            }
        default: break
        }
        return true
    }

    // MARK: wire

    private struct Incoming { let kid: String; let t: Int64; let key: String?; let v: [String: Any]?; let deleted: Bool }

    private func call(_ aid: String, _ key: Data, since: Int, changes: [[String: Any]]) async throws -> (seq: Int, more: Bool, list: [Incoming]) {
        let body: [String: Any] = ["since": since, "dev": deviceName(), "changes": changes]
        let data = try JSONSerialization.data(withJSONObject: body)
        let r = try await Http.request(SyncEngine.endpoint, method: "POST", headers: ["Content-Type": "application/json", "X-Account": aid], body: data, timeout: 25)
        guard r.status == 200 else { throw HttpError(status: r.status, url: SyncEngine.endpoint) }
        let j = J.parse(r.data)
        var list = [Incoming]()
        for c in j["changes"].array {
            let kid = c["k"].string
            let t = c["t"].int64OrNil ?? 0
            if let dd = c["d"].stringOrNil, let plain = SyncCrypto.open(key, dd), let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any], let k = o["k"] as? String {
                state.names[kid] = k
                list.append(Incoming(kid: kid, t: t, key: k, v: o["v"] as? [String: Any] ?? [:], deleted: false))
            } else if !c["d"].exists {
                list.append(Incoming(kid: kid, t: t, key: state.names[kid], v: nil, deleted: true))
            }
        }
        return (j["seq"].intOrNil ?? since, j["more"].boolOrNil ?? false, list)
    }

    /// Applies a batch, profiles first, and brings the snapshot in line with what is now in the database.
    private func applyAll(_ list: [Incoming]) {
        if list.isEmpty && state.orphans.isEmpty { return }
        applying = true
        defer { applying = false }
        var touched = Set<String>()
        var profilesChanged = false
        let ordered = list.filter { $0.key?.hasPrefix("profile/") == true } + list.filter { $0.key?.hasPrefix("profile/") != true }
        for c in ordered {
            guard let k = c.key else { continue }
            if let known = state.times[k], known >= c.t { continue }
            state.times[k] = c.t
            touched.insert(k)
            if k.hasPrefix("profile/") { profilesChanged = true }
            if c.deleted { _ = apply(k, nil); state.orphans[k] = nil }
            else if let v = c.v, !apply(k, v) { state.orphans[k] = v }
        }
        // records that were waiting for their profile
        for (k, v) in state.orphans where apply(k, v) { state.orphans[k] = nil; touched.insert(k) }
        if state.orphans.count > 4000 { state.orphans = [:] }
        let now = localRecords()
        for k in touched { state.snap[k] = now[k].map { canonical($0) } }
        if profilesChanged { profiles.refresh(); onProfilesChanged?() }
    }

    /// First time this device talks to the account: if the account already has profiles, they replace the local ones.
    private func firstContact(_ aid: String, _ key: Data) async throws {
        var all = [Incoming]()
        var since = 0
        while true {
            let r = try await call(aid, key, since: since, changes: [])
            all += r.list
            since = r.seq
            if !r.more { break }
        }
        let online = all.contains { !$0.deleted && $0.key?.hasPrefix("profile/") == true }
        NxLog.i("NxSync", "first contact: \(all.count) records online, profiles online: \(online)")
        if online {
            for p in db.profiles() {
                db.deleteProfileCascade(p.id)
                db.run("DELETE FROM meta WHERE \"key\" IN (?, ?)", ["puid.\(p.id)", "teams.\(p.id)"], touch: "meta")
            }
            profiles.deselect()
            state.snap = [:]; state.times = [:]; state.orphans = [:]; state.devs = [:]
            applyAll(all)
            onProfilesChanged?()
        }
        state.seq = since
        state.started = true
        save(aid)
    }

    private func round(_ aid: String, _ key: Data) async throws {
        let local = localRecords()
        let now = Clock.now
        let me = deviceName()
        var changes = [[String: Any]]()
        var sentHash = [String: String?]()
        for (k, v) in local {
            let h = canonical(v)
            if state.snap[k] == h { continue }
            var out = v
            if k.hasPrefix("prog/") { out["dev"] = me; state.devs[k] = me }
            guard let plain = try? JSONSerialization.data(withJSONObject: ["k": k, "v": out] as [String: Any]), let sealed = SyncCrypto.seal(key, plain) else { continue }
            let kid = SyncCrypto.kid(key, k)
            state.names[kid] = k
            changes.append(["k": kid, "t": now, "d": sealed])
            sentHash[k] = h
        }
        for k in state.snap.keys where local[k] == nil {
            changes.append(["k": SyncCrypto.kid(key, k), "t": now, "d": NSNull()])
            sentHash[k] = Optional<String>.none
        }
        var incoming = [Incoming]()
        var since = state.seq
        var parts = [[[String: Any]]]()
        var i = 0
        while i < changes.count { parts.append(Array(changes[i..<min(changes.count, i + 800)])); i += 800 }
        if parts.isEmpty { parts.append([]) }
        for part in parts {
            var r = try await call(aid, key, since: since, changes: part)
            incoming += r.list
            since = r.seq
            while r.more {
                r = try await call(aid, key, since: since, changes: [])
                incoming += r.list
                since = r.seq
            }
        }
        for (k, h) in sentHash {
            state.times[k] = now
            if let h = h { state.snap[k] = h } else { state.snap[k] = nil; state.devs[k] = nil }
        }
        state.seq = since
        if !changes.isEmpty || !incoming.isEmpty { NxLog.i("NxSync", "sent \(changes.count), received \(incoming.count), seq \(since)") }
        applyAll(incoming)
    }

    /// What was left half way on another device in the last three days, newest first.
    private func publishOthers() {
        let me = deviceName()
        let limit = Clock.now - 3 * Clock.day
        var out = [Other]()
        for (k, dev) in state.devs where dev != me && !dev.isEmpty {
            let p = k.components(separatedBy: "/")
            guard p.count == 6, let pid = localId(p[1]), let id = Int(p[3]), let s = Int(p[4]), let e = Int(p[5]) else { continue }
            guard let row = db.one("SELECT positionMs, durationMs, completed, updatedAt FROM progress WHERE profileId = ? AND tmdbId = ? AND media = ? AND season = ? AND episode = ?", [pid, id, p[2], s, e],
                                   { ($0.int64(0), $0.int64(1), $0.bool(2), $0.int64(3)) }), !row.2, row.3 >= limit, row.0 > 30_000 else { continue }
            out.append(Other(profileId: pid, media: p[2], tmdbId: id, season: s, episode: e, pos: row.0, dur: row.1, dev: dev, at: row.3))
        }
        out.sort { $0.at > $1.at }
        if out != others.value { others.value = out }
    }

    /// The profile's uuid, for "Riproduci su…".
    func profileUuid(_ pid: Int64) -> String { uuid(pid) }
    func profileId(uuid u: String) -> Int64? { localId(u) }
}
