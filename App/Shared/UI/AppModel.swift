import SwiftUI
import Combine

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case search, home, live, guide, movies, series, mine, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .search: return "Cerca"
        case .home: return "Home"
        case .live: return "Diretta"
        case .guide: return "Guida TV"
        case .movies: return "Film"
        case .series: return "Serie TV"
        case .mine: return Metrics.tv ? "La mia lista" : "Il mio spazio"
        case .settings: return "Impostazioni"
        }
    }
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house.fill"
        case .live: return "play.tv.fill"
        case .guide: return "calendar"
        case .movies: return "film.fill"
        case .series: return "tv.fill"
        case .mine: return "plus"
        case .settings: return "gearshape.fill"
        }
    }
    /// The symbol of a section that is not the one in view (phone bar).
    var iconOff: String {
        switch self {
        case .home: return "house"
        case .live: return "play.tv"
        case .movies: return "film"
        case .series: return "tv"
        default: return icon
        }
    }
}

/// Pages pushed on top of a section.
enum Route: Hashable {
    /// Programme / event page; programmeId = 0 for event channels without a guide.
    case programme(String, Int64)
    /// On-demand title page (TMDB movie / tv).
    case title(String, Int)
    case genre(String, Int, String)
    case teams
    case manageProfiles
    case transfer
    case remote
    case downloads
    case settings
    case mine
    case search
    /// The Film ("movie") or Serie TV ("tv") catalogue.
    case vod(String)
}

/// What is playing.
enum Playing: Identifiable, Hashable {
    /// Live channel; the list is what up/down zap through, in order.
    case live(String, [String])
    case vod(PlayRequest)
    var id: String {
        switch self {
        case .live: return "live"
        case .vod(let r): return "vod-\(r.id)"
        }
    }
    /// A downloaded file: it plays without VPN and without network.
    var isOffline: Bool { if case .vod(let r) = self { return r.localFile != nil }; return false }
}

/// Runs `body` on the main thread for every value of an `Observable`.
func onMain<T>(_ o: Observable<T>, _ body: @escaping (T) -> Void) -> Watch {
    o.observe { v in
        if Thread.isMainThread { body(v) } else { DispatchQueue.main.async { body(v) } }
    }
}

/// App-wide UI state: the gates (VPN → line → profile), where the viewer is, what is playing.
@MainActor
final class AppModel: ObservableObject {
    /// One model for the phone / TV screen and for the car screen.
    static let shared = AppModel()
    let core = NexCore.shared
    let store: LiveStore

    @Published var vpn = false
    @Published var session: LineSession? = nil
    @Published var profile: ProfileEntity? = nil
    @Published var syncStatus: String? = nil
    @Published var reminder: ReminderEntity? = nil
    @Published var section: AppSection = .home
    @Published var paths: [AppSection: [Route]] = [:]
    @Published private(set) var playing: Playing? = nil
    /// The player behind `playing`: one of the two is set while something plays.
    @Published private(set) var live: LivePlayerModel? = nil
    @Published private(set) var vod: VodPlayerModel? = nil
    /// iPhone: the player fills the screen in landscape (false = the portrait page with the video on top).
    @Published var playerFull = false
    /// Taste picker to show right after a profile is created.
    @Published var onboardingFor: Int64? = nil

    /// The downloads page opened from the VPN gate (what is downloaded plays without VPN and without network).
    @Published var offlineDownloads = false
    /// The phone remote opened from the VPN gate (it only talks to the home network).
    @Published var gateRemote = false
    @Published var toast: String? = nil
    /// Phone: which half of "Diretta" is in view (0 = channels, 1 = guide). Remembered.
    @Published var liveTab: Int = UserDefaults.standard.integer(forKey: "nx.liveTab") { didSet { UserDefaults.standard.set(liveTab, forKey: "nx.liveTab") } }
    /// Our own panels (menus, pickers, dialogs, editors), the last one on top.
    @Published var sheets: [NxSheetItem] = []
    @Published var pendingSearch: String? = nil
    /// Bumped when the tab already on screen is tapped again (back to the top).
    @Published var reselect = 0

