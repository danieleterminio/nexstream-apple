import SwiftUI

/// The big slide on top of Home, Film, Serie TV and I miei: artwork edge to edge, what it is, and the one thing to do.
struct HeroView: View {
    let item: HeroItem
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    #if os(tvOS)
    static let height: CGFloat = 640
    #else
    static var height: CGFloat { Metrics.isPad ? 460 : 430 }
    #endif

    private var artwork: String? {
        switch item {
        case .live(let s): return Img.hero(s.image)
        case .vod(let t, let d): return Img.tmdb(d?.bestBackdrop ?? t.backdropPath, "w1280")
        }
    }
    private var logo: String? {
        switch item {
        case .live(let s): return s.logo
        case .vod(_, let d): return Img.tmdb(d?.logoPath, "w500")
        }
    }
    private var title: String {
        switch item {
        case .live(let s): return s.cardTitle
        case .vod(let t, _): return t.displayTitle
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if case .live(let s) = item, s.match != nil, s.meta == nil { MatchArt(match: s.match!) }
                else { NxImage(url: artwork, maxPixel: Metrics.tv ? 1920 : 1400, alignment: .top) { NxColor.ink2 } }
            }
            .frame(maxWidth: .infinity).frame(height: HeroView.height).clipped()
            #if os(tvOS)
            NxColor.heroScrim
            #endif
            NxColor.heroFade
            VStack(alignment: .leading, spacing: Metrics.u(10)) {
                overline
                if let l = logo {
                    NxImage(url: l, fit: true, maxPixel: 700, alignment: .bottomLeading) { Text(title).font(NxFont.hero).foregroundStyle(.white).lineLimit(2) }
                        .frame(maxWidth: Metrics.u(250), maxHeight: Metrics.u(84), alignment: .bottomLeading)
                } else {
                    Text(title).font(NxFont.hero).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                }
                info
                actions.padding(.top, Metrics.u(4))
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.u(18))
            .frame(maxWidth: Metrics.tv ? 900 : 560, alignment: .leading)
        }
        .frame(height: HeroView.height)
    }

    @ViewBuilder private var overline: some View {
        switch item {
        case .live(let s):
            HStack(spacing: Metrics.u(8)) { ChannelLogo(channel: s.channel, height: 22); ShowingTags(showing: s) }
        case .vod(let t, _):
            HStack(spacing: Metrics.u(8)) { NxTag(text: "On demand"); NxTag(text: t.isTv ? "Serie TV" : "Film") }
        }
    }

    @ViewBuilder private var info: some View {
        switch item {
        case .live(let s):
            VStack(alignment: .leading, spacing: Metrics.u(4)) {
                Text([s.whenLabel(), s.cardLine].compactMap { $0 }.joined(separator: "  ·  ")).font(NxFont.meta).foregroundStyle(NxColor.textMuted).lineLimit(1)
                if let o = s.overview { Text(o).font(NxFont.body).foregroundStyle(NxColor.textMuted).lineLimit(Metrics.tv ? 3 : 2) }
                if let p = s.progress(), s.isLive() { NxProgressBar(value: p).frame(maxWidth: Metrics.u(220)) }
            }
        case .vod(let t, let d):
            VStack(alignment: .leading, spacing: Metrics.u(4)) {
                Text(vodMeta(t, d)).font(NxFont.meta).foregroundStyle(NxColor.textMuted).lineLimit(1)
                if let o = (d?.overview ?? t.overview)?.nilIfBlank { Text(o).font(NxFont.body).foregroundStyle(NxColor.textMuted).lineLimit(Metrics.tv ? 3 : 2) }
            }
        }
    }

    private func vodMeta(_ t: TmdbTitle, _ d: TmdbDetails?) -> String {
        var parts = [String]()
        if t.year > 0 { parts.append(String(t.year)) }
        if let d = d {
            if d.isTv, d.numberOfSeasons > 0 { parts.append(d.numberOfSeasons == 1 ? "1 stagione" : "\(d.numberOfSeasons) stagioni") }
            else if d.runtimeMin > 0 { parts.append(TimeText.duration(minutes: d.runtimeMin)) }
            parts += d.genres.prefix(2).map { $0.name }
        }
        if t.vote > 0 { parts.append(String(format: "★ %.1f", t.vote)) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Metrics.u(10)) {
            switch item {
            case .live(let s):
                if s.isLive() || s.programme == nil {
                    NxButton("Guarda", icon: "play.fill", kind: .primary) { app.play(s.channel) }
                } else {
                    NxButton(store.reminders.contains(s.channel.streamId) ? "Promemoria attivo" : "Avvisami", icon: "bell.fill", kind: .primary) { app.toggleReminder(s) }
                }
                NxButton("Dettagli", icon: "info.circle") { app.openShowing(s) }
                NxIconButton(icon: store.favorites.contains(s.channel.streamId) ? "star.fill" : "star", label: "Preferito", active: store.favorites.contains(s.channel.streamId)) { app.toggleFavorite(s.channel) }
            case .vod(let t, let d):
                NxButton("Riproduci", icon: "play.fill", kind: .primary) { if let d = d { app.playTitle(d) } else { app.playTitle(t) } }
                NxButton("Dettagli", icon: "info.circle") { app.openTitle(t) }
                NxIconButton(icon: store.listKeys.contains(t.key) ? "bookmark.fill" : "bookmark", label: "Da guardare", active: store.listKeys.contains(t.key)) { app.toggleList(t) }
            }
        }
    }
}

