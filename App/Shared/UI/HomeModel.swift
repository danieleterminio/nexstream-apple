import SwiftUI

/// Builds the Home: everything on air ranked into a carousel and rows, mixed with the on-demand rows — the same recipe as
/// the Android app (`HomeViewModel`).
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var state = HomeState()
    private let core = NexCore.shared
    private let pid: Int64
    private let kids: Bool
    private var vod = VodData()
    private var building = false
    private var again = false
    private var started = false
    private var watches = [Watch]()

    init(pid: Int64, kids: Bool) { self.pid = pid; self.kids = kids }

    func start(store: LiveStore) {
        if started { return }
        started = true
        core.prefetchMeta()
        Task { await core.meta.refreshTrending() }
        Task { await loadVod(store) }
        watches.append(core.db.changes.observe { [weak self] t in
            if t == "progress" { DispatchQueue.main.async { Task { await self?.refreshContinue(store) } } }
        })
        watches.append(onMain(core.teams.changed) { [weak self] _ in self?.rebuild(store) })
    }

    static func buildContinue(_ core: NexCore, _ pid: Int64) async -> HomeRow? {
        var titles = [TmdbTitle](); var overlays = [String: CardOverlay]()
        for p in core.library.continueWatching(pid).prefix(20) {
            if p.media == "movie" && p.completed { continue }
            guard let e = await core.catalog.ensureTitle(p.tmdbId, p.media) else { continue }
            let t = CatalogRepository.asTmdb(e)
            titles.append(t)
            overlays[t.key] = CardOverlay(progress: p.completed ? 1 : Double(p.positionMs) / Double(max(1, p.durationMs)), label: p.media == "tv" ? "S\(p.season) E\(p.episode)" : nil)
            if titles.count >= 12 { break }
        }
        if titles.isEmpty { return nil }
        return .vod(id: "vod-continue", title: "Continua a guardare", row: VodRow(id: "continue", title: "Continua a guardare", items: titles, kind: .continue), overlays: overlays, sub: nil, tag: nil)
    }

    private func refreshContinue(_ store: LiveStore) async {
        vod.continueRow = await HomeModel.buildContinue(core, pid)
        rebuild(store)
    }

    private func loadVod(_ store: LiveStore) async {
        let core = self.core, kids = self.kids, pid = self.pid
        vod.continueRow = await HomeModel.buildContinue(core, pid)
        var heroes = [HeroItem]()
        for t in await core.catalog.heroCandidates(kids).prefix(4) { heroes.append(.vod(t, try? await core.catalog.details(t.media, t.tmdbId))) }
        vod.heroes = heroes
        rebuild(store)
        let pub = await core.catalog.publicRows(kids)
        func pick(_ id: String, _ title: String) -> HomeRow? {
            guard let r = pub.first(where: { $0.id == id }), r.items.count >= 4 else { return nil }
            var ov = [String: CardOverlay]()
            for t in r.items { if let b = CatalogRepository.badgeFor(t) { ov[t.key] = CardOverlay(badge: b) } }
            return .vod(id: "vod-\(id)", title: title, row: r, overlays: ov, sub: nil, tag: "On demand")
        }
        vod.top10Movie = pick("top10movie", "Top 10 film"); vod.top10Tv = pick("top10tv", "Top 10 serie TV"); vod.fresh = pick("new", "Nuove uscite")
        rebuild(store)
        let mg = await core.catalog.genres("movie"), tg = await core.catalog.genres("tv")
        let personal = await core.recommender.rows(pid, kids: kids, genreNames: mg.merging(tg) { a, _ in a })
        if let r = personal.first(where: { $0.id == "foryou" }) {
            vod.forYou = .vod(id: "vod-foryou", title: "Scelti per te", row: r, overlays: [:], sub: "in base a cosa guardi", tag: "On demand")
            rebuild(store)
        }
    }

    /// Rebuilds the rows from the live snapshot (called whenever the store reloads).
    func rebuild(_ store: LiveStore) {
        if building { again = true; return }
        building = true
        let core = self.core, vod = self.vod
        let all = store.channels, nowMap = store.nowByEpg, metas = store.metas
        let syncing = core.syncStatus.value != nil
        Task {
            let st = await Task.detached(priority: .userInitiated) { HomeBuilder(core: core, all: all, now: nowMap, metas: metas, vod: vod, syncing: syncing).build() }.value
            self.state = st
            self.building = false
            if self.again { self.again = false; self.rebuild(store) }
        }
    }
}

