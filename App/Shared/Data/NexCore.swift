import Foundation

/// Everything the screens talk to, built once at launch (the role `NexApp` has on Android).
final class NexCore {
    static let shared = NexCore()

    let db: AppDB
    let megaOtt = MegaOttApi()
    let session = Session()
    let prefs = Prefs()
    let settings = Settings()
    let watchSession = WatchSession()
    let loginRepo: LoginRepository
    let profiles: Profiles
    let channels: ChannelRepository
    let epg: EpgRepository
    let tmdb = TmdbApi()
    let meta: MetaRepository
    let usage: UsageRepository
    let reminders: Reminders
    let teams: Teams
    // ---- VOD (Stream4Me through the embedded Python, TMDB catalogue, per-profile library, recommender)
    let engine = Engine.shared
    let updater: AddonUpdater
    let searchIndex: SearchIndex
    let catalog: CatalogRepository
    let library: LibraryRepository
    let recommender: Recommender
    let resolver: PlaybackResolver
    /// Live <-> VOD bridge: recognised programmes <-> Stream4Me titles.
    let matcher: LiveVodMatcher
    /// The same profiles, lists and positions on every device of the line.
    let sync: SyncEngine
    /// Offline downloads (iPhone).
    lazy var downloads: Downloads = Downloads(core: self)
    /// Apple TV home (Top Shelf): "Continua a guardare" and favourite channels for the extension.
    lazy var topShelf: TopShelfPublisher = TopShelfPublisher(core: self)

    /// "Aggiorno i canali…" style status for the UI, nil when idle.
    let syncStatus = Observable<String?>(nil)
    /// A reminder whose time has come while the app is open: the UI shows it and clears it.
    let reminderAlert = Observable<ReminderEntity?>(nil)
    /// Channel to open from a notification / deep link: (streamId, profileId).
    let pendingOpen = Observable<(String, Int64)?>(nil)
    /// VOD title to open from a link: (media, tmdbId, profileId).
    let pendingOpenVod = Observable<(String, Int, Int64)?>(nil)
    /// VOD title to play from where it was left (Top Shelf play button): (media, tmdbId, profileId).
    let pendingResume = Observable<(String, Int, Int64)?>(nil)
    /// Programme page to open from a link: (streamId, programmeId, profileId).
    let pendingOpenProgramme = Observable<(String, Int64, Int64)?>(nil)
    /// A search typed on the phone remote, consumed by the search screen.
    let pendingSearch = Observable<String?>(nil)
    let openDownloads = Observable<Bool>(false)

    private let syncLock = AsyncLock()
    private let metaLock = AsyncLock()
    private var watches = [Watch]()
    private var started = false
    private var timer: DispatchSourceTimer?

    var xtream: XtreamClient? { session.current.value.map { XtreamClient(base: $0.base, username: $0.username, password: $0.password) } }

    private init() {
        // a player that hangs up on a local stream (the add-on's proxy, our live proxy) must not end the app
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
        let url = Paths.support.appendingPathComponent("nexstream.sqlite")
        var opened: AppDB? = try? AppDB(url: url)
        if opened == nil {
            // a damaged file must never keep the app from starting
            try? FileManager.default.removeItem(at: url)
            opened = try? AppDB(url: url)
        }
        if opened == nil { opened = try? AppDB(url: Paths.tmp.appendingPathComponent("nexstream-\(UUID().uuidString).sqlite")) }
        db = opened!
        loginRepo = LoginRepository(megaOtt: megaOtt, session: session)
        profiles = Profiles(db: db)
        channels = ChannelRepository(db: db, profiles: profiles)
        epg = EpgRepository(db: db)
        meta = MetaRepository(db: db, tmdb: tmdb)
        usage = UsageRepository(db: db, profiles: profiles)
        reminders = Reminders(db: db, profiles: profiles)
        teams = Teams(db: db, profiles: profiles)
        updater = AddonUpdater(engine: engine)
        searchIndex = SearchIndex(tmdb: tmdb, dir: Paths.support)
        catalog = CatalogRepository(tmdb: tmdb, db: db)
        catalog.index = searchIndex
        library = LibraryRepository(db: db)
        recommender = Recommender(db: db, catalog: catalog, library: library)
        resolver = PlaybackResolver(engine: engine, db: db)
        matcher = LiveVodMatcher(db: db, catalog: catalog, channels: channels, meta: meta)
        sync = SyncEngine(db: db, session: session, profiles: profiles, prefs: prefs, settings: settings)
    }