/// Carousel of hero slides: it turns by itself, a swipe (touch) or the dots change slide.
struct HeroCarousel: View {
    let items: [HeroItem]
    @State private var slide = 0

    var body: some View {
        let count = items.count
        ZStack(alignment: .bottomTrailing) {
            #if os(tvOS)
            if count > 0 { HeroView(item: items[slide % count]).id(items[slide % count].id).transition(.opacity) }
            #else
            TabView(selection: $slide) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in HeroView(item: it).tag(i) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            if count > 1 {
                HStack(spacing: Metrics.u(5)) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule().fill(i == slide % count ? Color.white : Color.white.opacity(0.35)).frame(width: Metrics.u(i == slide % count ? 16 : 6), height: Metrics.u(6))
                    }
                }
                .padding(.horizontal, Metrics.gutter).padding(.bottom, Metrics.u(14))
                .animation(.easeOut(duration: 0.25), value: slide)
            }
        }
        .frame(height: HeroView.height)
        .task(id: "\(slide)-\(count)") {
            guard count > 1 else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.5)) { slide = (slide + 1) % count } }
        }
        .onChange(of: count) { _, n in if slide >= n { slide = 0 } }
    }
}

/// The page shared by Home and I miei: the carousel, then the rows.
struct HomePage: View {
    let state: HomeState
    var emptyTitle = "Nessun canale"
    var emptyText = "Controlla la connessione (VPN) e riprova dalle impostazioni."
    var onEnd: (() -> Void)? = nil
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    var body: some View {
        if state.rows.isEmpty && state.carousel.isEmpty {
            if state.loading { BrandLoader(label: app.syncStatus ?? "Preparo la tua Home…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { StateMessage(icon: "tv", title: emptyTitle, text: emptyText) }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                        if !state.carousel.isEmpty { HeroCarousel(items: state.carousel).id("top") }
                        else { Color.clear.frame(height: Metrics.u(8)).id("top") }
                        if let s = app.syncStatus {
                            HStack(spacing: 8) { ProgressView(); Text(s).font(NxFont.caption).foregroundStyle(NxColor.textDim) }.padding(.horizontal, Metrics.gutter)
                        }
                        ForEach(state.rows) { row in rowView(row) }
                        if let end = onEnd { Color.clear.frame(height: 1).onAppear(perform: end) }
                        Color.clear.frame(height: Metrics.u(24))
                    }
                }
                .onChange(of: app.reselect) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
            #if os(iOS)
            .ignoresSafeArea(edges: .top)
            #endif
        }
    }

