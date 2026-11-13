import SwiftUI

extension HeroItem {
    var heroTitle: String {
        switch self {
        case .live(let s): return s.cardTitle
        case .vod(let t, _): return t.displayTitle
        }
    }
    var heroLogo: String? {
        switch self {
        case .live(let s): return s.logo
        case .vod(_, let d): return Img.tmdb(d?.logoPath, "w500")
        }
    }
    var heroBackdrop: String? {
        switch self {
        case .live(let s): return Img.hero(s.image)
        case .vod(let t, let d): return Img.tmdb(d?.bestBackdrop ?? t.backdropPath, "w1280")
        }
    }
    var heroOverview: String? {
        switch self {
        case .live(let s): return s.overview
        case .vod(let t, let d): return (d?.overview ?? t.overview)?.nilIfBlank
        }
    }
    /// The quiet line under the title: year, length, genres — or channel and time for something on TV.
    var heroMeta: String {
        switch self {
        case .live(let s): return [s.channel.name, s.whenLabel(), s.cardLine].compactMap { $0 }.joined(separator: "  ·  ")
        case .vod(let t, let d):
            var parts = [String]()
            if t.year > 0 { parts.append(String(t.year)) }
            if let d = d {
                if d.isTv, d.numberOfSeasons > 0 { parts.append(d.numberOfSeasons == 1 ? "1 stagione" : "\(d.numberOfSeasons) stagioni") }
                else if d.runtimeMin > 0 { parts.append(TimeText.duration(minutes: d.runtimeMin)) }
                parts += d.genres.prefix(2).map { $0.name }
            } else { parts.append(t.isTv ? "Serie TV" : "Film") }
            return parts.joined(separator: "  ·  ")
        }
    }
}

#if os(iOS)
/// The big card on top of Home, Film, Serie TV: the poster, the title, and the two things to do.
struct HeroView: View {
    let item: HeroItem
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    private var art: String? {
        switch item {
        case .live(let s): return Img.hero(s.image)
        case .vod(let t, let d):
            if Metrics.isPad { return Img.tmdb(d?.bestBackdrop ?? t.backdropPath, "w1280") ?? Img.tmdb(t.posterPath, "w780") }
            return Img.tmdb(t.posterPath ?? d?.posterPath, "w780") ?? Img.tmdb(d?.bestBackdrop ?? t.backdropPath, "w1280")
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if case .live(let s) = item, s.match != nil, s.meta == nil { MatchArt(match: s.match!) }
                else if case .live(let s) = item, art == nil { ShowingArt(showing: s, hero: true) }
                else { NxImage(url: art, maxPixel: 1400, alignment: .top) { NxColor.ink2 } }
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.42), .init(color: .black.opacity(0.72), location: 0.74), .init(color: .black.opacity(0.96), location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                if case .live(let s) = item { HStack(spacing: 8) { ChannelLogo(channel: s.channel, height: 20); ShowingTags(showing: s, showKind: false) } }
                if let l = item.heroLogo {
                    NxImage(url: l, fit: true, maxPixel: 700, alignment: .bottom) { titleText }.frame(maxWidth: 240, maxHeight: 84, alignment: .bottom)
                } else { titleText }
                Text(item.heroMeta).font(NxFont.ui(12, .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                if case .live(let s) = item, let p = s.progress(), s.isLive() { NxProgressBar(value: p).frame(maxWidth: 200) }
                actions.padding(.top, 2).frame(maxWidth: 440)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            switch item {
            case .live(let s): app.openShowing(s)
            case .vod(let t, _): app.openTitle(t)
            }
        }
    }

    private var titleText: some View {
        Text(item.heroTitle).font(NxFont.hero).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6).multilineTextAlignment(.center)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch item {
            case .live(let s):
                let fav = store.favorites.contains(s.channel.streamId)
                if s.isLive() || s.programme == nil { NxButton("Guarda", icon: "play.fill", kind: .primary, wide: true) { app.play(s.channel) } }
                else { NxButton(store.reminders.contains(s.channel.streamId) ? "Avviso attivo" : "Avvisami", icon: "bell.fill", kind: .primary, wide: true) { app.toggleReminder(s) } }
                NxButton(fav ? "Preferito" : "Preferiti", icon: fav ? "checkmark" : "plus", wide: true) { app.toggleFavorite(s.channel) }
            case .vod(let t, let d):
                let inList = store.listKeys.contains(t.key)
                NxButton("Riproduci", icon: "play.fill", kind: .primary, wide: true) { if let d = d { app.playTitle(d) } else { app.playTitle(t) } }
                NxButton("La mia lista", icon: inList ? "checkmark" : "plus", wide: true) { app.toggleList(t) }
            }
        }
    }
}