    private var watches = [Watch]()
    private var autoTried = false

    private init() {
        store = LiveStore(core: NexCore.shared)
        MetaRepository.logoLuminance = { ImageLoader.luminance($0) }
        _ = PlatformServices.shared
        core.sync.deviceName = { Lan.deviceName().substringAfter("· ") }
        core.sync.onProfilesChanged = { [weak self] in DispatchQueue.main.async { self?.store.reloadAll() } }
        core.start()
        watches.append(onMain(Vpn.shared.active) { [weak self] v in
            guard let self = self else { return }
            self.vpn = v
            // nothing streams without the VPN: only a downloaded file may go on
            if !v, let p = self.playing, !p.isOffline { self.closePlayer() }
            // the pages opened from the gate belong to it (Android: state kept inside `if (!vpn)`)
            if v { self.offlineDownloads = false; self.gateRemote = false; self.consumePending() }
        })
        watches.append(onMain(core.session.current) { [weak self] s in self?.session = s })
        watches.append(onMain(core.profiles.current) { [weak self] p in
            guard let self = self else { return }
            let changed = self.profile?.id != p?.id
            self.profile = p
            if changed { self.paths = [:]; self.section = .home; self.store.reloadAll() }
            if p != nil { self.consumePending() }
        })
        watches.append(onMain(core.syncStatus) { [weak self] s in self?.syncStatus = s })
        watches.append(onMain(core.reminderAlert) { [weak self] r in self?.reminder = r })
        watches.append(onMain(core.pendingOpen) { [weak self] _ in self?.consumePending() })
        watches.append(onMain(core.pendingOpenVod) { [weak self] _ in self?.consumePending() })
        watches.append(onMain(core.pendingOpenProgramme) { [weak self] _ in self?.consumePending() })
        watches.append(onMain(core.pendingResume) { [weak self] _ in self?.consumePending() })
        // nexstream://open/downloads: the page of the downloads, also from the VPN gate
        watches.append(onMain(core.openDownloads) { [weak self] on in
            guard let self = self, on else { return }
            self.core.openDownloads.value = false
            #if os(iOS)
            if !self.vpn { self.offlineDownloads = true }
            else if self.profile != nil, self.paths[self.section]?.last != .downloads { self.open(.downloads) }
            #endif
        })
        watches.append(onMain(core.pendingSearch) { [weak self] q in
            guard let self = self, let q = q else { return }
            self.pendingSearch = q; self.section = .search; self.core.pendingSearch.value = nil
        })
        debugLaunch()
    }

