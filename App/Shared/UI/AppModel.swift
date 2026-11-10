import SwiftUI
import Combine

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case search, home, live, guide, movies, series, mine, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .search: return "Cerca"
        case .home: return "Home"
        case .live: return "Canali"
        case .guide: return "Guida TV"
        case .movies: return "Film"
        case .series: return "Serie TV"
        case .mine: return "I miei"
        case .settings: return "Impostazioni"
        }
    }
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house.fill"
        case .live: return "tv.fill"
        case .guide: return "calendar"
        case .movies: return "film.fill"
        case .series: return "play.rectangle.on.rectangle.fill"
        case .mine: return "bookmark.fill"
        case .settings: return "gearshape.fill"
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
}

/// What is playing full screen.
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
    let core = NexCore.shared
    let store: LiveStore

    @Published var vpn = false
    @Published var session: LineSession? = nil
    @Published var profile: ProfileEntity? = nil
    @Published var syncStatus: String? = nil
    @Published var reminder: ReminderEntity? = nil
    @Published var section: AppSection = .home
    @Published var paths: [AppSection: [Route]] = [:]
    @Published var playing: Playing? = nil
    /// Taste picker to show right after a profile is created.
    @Published var onboardingFor: Int64? = nil
    /// "Gestisci i profili" opened from the profile picker.
    @Published var manageProfilesGate = false
    /// The downloads page opened from the VPN gate (what is downloaded plays without VPN and without network).
    @Published var offlineDownloads = false
    @Published var toast: String? = nil
    @Published var pendingSearch: String? = nil
    /// Bumped when the tab already on screen is tapped again (back to the top).
    @Published var reselect = 0

    private var watches = [Watch]()
    private var autoTried = false

    init() {
        store = LiveStore(core: NexCore.shared)
        MetaRepository.logoLuminance = { ImageLoader.luminance($0) }
        _ = PlatformServices.shared
        core.start()
        watches.append(onMain(Vpn.shared.active) { [weak self] v in self?.vpn = v })
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
        if Demo.args.contains("-nxPlayFirst") {
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let c = core.channels.visible().first { play(c) }
            }
        }
        if Demo.args.contains("-nxPlayVod") {
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let d = try? await core.catalog.details("movie", 603) { play(PlayRequest(details: d)) }
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
        playing = .live(c.streamId, all.contains(c.streamId) ? all : [c.streamId] + all)
    }
    func play(_ r: PlayRequest) { playing = .vod(r) }
    /// "Riproduci" on a title: from where it was left, or the first episode.
    func playTitle(_ d: TmdbDetails) { playing = .vod(core.resumeFor(pid, d)) }
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
        let wanted = core.pendingOpen.value?.1 ?? core.pendingOpenVod.value?.2 ?? 0
        if wanted > 0, let p = core.profiles.all().first(where: { $0.id == wanted && $0.pin == nil }) { core.profiles.select(p) }
        else { core.profiles.autoSelect() }
    }
    func changeProfile() { autoTried = true; core.profiles.deselect() }

    /// A notification or a link was opened: go there once the gates are passed.
    private func consumePending() {
        guard profile != nil else { return }
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
    }

    func toggleFavorite(_ c: ChannelEntity) { let on = core.channels.toggleFavorite(c.streamId); say(on ? "\(c.name) aggiunto ai preferiti" : "\(c.name) tolto dai preferiti") }
    func toggleReminder(_ s: Showing) { let on = core.toggleReminder(s); say(on ? "Ti avviso quando inizia" : "Promemoria tolto") }
    func toggleList(_ t: TmdbTitle) {
        let now = core.library.isInList(pid, t.tmdbId, t.media)
        core.library.toggleList(pid, t.tmdbId, t.media, currently: now)
        say(now ? "Tolto da Da guardare" : "Aggiunto a Da guardare")
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