    /// Called once when the app starts.
    func start() {
        if started { return }
        started = true
        Vpn.shared.start()
        Backup.restoreIfNeeded(self)
        Demo.prepare(self)
        Crests.load(db)
        reminders.rescheduleAll()
        Task { await teams.scheduleAlerts() }
        // reminders and teams that arrive from another device ring here too
        sync.onAlertsChanged = { [weak self] in
            guard let self = self else { return }
            self.reminders.rescheduleAll()
            Task { await self.teams.scheduleAlerts() }
        }
        // per-profile playback preferences and the VOD catalogue's maturity follow the selected profile
        watches.append(profiles.current.observe { [weak self] p in
            guard let self = self else { return }
            self.prefs.setProfile(p?.id ?? 0)
            self.catalog.maturity = p?.level ?? 2
        })
        // nothing goes out before the VPN is up; every time it comes back, refresh what may have been missed
        watches.append(Vpn.shared.active.observe { [weak self] on in
            guard let self = self, on else { return }
            Task {
                await self.loginRepo.refreshDns()
                if self.session.current.value != nil { self.syncIfNeeded(); self.prefetchMeta() }
                await self.meta.refreshTrending()
            }
            // Stream4Me engine: warmed up after the live side is ready, so the first "Riproduci" is fast
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do { try await self.engine.ensureReady() } catch { NxLog.e("NxEngine", "warmup failed: \(error)") }
                await self.updater.check()
            }
            Task { try? await Task.sleep(nanoseconds: 5_000_000_000); await self.searchIndex.ensure() }
        })
        // personal data changes are mirrored where they survive a cache purge (tvOS)
        watches.append(db.changes.observe { table in if Backup.tables.contains(table) { Backup.schedule(self) } })
        // ...and sent to the other devices of the line
        let synced: Set<String> = ["profiles", "favorites", "recents", "usage", "list_item", "progress", "watch_event", "reminders", "meta"]
        watches.append(db.changes.observe { [weak self] table in if synced.contains(table) { self?.sync.kick() } })
        watches.append(settings.rev.observe { [weak self] _ in self?.sync.kick() })
        watches.append(prefs.values.observe { [weak self] _ in self?.sync.kick() })
        watches.append(session.current.observe { [weak self] s in if s != nil { self?.sync.kick(after: 1) } })
        watches.append(Vpn.shared.active.observe { [weak self] on in if on { self?.sync.kick(after: 3) } })
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 15, repeating: 20)
        var ticks = 0
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.checkAlerts()
            ticks += 1
            if ticks % 3 == 0 { self.sync.kick(after: 0) }
            // every 6 h: sources and search index; every 30 min: is the guide stale?
            if ticks % 90 == 0 && Vpn.shared.active.value && self.session.current.value != nil { self.syncIfNeeded() }
            if ticks % 1080 == 0 && Vpn.shared.active.value { Task { await self.updater.check(); await self.searchIndex.ensure() } }
        }
        t.resume()
        timer = t
    }

    /// The in-app "Sta per iniziare": reminders and followed-team matches whose moment has come.
    func checkAlerts() {
        let pid = profiles.id
        var due = reminders.takeDue()
        due += teams.takeDue(currentProfile: pid)
        if let mine = due.first(where: { $0.profileId == pid }) { reminderAlert.value = mine }
    }

    @discardableResult
    func toggleReminder(_ s: Showing) -> Bool {
        guard let at = s.start else { return false }
        return reminders.toggle(streamId: s.channel.streamId, at: at, title: s.title, sub: [s.channel.name, s.sub].compactMap { $0 }.joined(separator: " · "))
    }

    func logout() {
        sync.forgetAccount()
        session.clear()
        db.replaceLive([], [])
        db.replaceProgrammes([])
    }

    /// Channel list: refresh if older than 12 h or empty; EPG: refresh if older than 6 h. Safe to call often.
    func syncIfNeeded(force: Bool = false) {
        Task {
            if !Vpn.shared.active.value { return }
            await syncLock.lock()
            await doSync(force)
            await syncLock.unlock()
        }
    }

    private func doSync(_ force: Bool) async {
        guard let client = xtream else { return }
        let staleChannels = force || !channels.hasChannels() || Clock.now - channels.lastSync() > 12 * Clock.hour
        if staleChannels {
            syncStatus.value = "Aggiorno i canali…"
            do { let n = try await channels.sync(client, hevcOk: prefs.values.value.hevc); NxLog.i("NxSync", "\(n) channels") }
            catch { NxLog.w("NxSync", "channels: \(error)") }
        }
        var epgUpdated = false
        let epgOutdated = db.meta("epg_ver") != EpgRepository.version
        if force || staleChannels || epgOutdated || epg.isStale() {
            syncStatus.value = "Aggiorno la guida TV…"
            do {
                _ = try await epg.sync(lineXmltvUrl: client.xmltvUrl(), channels: channels.all()) { [weak self] s in self?.syncStatus.value = s }
                epgUpdated = true
                db.setMeta("epg_ver", EpgRepository.version)
            } catch { NxLog.w("NxSync", "epg: \(error)") }
        }
        syncStatus.value = nil
        if epgUpdated { prefetchMeta(); await teams.scheduleAlerts() }
    }

    /// Called by the player: how long a channel was watched, credited to the programme on air when it was tuned.
    func recordWatch(_ c: ChannelEntity, startedAt: Millis) {
        let secs = Int((Clock.now - startedAt) / 1000)
        if secs < 20 { return }
        let p = c.epgId.flatMap { db.programmesBetween($0, startedAt, startedAt + 1).first }
        let m = p.flatMap { meta.get(meta.keyOf($0)) }.flatMap { $0.found ? $0 : nil }
        let kind: String? = p.map { meta.kindOf($0, c).rawValue } ?? (c.isEvent ? "sport" : nil)
        usage.record(c, p, kind: kind, meta: m, seconds: secs)
    }

    /// 21:15 tonight, or tomorrow once the evening is over (`after` minutes past it).
    static func tonightAt(graceMinutes: Int = 0) -> Millis {
        let cal = Calendar.current
        var t = cal.date(bySettingHour: 21, minute: 15, second: 0, of: Date()) ?? Date()
        if Date().timeIntervalSince(t) > Double(graceMinutes) * 60 { t = cal.date(byAdding: .day, value: 1, to: t) ?? t }
        return t.ms
    }

    /// Dress the programmes people will actually see — on air now, the next hours and tonight's prime time — with TMDB
    /// data, a few at a time, so the Home shows artwork without waiting. Idempotent; cached per title.
    func prefetchMeta(limit: Int = 160) {
        Task {
            if !Vpn.shared.active.value { return }
            if !(await metaLock.tryLock()) { return }
            let now = Clock.now
            let chans = channels.all().filter { $0.epgId != nil }
            var byEpg = [String: ChannelEntity]()
            for c in chans { if byEpg[c.epgId!] == nil { byEpg[c.epgId!] = c } }
            let tonight = NexCore.tonightAt()
            let progs = db.allProgrammesBetween(now - 30 * Clock.minute, now + 6 * Clock.hour) + db.allProgrammesBetween(tonight - 30 * Clock.minute, tonight + 2 * Clock.hour)
            func weight(_ c: ChannelEntity) -> Int { switch c.categoryId { case "general": return 0; case "cinema": return 1; case "entertainment": return 2; default: return 3 } }
            var pairs = [(ProgrammeEntity, ChannelEntity)]()
            for p in progs { if let c = byEpg[p.epgId], meta.wantsMeta(p, c) { pairs.append((p, c)) } }
            pairs.sort { a, b in
                let ka = ((a.0.start <= now && a.0.stop > now) ? 0 : 1, weight(a.1), a.0.start), kb = ((b.0.start <= now && b.0.stop > now) ? 0 : 1, weight(b.1), b.0.start)
                return ka < kb
            }
            let todo = Array(pairs.distinct { self.meta.keyOf($0.0) }.prefix(limit))
            _ = await mapConcurrent(todo, limit: 3) { pc in await self.meta.enrich(pc.0, pc.1) != nil }
            db.purgeMetaMisses(before: now - 7 * Clock.day)
            NxLog.i("NxMeta", "prefetch done for \(todo.count) titles")
            await metaLock.unlock()
        }
    }

    /// Resume point used by "Riproduci": last unfinished position or the first episode. Uses cached progress only.
    func resumeFor(_ pid: Int64, _ d: TmdbDetails) -> PlayRequest {
        let last = library.progressFor(pid, d.id, d.media).first
        if !d.isTv { return PlayRequest(details: d, startMs: (last != nil && !last!.completed) ? last!.positionMs : 0) }
        guard let l = last else { return PlayRequest(details: d, season: 1, episode: 1) }
        if !l.completed { return PlayRequest(details: d, season: l.season, episode: l.episode, startMs: l.positionMs) }
        let n = d.episodeAfter(l.season, l.episode); return PlayRequest(details: d, season: n.0, episode: n.1)
    }

    /// nexstream://open/live/<streamId>?profile=<id> · open/vod/<media>/<tmdbId> · open/programme/<streamId>/<id> ·
    /// open/follow/<team> · open/downloads
    func handle(url: URL) {
        guard url.scheme == "nexstream", url.host == "open" else { return }
        let seg = url.pathComponents.filter { $0 != "/" }
        let pid = Int64(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value ?? "") ?? 0
        if seg.count == 1 && seg[0] == "downloads" { openDownloads.value = true }
        else if seg.count == 2 && seg[0] == "live" { pendingOpen.value = (seg[1], pid) }
        else if seg.count == 3 && seg[0] == "vod", let id = Int(seg[2]) { pendingOpenVod.value = (seg[1], id, pid) }
        else if seg.count == 3 && seg[0] == "resume", let id = Int(seg[2]) { pendingResume.value = (seg[1], id, pid) }
        else if seg.count == 3 && seg[0] == "programme", let id = Int64(seg[2]) { pendingOpenProgramme.value = (seg[1], id, pid) }
        else if seg.count == 2 && seg[0] == "follow" {
            let target = pid > 0 ? pid : (profiles.id > 0 ? profiles.id : profiles.lastId)
            Task {
                let ok = target > 0 ? await teams.followByName(seg[1], pid: target) : false
                NxLog.i("NxTeams", "follow \(seg[1]) on profile \(target): \(ok)")
            }
        }
    }
}