/// The hero cards side by side: swipe to see the next one; it also moves on by itself.
struct HeroCarousel: View {
    let items: [HeroItem]
    @State private var slide: String? = nil
    @State private var width: CGFloat = 390

    var body: some View {
        let cardW = Metrics.isPad ? min(width - 80, 760) : min(width - 36, 420)
        let ratio: CGFloat = Metrics.isPad ? 0.62 : 1.36
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { it in HeroView(item: it).frame(width: cardW, height: cardW * ratio).id(it.id) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, (width - cardW) / 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $slide)
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items) { it in
                        let on = (slide ?? items.first?.id) == it.id
                        Circle().fill(on ? Color.white : Color.white.opacity(0.3)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .task(id: "\(slide ?? "")-\(items.count)") {
            guard items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { return }
            let i = items.firstIndex { $0.id == (slide ?? items.first?.id) } ?? 0
            withAnimation(.easeInOut(duration: 0.45)) { slide = items[(i + 1) % items.count].id }
        }
    }
}
#else
/// Apple TV: the top of a browsing page describes what the remote is on — the artwork on the right, the title and
/// the plot on the left. With nothing chosen yet it shows the page's own suggestions, one after the other.
struct Billboard: View {
    let items: [HeroItem]
    @ObservedObject private var hub = FocusHub.shared
    @EnvironmentObject var app: AppModel
    @State private var slide = 0
    @State private var details: TmdbDetails? = nil
    static let height: CGFloat = 470

    private var item: HeroItem? {
        if let f = hub.item {
            if case .vod(let t, nil) = f, let d = details, d.id == t.tmdbId { return .vod(t, d) }
            return f
        }
        return items.isEmpty ? nil : items[slide % items.count]
    }