    /// Launch arguments of the build pipeline: open a section, a link or the first channel straight away.
    private func debugLaunch() {
        if let s = Demo.value("-nxSection"), let sec = AppSection(rawValue: s) { section = sec }
        if let u = Demo.value("-nxOpen"), let url = URL(string: u) { core.handle(url: url) }
        if let r = Demo.value("-nxRoute") {
            switch r {
            case "teams": paths[section] = [.teams]
            case "settings": paths[section] = [.settings]
            case "transfer": paths[section] = [.transfer]
            case "remote": paths[section] = [.remote]
            case "downloads": paths[section] = [.downloads]
            default: break
            }
        }
        // the pages the VPN gate opens (screenshots of the gate with -nxVpnOff)
        if Demo.args.contains("-nxGateRemote") { gateRemote = true }
        if Demo.args.contains("-nxGateDownloads") { offlineDownloads = true }
        if Demo.args.contains("-nxPlayFirst") {
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let c = core.channels.visible().first { play(c) }
            }
        }
        if let secs = Demo.value("-nxCloseAfter").flatMap(Double.init) {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                NxLog.i("NxDebug", "closing the player as the close button does")
                closePlayer()
                NxLog.i("NxDebug", "player closed")
            }
        }
        if Demo.enabled { NxPlayer.forceVlc = Demo.args.contains("-nxForceVlc") }
        if Demo.args.contains("-nxFull") {
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                PlatformServices.shared.rotate(landscape: true)
            }
        }
        if Demo.args.contains("-nxPlayVod") {
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                // "-nxPlayVod tv:1396:4:5" plays that episode; without a value, The Matrix
                let spec = (Demo.value("-nxPlayVod") ?? "").split(separator: ":").map(String.init)
                if spec.count == 4, let id = Int(spec[1]), let se = Int(spec[2]), let ep = Int(spec[3]), let d = try? await core.catalog.details(spec[0], id) {
                    play(PlayRequest(details: d, season: se, episode: ep))
                } else if let d = try? await core.catalog.details("movie", 603) { play(PlayRequest(details: d)) }
            }
        }
    }

    var pid: Int64 { profile?.id ?? 0 }
    var kids: Bool { profile?.kids ?? false }

    func path(_ s: AppSection) -> Binding<[Route]> {
        Binding(get: { self.paths[s] ?? [] }, set: { self.paths[s] = $0 })
    }
    /// Pushes a page on the section in view.
    func open(_ r: Route) { paths[section, default: []].append(r) }
    func openShowing(_ s: Showing) { open(.programme(s.channel.streamId, s.programme?.id ?? 0)) }
    func openTitle(_ t: TmdbTitle) { open(.title(t.media, t.tmdbId)) }
    func pop() { if !(paths[section] ?? []).isEmpty { paths[section]?.removeLast() } }

    /// Opens a live channel; zapping goes through `ids` (or every visible channel in number order).
    func play(_ c: ChannelEntity, ids: [String]? = nil) {
        let all = ids ?? store.zapOrder()
        let list = all.contains(c.streamId) ? all : [c.streamId] + all
        if let v = vod { v.close(); vod = nil }
        if let l = live { l.switchTo(c.streamId, listIds: list) }
        else {
            PlatformServices.shared.playerOpened()
            let m = LivePlayerModel(channelId: c.streamId, listIds: list)
            m.player.onRestoreUI = { [weak self] in self?.playerHidden = false }
            live = m
            m.start()
        }
        playerHidden = false
        playing = .live(c.streamId, list)
    }
    func play(_ r: PlayRequest) {
        if let l = live { l.stop(); live = nil }
        if let v = vod { v.close(); vod = nil }
        PlatformServices.shared.playerOpened()
        // from the VPN gate (downloads) there may be no profile chosen yet: positions go to the last one
        let m = VodPlayerModel(request: r, pid: pid > 0 ? pid : core.profiles.lastId)
        m.onNext = { [weak self] n in self?.play(n) }
        m.player.onRestoreUI = { [weak self] in self?.playerHidden = false }
        vod = m
        m.start()
        playerHidden = false
        playing = .vod(r)
    }
    /// Stops whatever is playing and leaves the player.
    func closePlayer() {
        live?.stop(); live = nil
        vod?.close(); vod = nil
        if playing != nil {
            playing = nil
            playerFull = false
            NowPlaying.shared.clear()
            PlatformServices.shared.playerClosed()
            core.sync.kick(after: 0.5)
        }
    }
    /// "Riproduci su…": the TV the remote page opens on once the title is playing there.
    var remoteTarget: (address: String, name: String)? = nil

    /// Describes what is playing here, for another NexStream to carry on with (remote protocol, `/play`).
    func castBody() -> [String: Any]? {
        if let l = live { return ["kind": "live", "id": l.currentId] }
        if let v = vod, !v.isOffline {
            return ["kind": "vod", "media": v.details.media, "tmdb": v.details.id, "season": v.request.season, "episode": v.request.episode,
                    "pos": v.position, "profile": core.sync.profileUuid(pid)]
        }
        return nil
    }

    /// The TV accepted what was playing here ("Riproduci su…"): the player closes and this phone becomes its remote.
    func castSent(to address: String, name: String) {
        remoteTarget = (address, name)
        closePlayer()
        dismissAllSheets()
        section = .mine
        paths[.mine] = [.remote]
    }

    /// Started from the car screen: the phone keeps showing what it was showing.
    @Published var playerHidden = false
    /// Back to the first page of Home (the phone remote's Home key).
    func goHome() { closePlayer(); paths = [:]; section = .home }
    /// "Riproduci" on a title: from where it was left, or the first episode.
    func playTitle(_ d: TmdbDetails) { play(core.resumeFor(pid, d)) }
    func playTitle(_ t: TmdbTitle) {
        Task {
            if let d = try? await core.catalog.details(t.media, t.tmdbId) { playTitle(d) }
            else { say("Non riesco a caricare questo titolo: controlla la connessione.") }
        }
    }

    func say(_ message: String) {
        toast = message
        Task { try? await Task.sleep(nanoseconds: 3_200_000_000); if toast == message { toast = nil } }
    }

    /// One open profile → straight in; a link naming an open profile → that one.
    func autoSelectProfile() {
        if autoTried || core.profiles.pickRequested { return }
        autoTried = true
        let wanted = core.pendingOpen.value?.1 ?? core.pendingOpenVod.value?.2 ?? core.pendingResume.value?.2 ?? 0
        if wanted > 0, let p = core.profiles.all().first(where: { $0.id == wanted && $0.pin == nil }) { core.profiles.select(p) }
        else { core.profiles.autoSelect() }
    }
    func changeProfile() { autoTried = true; core.profiles.deselect() }

    /// A notification or a link was opened: go there once the gates are passed.
    private func consumePending() {
        // a channel asked for while the VPN was off (phone remote, Top Shelf) opens once it is on
        guard profile != nil, vpn else { return }
        if let (sid, _) = core.pendingOpen.value {
            core.pendingOpen.value = nil
            if let c = core.channels.get(sid), core.channels.isVisible(c) { play(c) }
        }
        if let (sid, progId, _) = core.pendingOpenProgramme.value {
            core.pendingOpenProgramme.value = nil
            if let c = core.channels.get(sid), core.channels.isVisible(c) { open(.programme(sid, progId)) }
        }
        if let (media, id, _) = core.pendingOpenVod.value {
            core.pendingOpenVod.value = nil
            open(.title(media, id))
        }
        if let (media, id, _) = core.pendingResume.value {
            // Top Shelf "play": from where it was left (the title page when the details cannot be loaded)
            core.pendingResume.value = nil
            Task {
                if let d = try? await core.catalog.details(media, id) { playTitle(d) } else { open(.title(media, id)) }
            }
        }
    }

    func toggleFavorite(_ c: ChannelEntity) { let on = core.channels.toggleFavorite(c.streamId); say(on ? "\(c.name) aggiunto ai preferiti" : "\(c.name) tolto dai preferiti") }
    func toggleReminder(_ s: Showing) { let on = core.toggleReminder(s); say(on ? "Ti avviso quando inizia" : "Promemoria tolto") }
    func toggleList(_ t: TmdbTitle) {
        let now = core.library.isInList(pid, t.tmdbId, t.media)
        core.library.toggleList(pid, t.tmdbId, t.media, currently: now)
        say(now ? "Tolto dalla tua lista" : "Aggiunto alla tua lista")
    }
}