    @ViewBuilder private func rowView(_ row: HomeRow) -> some View {
        switch row {
        case .shows(_, let title, let items, let wide, let sub):
            CardRow(title: title, sub: sub, items: items) { s in
                ShowCard(showing: s, style: wide ? .wide : .compact, favorite: store.favorites.contains(s.channel.streamId), reminder: store.reminders.contains(s.channel.streamId),
                         onTap: { if s.isLive() && !Metrics.tv { app.openShowing(s) } else { app.openShowing(s) } },
                         onPlay: { app.play(s.channel) }, onFavorite: { app.toggleFavorite(s.channel) }, onReminder: { app.toggleReminder(s) })
            }
        case .channels(let id, let title, let items):
            CardRow(title: title, items: items) { c in
                ChannelCard(showing: store.showing(c), favorite: store.favorites.contains(c.streamId),
                            onTap: { app.play(c, ids: id.hasPrefix("cat-") ? items.map { $0.streamId } : nil) },
                            onInfo: { app.openShowing(store.showing(c)) }, onFavorite: { app.toggleFavorite(c) })
            }
        case .vod(_, let title, let r, let overlays, let sub, let tag):
            VodRowView(row: r, overlays: overlays, tag: tag, sub: sub, title: title)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: HomeModel

    init(pid: Int64, kids: Bool) { _model = StateObject(wrappedValue: HomeModel(pid: pid, kids: kids)) }

    var body: some View {
        HomePage(state: model.state)
            .nxPage()
            .onAppear { model.start(store: store); model.rebuild(store) }
            .onChange(of: store.version) { _, _ in model.rebuild(store) }
            .onChange(of: app.syncStatus) { _, _ in model.rebuild(store) }
    }
}

/// "I miei": saved titles, favourite channels, what was left half way — and a few rows that go with them.
@MainActor
final class MineModel: ObservableObject {
    @Published private(set) var state = HomeState()
    private let core = NexCore.shared
    private let pid: Int64
    private let kids: Bool
    private var savedTitles = [TmdbTitle]()
    private var badges = [String: CardOverlay]()
    private var heroes = [HeroItem]()
    private var ready = false
    private var continueRow: HomeRow? = nil
    private var extra = [HomeRow]()
    private enum Source { case similar(TmdbTitle), forYou, genre(String, Int, String), recipe(Recipe) }
    private var queue = [Source]()
    private var queued = false
    private var loadingMore = false
    private var usedRowIds = Set<String>()
    private var lastList = Set<String>()

    init(pid: Int64, kids: Bool) { self.pid = pid; self.kids = kids }

    func refresh(_ store: LiveStore) {
        Task {
            if store.listKeys != lastList || !ready { await loadSaved(store.listKeys) }
            continueRow = await HomeModel.buildContinue(core, pid)
            build(store)
        }
    }

    private func loadSaved(_ keys: Set<String>) async {
        lastList = keys
        var titles = [TmdbTitle](); var b = [String: CardOverlay]()
        for it in core.library.list(pid) {
            guard let e = await core.catalog.ensureTitle(it.tmdbId, it.media) else { continue }
            let t = CatalogRepository.asTmdb(e)
            titles.append(t)
            if let badge = CatalogRepository.badgeFor(t, e) { b[t.key] = CardOverlay(badge: badge) }
        }
        var h = [HeroItem]()
        for t in titles.filter({ $0.backdropPath != nil }).prefix(6) { h.append(.vod(t, try? await core.catalog.details(t.media, t.tmdbId))) }
        savedTitles = titles; badges = b; heroes = h; ready = true
        if !queued { await seedQueue(titles); queued = true; loadMore(nil) }
    }

    private func seedQueue(_ titles: [TmdbTitle]) async {
        queue = titles.map { .similar($0) }
        queue.append(.forYou)
        let tv = await core.catalog.genres("tv"), mv = await core.catalog.genres("movie")
        var count = [String: Int]()
        for t in titles { for g in t.genreIds { count["\(t.media)|\(g)", default: 0] += 1 } }
        for (k, _) in count.sorted(by: { $0.value > $1.value }).prefix(6) {
            let p = k.split(separator: "|")
            guard p.count == 2, let g = Int(p[1]) else { continue }
            let media = String(p[0])
            if let name = (media == "tv" ? tv : mv)[g] { queue.append(.genre(media, g, name)) }
        }
        for r in core.catalog.recipes(tvGenres: tv, movieGenres: mv, kids: kids, media: nil) { queue.append(.recipe(r)) }
    }

    /// "I miei" is the viewer's own page: a few rows that go with what they saved, not an endless catalogue.
    func loadMore(_ store: LiveStore?) {
        if loadingMore || queue.isEmpty || extra.count >= 6 { return }
        loadingMore = true
        Task {
            var built = [HomeRow](); var tries = 0
            while built.count < 2 && !queue.isEmpty && tries < 6 {
                tries += 1
                let src = queue.removeFirst()
                var row: VodRow? = nil; var sub: String? = nil
                switch src {
                case .similar(let t): row = VodRow(id: "sim-\(t.media)-\(t.tmdbId)", title: "Affini a \(t.displayTitle)", items: await core.catalog.similar(t.media, t.tmdbId, kids)); sub = "perché l'hai salvato"
                case .forYou:
                    let mg = await core.catalog.genres("movie"), tg = await core.catalog.genres("tv")
                    row = await core.recommender.rows(pid, kids: kids, genreNames: mg.merging(tg) { a, _ in a }).first { $0.id == "foryou" }
                    row?.id = "mine-foryou"; sub = "in base a cosa guardi"
                case .genre(let media, let g, let name):
                    row = await core.catalog.byGenre(media, g, media == "tv" ? "Serie TV · \(name)" : "Film · \(name)", kids)
                    if let id = row?.id { row?.id = "mine-\(id)" }
                case .recipe(let r):
                    row = await core.catalog.build(r, kids)
                    if let id = row?.id { row?.id = "mine-\(id)" }
                }
                guard let r = row, r.items.count >= 4, usedRowIds.insert(r.id).inserted else { continue }
                var ov = [String: CardOverlay]()
                for t in r.items { if let b = CatalogRepository.badgeFor(t) { ov[t.key] = CardOverlay(badge: b) } }
                built.append(.vod(id: r.id, title: r.title, row: r, overlays: ov, sub: sub, tag: nil))
            }
            extra += built
            loadingMore = false
            if let s = store { build(s) }
        }
    }

    private func build(_ store: LiveStore) {
        var rows = [HomeRow]()
        if !savedTitles.isEmpty {
            rows.append(.vod(id: "mine-saved", title: "Da guardare", row: VodRow(id: "saved", title: "Da guardare", items: savedTitles), overlays: badges,
                             sub: "\(savedTitles.count) titol\(savedTitles.count == 1 ? "o" : "i")", tag: nil))
        }
        let favs = store.channels.filter { store.favorites.contains($0.streamId) }
        if !favs.isEmpty { rows.append(.channels(id: "fav", title: "I tuoi canali preferiti", items: favs)) }
        if let c = continueRow { rows.append(c) }
        // what the favourite channels are showing now, as big cards (only the ones with artwork)
        let onFavs = favs.compactMap { c in store.now(c).map { store.showing(c, $0) } }.filter { $0.image != nil }
        if onFavs.count >= 2 { rows.append(.shows(id: "mine-now", title: "Adesso sui tuoi canali", items: onFavs, wide: true, sub: nil)) }
        rows += extra
        // carousel: saved titles and, between them, what the favourite channels are showing
        let liveHeroes = onFavs.filter { $0.meta != nil }.prefix(3).map { HeroItem.live($0) }
        var carousel = [HeroItem](); var vi = 0, li = 0
        while vi < heroes.count || li < liveHeroes.count {
            if vi < heroes.count { carousel.append(heroes[vi]); vi += 1 }
            if vi < heroes.count { carousel.append(heroes[vi]); vi += 1 }
            if li < liveHeroes.count { carousel.append(liveHeroes[li]); li += 1 }
        }
        state = HomeState(carousel: Array(carousel.prefix(9)), rows: rows, loading: !ready)
    }
}

struct MineView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: MineModel

    init(pid: Int64, kids: Bool) { _model = StateObject(wrappedValue: MineModel(pid: pid, kids: kids)) }

    var body: some View {
        HomePage(state: model.state, emptyTitle: "Qui trovi i tuoi contenuti",
                 emptyText: "Salva un titolo con il segnalibro, un canale con la stella: li ritrovi qui, insieme a ciò che potrebbe piacerti.",
                 onEnd: { model.loadMore(store) })
            .nxPage()
            .onAppear { model.refresh(store) }
            .onChange(of: store.version) { _, _ in model.refresh(store) }
    }
}
