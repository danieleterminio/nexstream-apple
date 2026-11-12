import UIKit
import CarPlay
import Intents
import Combine

/// What the signing profile allows. CarPlay and Siri only work when the app is signed with a profile that carries the
/// matching permission; asking Siri for authorisation without it would crash, so it is checked first.
enum Entitlements {
    private static let profile: String = {
        guard let u = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let d = try? Data(contentsOf: u) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }()
    static var siri: Bool { profile.contains("com.apple.developer.siri") }
    static var carPlay: Bool { profile.contains("com.apple.developer.carplay-audio") || profile.contains("com.apple.developer.playable-content") }
}

/// NexStream on the car screen. Apple does not let any app show video there, so this is the listening side of the app:
/// live channels, films and series are browsed in lists and played as sound, with the system's "In riproduzione" screen
/// and the steering-wheel keys. The phone keeps doing the work (line, VPN, profile).
final class CarSceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CPInterfaceController?
    private var bag = Set<AnyCancellable>()
    private var lastBuild = Date.distantPast
    private var gate = ""

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        Task { @MainActor in
            let app = AppModel.shared
            app.autoSelectProfile()
            self.rebuild()
            app.$vpn.map { _ in () }.merge(with: app.$session.map { _ in () }, app.$profile.map { _ in () })
                .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
                .sink { [weak self] in self?.rebuild() }.store(in: &self.bag)
            app.store.$version.throttle(for: .seconds(45), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in self?.rebuild(onlyIfRoot: true) }.store(in: &self.bag)
        }
        if Entitlements.siri { INPreferences.requestSiriAuthorization { _ in } }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller = nil
        bag.removeAll()
    }

    // MARK: root

    @MainActor private func gateMessage(_ app: AppModel) -> (String, String)? {
        if !app.vpn { return ("Accendi la VPN", "Apri l'app della VPN sul telefono, poi torna qui.") }
        if app.session == nil { return ("Accedi dal telefono", "Apri NexStream sul telefono e collega la tua linea.") }
        if app.profile == nil { return ("Scegli un profilo", "Apri NexStream sul telefono e scegli chi guarda.") }
        return nil
    }

    @MainActor private func rebuild(onlyIfRoot: Bool = false) {
        guard let c = controller else { return }
        let app = AppModel.shared
        if onlyIfRoot && (c.templates.count > 1 || Date().timeIntervalSince(lastBuild) < 30) { return }
        lastBuild = Date()
        if let m = gateMessage(app) {
            gate = m.0
            let item = CPListItem(text: m.0, detailText: m.1, image: UIImage(systemName: "iphone"))
            let t = CPListTemplate(title: "NexStream", sections: [CPListSection(items: [item])])
            c.setRootTemplate(t, animated: false, completion: nil)
            return
        }
        gate = ""
        let live = liveTemplate(app)
        let movies = CPListTemplate(title: "Film", sections: [])
        movies.tabImage = UIImage(systemName: "film")
        movies.emptyViewTitleVariants = ["Carico i film…"]
        let series = CPListTemplate(title: "Serie TV", sections: [])
        series.tabImage = UIImage(systemName: "tv")
        series.emptyViewTitleVariants = ["Carico le serie TV…"]
        let tabs = CPTabBarTemplate(templates: [live, movies, series])
        c.setRootTemplate(tabs, animated: false, completion: nil)
        Task { @MainActor in
            await self.fill(movies, media: "movie", app)
            await self.fill(series, media: "tv", app)
        }
    }

    private var limit: Int { max(8, CPListTemplate.maximumItemCount) }

    // MARK: live

    @MainActor private func channelItem(_ c: ChannelEntity, _ app: AppModel, list: [ChannelEntity]) -> CPListItem {
        let s = app.store.showing(c)
        let now = (s.programme != nil || c.event != nil) ? s.cardTitle : nil
        let item = CPListItem(text: (c.num > 0 ? "\(c.num)  " : "") + c.name, detailText: now, image: UIImage(systemName: "tv"))
        item.isPlaying = app.live?.currentId == c.streamId
        if let u = c.logo ?? c.icon { loadImage(u, into: item) }
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                self?.start { app.play(c, ids: list.map { $0.streamId }) }
                done()
            }
        }
        return item
    }

    @MainActor private func liveTemplate(_ app: AppModel) -> CPListTemplate {
        let store = app.store
        var sections = [CPListSection]()
        let favs = store.channels.filter { store.favorites.contains($0.streamId) }
        if !favs.isEmpty {
            sections.append(CPListSection(items: favs.prefix(8).map { channelItem($0, app, list: favs) }, header: "Preferiti", sectionIndexTitle: nil))
        }
        var genres = [CPListItem]()
        let all = CPListItem(text: "Tutti i canali", detailText: "\(store.channels.count) canali", image: UIImage(systemName: "square.grid.2x2"))
        all.accessoryType = .disclosureIndicator
        all.handler = { [weak self] _, done in Task { @MainActor in self?.pushChannels("Tutti i canali", store.channels.filter { $0.shiftMin == 0 }, app); done() } }
        genres.append(all)
        for g in store.categories {
            let list = store.byCategory(g.id).filter { $0.shiftMin == 0 }
            if list.isEmpty { continue }
            let item = CPListItem(text: g.label, detailText: "\(list.count) canali", image: UIImage(systemName: "list.bullet"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in Task { @MainActor in self?.pushChannels(g.label, list, app); done() } }
            genres.append(item)
        }
        sections.append(CPListSection(items: Array(genres.prefix(limit)), header: "Canali", sectionIndexTitle: nil))
        let t = CPListTemplate(title: "Diretta", sections: sections)
        t.tabImage = UIImage(systemName: "play.tv")
        if Entitlements.siri { t.assistantCellConfiguration = CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .playMedia) }
        return t
    }

    @MainActor private func pushChannels(_ title: String, _ list: [ChannelEntity], _ app: AppModel) {
        let items = list.prefix(limit).map { channelItem($0, app, list: list) }
        controller?.pushTemplate(CPListTemplate(title: title, sections: [CPListSection(items: Array(items))]), animated: true, completion: nil)
    }

    // MARK: on demand

    @MainActor private func titleItem(_ t: TmdbTitle, sub: String?, _ app: AppModel) -> CPListItem {
        let item = CPListItem(text: t.displayTitle, detailText: sub ?? (t.year > 0 ? String(t.year) : nil), image: UIImage(systemName: t.isTv ? "tv" : "film"))
        if let u = Img.tmdb(t.posterPath, "w154") { loadImage(u, into: item) }
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                if let d = try? await app.core.catalog.details(t.media, t.tmdbId) { self?.start { app.playTitle(d) } }
                done()
            }
        }
        return item
    }

    @MainActor private func fill(_ template: CPListTemplate, media: String, _ app: AppModel) async {
        let core = app.core, pid = app.pid, kids = app.kids
        var sections = [CPListSection]()
        var cont = [CPListItem]()
        for p in core.library.continueWatching(pid) where p.media == media && !(p.media == "movie" && p.completed) {
            guard let e = await core.catalog.ensureTitle(p.tmdbId, p.media) else { continue }
            cont.append(titleItem(CatalogRepository.asTmdb(e), sub: p.media == "tv" ? "Stagione \(p.season), episodio \(p.episode)" : "Riprendi", app))
            if cont.count >= 6 { break }
        }
        if !cont.isEmpty { sections.append(CPListSection(items: cont, header: "Continua", sectionIndexTitle: nil)) }
        var mine = [CPListItem]()
        for it in core.library.list(pid) where it.media == media {
            guard let e = await core.catalog.ensureTitle(it.tmdbId, it.media) else { continue }
            mine.append(titleItem(CatalogRepository.asTmdb(e), sub: nil, app))
            if mine.count >= 8 { break }
        }
        if !mine.isEmpty { sections.append(CPListSection(items: mine, header: "La mia lista", sectionIndexTitle: nil)) }
        let rows = await core.catalog.publicRows(kids)
        let wanted = media == "movie" ? ["top10movie", "new", "week", "movies"] : ["top10tv", "new", "week", "series"]
        var seen = Set<String>()
        var popular = [CPListItem]()
        for id in wanted {
            guard let r = rows.first(where: { $0.id == id }) else { continue }
            for t in r.items where t.media == media && seen.insert(t.key).inserted {
                popular.append(titleItem(t, sub: nil, app))
                if popular.count >= 12 { break }
            }
            if popular.count >= 12 { break }
        }
        if !popular.isEmpty { sections.append(CPListSection(items: popular, header: "I più visti", sectionIndexTitle: nil)) }
        if sections.isEmpty { template.emptyViewTitleVariants = ["Niente da mostrare"] }
        template.updateSections(sections)
    }

    // MARK: playing

    /// Starts something from the car: the phone screen is left alone, the car shows "In riproduzione".
    @MainActor private func start(_ play: () -> Void) {
        let app = AppModel.shared
        let onPhone = UIApplication.shared.applicationState == .active
        play()
        if !onPhone { app.playerHidden = true }
        if let c = controller, !(c.topTemplate is CPNowPlayingTemplate) { c.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil) }
    }

    private func loadImage(_ url: String, into item: CPListItem) {
        Task { @MainActor in
            guard let img = await ImageLoader.shared.load(url, maxPixel: 240) else { return }
            item.setImage(img)
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- Siri

/// "Riproduci Rai 1 su NexStream": Siri (also from the car's voice key) hands the words to the app, which looks for a
/// channel first, then for a film or a series.
final class PlayMediaHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let q = (intent.mediaSearch?.mediaName ?? "").trimmed
        if q.isEmpty { return [INPlayMediaMediaItemResolutionResult.unsupported()] }
        let items = await PlayMediaHandler.find(q)
        if items.isEmpty { return [INPlayMediaMediaItemResolutionResult.unsupported()] }
        return INPlayMediaMediaItemResolutionResult.successes(with: Array(items.prefix(1)))
    }

    @MainActor static func find(_ q: String) async -> [INMediaItem] {
        let app = AppModel.shared
        guard app.vpn, app.session != nil, app.profile != nil else { return [] }
        let n = MetaText.norm(q)
        var out = [INMediaItem]()
        let chans = app.store.channels.filter { $0.shiftMin == 0 }
        let exact = chans.filter { MetaText.norm($0.name) == n }
        let partial = chans.filter { MetaText.norm($0.name).contains(n) }
        for c in (exact + partial).prefix(3) { out.append(INMediaItem(identifier: "live:" + c.streamId, title: c.name, type: .tvShow, artwork: nil)) }
        var titles = app.core.catalog.searchLocal(q, app.kids)
        if titles.isEmpty { titles = await app.core.catalog.search(q, app.kids) }
        for t in titles.prefix(3) { out.append(INMediaItem(identifier: "vod:\(t.media):\(t.tmdbId)", title: t.displayTitle, type: t.isTv ? .tvShow : .movie, artwork: nil)) }
        return out
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let id = intent.mediaItems?.first?.identifier else { return INPlayMediaIntentResponse(code: .failure, userActivity: nil) }
        let ok = await PlayMediaHandler.play(id)
        return INPlayMediaIntentResponse(code: ok ? .success : .failure, userActivity: nil)
    }

    @MainActor static func play(_ id: String) async -> Bool {
        let app = AppModel.shared
        guard app.vpn, app.session != nil, app.profile != nil else { return false }
        let hidden = UIApplication.shared.applicationState != .active
        if id.hasPrefix("live:"), let c = app.core.channels.get(String(id.dropFirst(5))) {
            app.play(c)
            if hidden { app.playerHidden = true }
            return true
        }
        let p = id.split(separator: ":").map(String.init)
        if p.count == 3, p[0] == "vod", let tmdb = Int(p[2]), let d = try? await app.core.catalog.details(p[1], tmdb) {
            app.playTitle(d)
            if hidden { app.playerHidden = true }
            return true
        }
        return false
    }
}