/// The live snapshot most pages read: the profile's channels, what is on air now, TMDB dressing, favourites, reminders,
/// saved titles. Reloaded when the database changes (debounced) and every minute, off the main thread.
@MainActor
final class LiveStore: ObservableObject {
    private let core: NexCore
    @Published private(set) var channels: [ChannelEntity] = []
    @Published private(set) var nowByEpg: [String: ProgrammeEntity] = [:]
    @Published private(set) var metas: [String: ProgrammeMetaEntity] = [:]
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var reminders: Set<String> = []
    @Published private(set) var listKeys: Set<String> = []
    /// Bumped at every reload: pages that build their own rows watch this.
    @Published private(set) var version = 0
    @Published private(set) var loaded = false

    private var watches = [Watch]()
    private var dirty = Set<String>()
    private var scheduled = false
    private var timer: Timer?

    init(core: NexCore) {
        self.core = core
        watches.append(core.db.changes.observe { [weak self] table in
            DispatchQueue.main.async { self?.mark(table) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.mark("tick") }
        }
        reloadAll()
    }

    func reloadAll() { mark("all") }

    private func mark(_ table: String) {
        dirty.insert(table)
        if scheduled { return }
        scheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            let what = self.dirty
            self.dirty = []
            self.scheduled = false
            await self.reload(what)
        }
    }