/// tvOS may empty `Caches` (where the database lives there) while the app is closed. Profiles and what belongs to them —
/// favourite channels, "Da guardare", followed teams, positions — are small: a JSON copy is kept in UserDefaults and put
/// back when the database comes up empty. On iPhone the database is durable and this is only a second copy.
enum Backup {
    static let tables: Set<String> = ["profiles", "favorites", "list_item", "progress", "meta"]
    private static let key = "nx.backup.v1"
    private static let lock = NSLock()
    private static var pending = false

    static func schedule(_ core: NexCore) {
        lock.lock()
        if pending { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            lock.lock(); pending = false; lock.unlock()
            save(core)
        }
    }

    static func export(_ core: NexCore, progress: Bool) -> [String: Any] {
        var out = [[String: Any]]()
        for p in core.db.profiles() {
            var o: [String: Any] = ["name": p.name, "color": p.avatarColor, "icon": p.avatarIcon, "kids": p.kids, "maturity": p.maturity, "created": p.createdAt]
            if let pin = p.pin { o["pin"] = pin }
            o["favorites"] = core.db.favoriteIds(p.id)
            o["list"] = core.db.list(p.id).map { ["id": $0.tmdbId, "media": $0.media, "at": $0.addedAt] as [String: Any] }
            o["teams"] = core.teams.load(p.id).map { ["n": $0.name, "c": $0.crest] }
            if progress {
                o["progress"] = core.db.allProgress(p.id).prefix(300).map { ["id": $0.tmdbId, "m": $0.media, "s": $0.season, "e": $0.episode, "p": $0.positionMs, "d": $0.durationMs, "c": $0.completed, "u": $0.updatedAt] as [String: Any] }
            }
            out.append(o)
        }
        return ["app": "nexstream", "v": 1, "profiles": out]
    }