    var body: some View {
        let it = item
        ZStack(alignment: .topLeading) {
            if let i = it {
                Group {
                    if case .live(let s) = i, s.match != nil, s.meta == nil { MatchArt(match: s.match!) }
                    else if case .live(let s) = i, i.heroBackdrop == nil { ShowingArt(showing: s, hero: true) }
                    else { NxImage(url: i.heroBackdrop, maxPixel: 1920, alignment: .top) { NxColor.bg } }
                }
                .frame(width: 1240, height: 698)
                .overlay(NxColor.heroScrim)
                .overlay(NxColor.heroFade)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .id(i.id)
                .transition(.opacity)
                VStack(alignment: .leading, spacing: 14) {
                    if case .live(let s) = i { HStack(spacing: 12) { ChannelLogo(channel: s.channel, height: 22); ShowingTags(showing: s) } }
                    if let l = i.heroLogo {
                        NxImage(url: l, fit: true, maxPixel: 800, alignment: .bottomLeading) { title(i) }.frame(maxWidth: 520, maxHeight: 170, alignment: .bottomLeading)
                    } else { title(i) }
                    Text(i.heroMeta).font(NxFont.ui(13, .bold)).foregroundStyle(.white).lineLimit(1)
                    if let o = i.heroOverview { Text(o).font(NxFont.ui(14, .medium)).foregroundStyle(NxColor.textMuted).lineLimit(3).frame(maxWidth: 780, alignment: .leading) }
                    if case .live(let s) = i, let p = s.progress(), s.isLive() { NxProgressBar(value: p).frame(width: 380) }
                }
                .padding(.leading, Metrics.gutter).padding(.top, 70)
                .frame(maxWidth: 900, maxHeight: Billboard.height, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 698, alignment: .top)
        .animation(.easeInOut(duration: 0.3), value: it?.id)
        .task(id: it?.id) {
            if case .vod(let t, nil)? = hub.item { details = try? await app.core.catalog.details(t.media, t.tmdbId) }
        }
        .task(id: "\(slide)-\(items.count)-\(hub.item == nil)") {
            guard items.count > 1, hub.item == nil else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !Task.isCancelled { slide = (slide + 1) % items.count }
        }
    }

    private func title(_ i: HeroItem) -> some View {
        Text(i.heroTitle).font(NxFont.display(34, .heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
    }
}
#endif

/// A browsing page: the hero, then the rows. Shared by Home, Film, Serie TV and the viewer's own page.
struct BrowsePage<Top: View>: View {
    let state: HomeState
    var emptyTitle = "Nessun canale"
    var emptyText = "Controlla la connessione (VPN) e riprova dalle impostazioni."
    var loadingLabel = "Preparo la tua Home…"
    var onEnd: (() -> Void)? = nil
    /// What sits above the hero on the phone (the pills).
    @ViewBuilder var top: () -> Top
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    var body: some View {
        if state.rows.isEmpty && state.carousel.isEmpty {
            if state.loading { BrandLoader(label: app.syncStatus ?? loadingLabel).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { VStack(spacing: 0) { top(); StateMessage(icon: "tv", title: emptyTitle, text: emptyText) } }
        } else {
            #if os(tvOS)
            ZStack(alignment: .topLeading) {
                Billboard(items: state.carousel)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                        top()
                        rows
                        Color.clear.frame(height: 60)
                    }
                    .padding(.top, 14)
                }
                .scrollClipDisabled(false)
                .padding(.top, Billboard.height)
            }
            .ignoresSafeArea()
            .onAppear { FocusHub.shared.clear() }
            #else
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                        VStack(spacing: 12) {
                            top()
                            if !state.carousel.isEmpty { HeroCarousel(items: state.carousel) }
                        }
                        .id("top")
                        rows
                        Color.clear.frame(height: 16)
                    }
                }
                .onChange(of: app.reselect) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
            #endif
        }
    }

    @ViewBuilder private var rows: some View {
        if let s = app.syncStatus {
            HStack(spacing: Metrics.u(8)) { NxSpinner(size: 14); Text(s).font(NxFont.caption).foregroundStyle(NxColor.textDim) }.padding(.horizontal, Metrics.gutter)
        }
        ForEach(state.rows) { row in rowView(row) }
        if let end = onEnd { Color.clear.frame(height: 1).onAppear(perform: end) }
    }

    @ViewBuilder private func rowView(_ row: HomeRow) -> some View {
        switch row {
        case .shows(_, let title, let items, let wide, let sub):
            CardRow(title: title, sub: sub, items: items) { s in
                ShowCard(showing: s, style: wide ? .wide : .compact, favorite: store.favorites.contains(s.channel.streamId), reminder: store.reminders.contains(s.channel.streamId)) { app.openShowing(s) }
            }
        case .channels(let id, let title, let items):
            CardRow(title: title, items: items) { c in
                ChannelCard(showing: store.showing(c), favorite: store.favorites.contains(c.streamId)) { app.play(c, ids: id.hasPrefix("cat-") ? items.map { $0.streamId } : nil) }
            }
        case .vod(_, let title, let r, let overlays, let sub, let tag):
            VodRowView(row: r, overlays: overlays, tag: tag, sub: sub, title: title)
        }
    }
}

extension BrowsePage where Top == EmptyView {
    init(state: HomeState, emptyTitle: String = "Nessun canale", emptyText: String = "Controlla la connessione (VPN) e riprova dalle impostazioni.", loadingLabel: String = "Preparo la tua Home…", onEnd: (() -> Void)? = nil) {
        self.init(state: state, emptyTitle: emptyTitle, emptyText: emptyText, loadingLabel: loadingLabel, onEnd: onEnd, top: { EmptyView() })
    }
}

/// Home: what is on now, what was left half way, what to watch next.
struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: HomeModel
    @StateObject private var others = OthersWatcher()
    private let pid: Int64

    init(pid: Int64, kids: Bool) { self.pid = pid; _model = StateObject(wrappedValue: HomeModel(pid: pid, kids: kids)) }