    private struct Snapshot {
        var channels: [ChannelEntity]?; var now: [String: ProgrammeEntity]?; var metas: [String: ProgrammeMetaEntity]?
        var favorites: Set<String>?; var reminders: Set<String>?; var listKeys: Set<String>?
    }

    private func reload(_ what: Set<String>) async {
        let core = self.core
        let pid = core.profiles.id
        let all = what.contains("all")
        let snap: Snapshot = await Task.detached(priority: .userInitiated) {
            var s = Snapshot()
            if all || what.contains("channels") || what.contains("tick") || what.contains("programmes") { s.channels = core.channels.visible() }
            if all || what.contains("programmes") || what.contains("tick") || what.contains("channels") {
                var m = [String: ProgrammeEntity]()
                for p in core.db.programmesAt(Clock.now) { m[p.epgId] = p }
                s.now = m
            }
            if all || what.contains("programme_meta") { s.metas = core.meta.allFound() }
            if all || what.contains("favorites") { s.favorites = Set(core.db.favoriteIds(pid)) }
            if all || what.contains("reminders") { s.reminders = Set(core.db.reminderIds(pid)) }
            if all || what.contains("list_item") { s.listKeys = Set(core.db.list(pid).map { "\($0.tmdbId)-\($0.media)" }) }
            return s
        }.value
        if let v = snap.channels, v != channels { channels = v }
        if let v = snap.now, v != nowByEpg { nowByEpg = v }
        if let v = snap.metas, v != metas { metas = v }
        if let v = snap.favorites, v != favorites { favorites = v }
        if let v = snap.reminders, v != reminders { reminders = v }
        if let v = snap.listKeys, v != listKeys { listKeys = v }
        loaded = true
        version += 1
    }

    func now(_ c: ChannelEntity) -> ProgrammeEntity? { c.epgId.flatMap { nowByEpg[$0] } }
    func meta(_ p: ProgrammeEntity?) -> ProgrammeMetaEntity? { p.flatMap { metas[core.meta.keyOf($0)] } }
    func showing(_ c: ChannelEntity, _ p: ProgrammeEntity?) -> Showing { Showing(channel: c, programme: p, meta: meta(p)) }
    /// What a channel is showing right now.
    func showing(_ c: ChannelEntity) -> Showing { showing(c, now(c)) }
    /// Every channel the profile may see, in number order: what up/down zap through.
    func zapOrder() -> [String] { channels.filter { $0.shiftMin == 0 }.sorted { ($0.num > 0 ? $0.num : Int.max) < ($1.num > 0 ? $1.num : Int.max) }.map { $0.streamId } }
    func byCategory(_ id: String) -> [ChannelEntity] { channels.filter { $0.categoryId == id } }
    var categories: [ChannelCatalog.Genre] {
        let used = Set(channels.map { $0.categoryId })
        return ChannelCatalog.genres.filter { used.contains($0.id) }
    }
}