    static func save(_ core: NexCore) {
        let json = jsonString(export(core, progress: true))
        // UserDefaults on tvOS is limited to 500 KB: this stays far below (a few KB per profile)
        if json.utf8.count < 400_000 { UserDefaults.standard.set(json, forKey: key) }
    }

    static func restoreIfNeeded(_ core: NexCore) {
        guard core.db.profiles().isEmpty, let json = UserDefaults.standard.string(forKey: key) else { return }
        let root = J.parse(json)
        var n = 0
        for o in root["profiles"].array {
            guard let name = o["name"].stringOrNil, !name.isBlank else { continue }
            let kids = o["kids"].bool
            let id = core.db.insertProfile(ProfileEntity(name: name, avatarColor: o["color"].int, kids: kids, createdAt: o["created"].int64OrNil ?? Clock.now,
                                                         pin: o["pin"].stringOrNil, avatarIcon: o["icon"].int, maturity: o["maturity"].intOrNil ?? (kids ? 0 : 2)))
            if id <= 0 { continue }
            n += 1
            for f in o["favorites"].array { if let s = f.stringOrNil { core.db.addFavorite(id, s) } }
            for i in o["list"].array { if let tid = i["id"].intOrNil, let m = i["media"].stringOrNil { core.db.addToList(ListItemEntity(profileId: id, tmdbId: tid, media: m, addedAt: i["at"].int64OrNil ?? Clock.now)) } }
            let teams = o["teams"].array.compactMap { t -> [String: String]? in
                guard let tn = t["n"].stringOrNil, let tc = t["c"].stringOrNil else { return nil }
                return ["n": tn, "c": tc]
            }
            if !teams.isEmpty { core.db.setMeta("teams.\(id)", jsonString(teams)) }
            for g in o["progress"].array {
                guard let tid = g["id"].intOrNil, let m = g["m"].stringOrNil else { continue }
                core.db.upsertProgress(ProgressEntity(profileId: id, tmdbId: tid, media: m, season: g["s"].int, episode: g["e"].int, positionMs: g["p"].int64OrNil ?? 0,
                                                      durationMs: g["d"].int64OrNil ?? 0, completed: g["c"].bool, updatedAt: g["u"].int64OrNil ?? Clock.now))
            }
        }
        if n > 0 { NxLog.i("NxBackup", "restored \(n) profiles after a cache purge") }
    }
}