    /// The Home, with what was left half way on another device on top.
    private var state: HomeState {
        var s = model.state
        if let r = others.row, !s.rows.isEmpty { s.rows.insert(r, at: 0) }
        return s
    }

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NxTopBar(title: "Per \(app.profile?.name ?? "te")", back: false, large: true) {
                    BarIcon(icon: "magnifyingglass", label: "Cerca") { app.open(.search) }
                }
                BrowsePage(state: state) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            NxChip(title: "Guida TV", icon: "calendar", selected: false) { app.liveTab = 1; app.section = .live }
                            NxChip(title: "Le mie squadre", selected: false) { app.open(.teams) }
                            NxChip(title: "Download", selected: false) { app.open(.downloads) }
                        }
                        .padding(.horizontal, Metrics.gutter).padding(.vertical, 4)
                    }
                }
            }
            #else
            BrowsePage(state: state)
            #endif
        }
        .nxPage()
        .onAppear { model.start(store: store); model.rebuild(store); others.start(pid: pid) }
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
            rows.append(.vod(id: "mine-saved", title: "La mia lista", row: VodRow(id: "saved", title: "La mia lista", items: savedTitles), overlays: badges,
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

/// The viewer's own page. Apple TV: "La mia lista". iPhone: "Il mio spazio" — the profile, the shortcuts, then the
/// saved titles, the favourite channels and what was left half way.
struct MineView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: MineModel

    init(pid: Int64, kids: Bool) { _model = StateObject(wrappedValue: MineModel(pid: pid, kids: kids)) }

    private var rowsOnly: HomeState { HomeState(carousel: Metrics.tv ? model.state.carousel : [], rows: model.state.rows, loading: model.state.loading) }

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NxTopBar(title: "Il mio spazio", back: false, large: true) {
                    BarIcon(icon: "magnifyingglass", label: "Cerca") { app.open(.search) }
                    BarIcon(icon: "gearshape", label: "Impostazioni") { app.open(.settings) }
                }
                BrowsePage(state: rowsOnly, emptyTitle: "Qui trovi i tuoi contenuti",
                           emptyText: "Aggiungi un titolo alla tua lista, un canale ai preferiti: li ritrovi qui.",
                           loadingLabel: "Carico i tuoi contenuti…", onEnd: { model.loadMore(store) }) { header }
            }
            #else
            BrowsePage(state: rowsOnly, emptyTitle: "Qui trovi i tuoi contenuti",
                       emptyText: "Aggiungi un titolo alla tua lista, un canale ai preferiti: li ritrovi qui, insieme a ciò che potrebbe piacerti.",
                       loadingLabel: "Carico i tuoi contenuti…", onEnd: { model.loadMore(store) })
            #endif
        }
        .nxPage()
        .onAppear { model.refresh(store) }
        .onChange(of: store.version) { _, _ in model.refresh(store) }
    }

    #if os(iOS)
    private var header: some View {
        VStack(spacing: 14) {
            if let p = app.profile {
                Button { app.changeProfile() } label: {
                    VStack(spacing: 8) {
                        p.face(72)
                        HStack(spacing: 6) {
                            Text(p.name).font(NxFont.display(20, .bold)).foregroundStyle(.white)
                            Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(NxPlainStyle())
                .accessibilityLabel("Cambia profilo")
            }
            VStack(spacing: 0) {
                shortcut("arrow.down.to.line", NxColor.kids, "Download", "Film ed episodi salvati sul telefono") { app.open(.downloads) }
                shortcut("appletvremote.gen4.fill", NxColor.accent, "Telecomando della TV", "Comanda NexStream sulla TV di casa") { app.open(.remote) }
                shortcut("soccerball", NxColor.success, "Le tue squadre", "Partite in Home e un avviso prima dell'inizio") { app.open(.teams) }
            }
        }
        .padding(.top, 6)
    }

    private func shortcut(_ icon: String, _ color: Color, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(color, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(NxFont.ui(16, .bold)).foregroundStyle(.white)
                    Text(sub).font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(NxColor.textDim)
            }
            .padding(.horizontal, Metrics.gutter).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(NxPlainStyle(scale: 0.99))
    }
    #endif
}
