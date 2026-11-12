import SwiftUI

/// The Film / Serie TV pages: a carousel of titles of their kind, the viewer's own rows, the catalogue, and then rows
/// that keep coming while scrolling (a different order every day).
@MainActor
final class VodHomeModel: ObservableObject {
    @Published private(set) var state = HomeState()
    @Published private(set) var genres: [(Int, String)] = []
    private let core = NexCore.shared
    private let media: String
    private let pid: Int64
    private let kids: Bool
    private var heroes = [HeroItem]()
    private var publicRows = [VodRow]()
    private var personal = [VodRow]()
    private var soon: VodRow? = nil
    private var continueRow: HomeRow? = nil
    private var listRow: VodRow? = nil
    private var badges = [String: CardOverlay]()
    private var recipes = [Recipe]()
    private var recipeIdx = 0
    private var extra = [VodRow]()
    private var loadingRows = false
    private var ready = false
    private var started = false
    private var lastList: Set<String>? = nil

    init(media: String, pid: Int64, kids: Bool) { self.media = media; self.pid = pid; self.kids = kids }

    func start() {
        if started { return }
        started = true
        Task { await load() }
    }

    private func mine(_ t: TmdbTitle) -> Bool { t.media == media }

    private func load() async {
        let core = self.core, kids = self.kids, media = self.media
        let all = await core.catalog.genres(media)
        let kidsGenres: Set<Int> = [16, 10751, 10762, 35, 12, 14, 878]
        genres = all.filter { !kids || kidsGenres.contains($0.key) }.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
        // the Film / Serie TV pages open on a title of their own kind
        var cands = await core.catalog.heroCandidates(kids).filter { $0.media == media }
        if cands.count < 3 {
            let more = (try? await core.tmdb.trending(media, window: "week")) ?? []
            cands = (cands + core.catalog.clean(more, kids).filter { $0.backdropPath != nil }).distinct { $0.key }
        }
        var hs = [HeroItem]()
        for t in cands.prefix(5) { hs.append(.vod(t, try? await core.catalog.details(t.media, t.tmdbId))) }
        heroes = hs
        publish()
        publicRows = await core.catalog.publicRows(kids)
        for r in publicRows { for t in r.items { if let b = CatalogRepository.badgeFor(t) { badges[t.key] = CardOverlay(badge: b) } } }
        publish()
        let up = await core.catalog.upcomingRow(kids)
        soon = up.items.contains(where: mine) ? up : nil
        publish()
        let mg = await core.catalog.genres("movie"), tg = await core.catalog.genres("tv")
        personal = await core.recommender.rows(pid, kids: kids, genreNames: mg.merging(tg) { a, _ in a })
        recipes = core.catalog.recipes(tvGenres: tg, movieGenres: mg, kids: kids, media: media)
        ready = true
        publish()
        loadMore()
    }

    /// The profile's own rows (continue watching, Da guardare) follow the database.
    func refreshPersonal(listKeys: Set<String>) {
        Task {
            continueRow = await HomeModel.buildContinue(core, pid)
            if lastList != listKeys {
                lastList = listKeys
                var titles = [TmdbTitle]()
                for it in core.library.list(pid) where it.media == media {
                    if let e = await core.catalog.ensureTitle(it.tmdbId, it.media) {
                        let t = CatalogRepository.asTmdb(e)
                        titles.append(t)
                        if let b = CatalogRepository.badgeFor(t, e) { badges[t.key] = CardOverlay(badge: b) }
                    }
                }
                listRow = titles.isEmpty ? nil : VodRow(id: "mylist", title: "Da guardare", items: titles)
            }
            publish()
        }
    }

    /// Rows built on demand while the page scrolls down.
    func loadMore() {
        if !ready || loadingRows || recipeIdx >= recipes.count || extra.count >= 40 { return }
        loadingRows = true
        Task {
            var built = 0, tries = 0
            while built < 3 && recipeIdx < recipes.count && tries < 8 {
                tries += 1
                let r = recipes[recipeIdx]; recipeIdx += 1
                let row = await core.catalog.build(r, kids)
                if row.items.count >= 6 { extra.append(row); built += 1 }
            }
            loadingRows = false
            publish()
        }
    }

    private func overlays(_ r: VodRow) -> [String: CardOverlay] {
        var o = [String: CardOverlay]()
        for t in r.items { if let b = badges[t.key] { o[t.key] = b } }
        return o
    }
    private func row(_ r: VodRow, title: String? = nil, sub: String? = nil) -> HomeRow? {
        var x = r
        x.items = r.items.filter(mine)
        if x.items.count < 4 && r.id != "mylist" { return nil }
        if x.items.isEmpty { return nil }
        return .vod(id: "v-\(r.id)", title: title ?? r.title, row: x, overlays: overlays(x), sub: sub, tag: nil)
    }

    private func publish() {
        var rows = [HomeRow]()
        if case .vod(let id, let title, let r, let ov, let sub, let tag)? = continueRow {
            var x = r; x.items = r.items.filter(mine)
            if !x.items.isEmpty { rows.append(.vod(id: id, title: title, row: x, overlays: ov, sub: sub, tag: tag)) }
        }
        if let l = listRow, let r = row(l) { rows.append(r) }
        for p in personal { if let r = row(p, sub: p.id == "foryou" ? "in base a cosa guardi" : nil) { rows.append(r) } }
        let wanted = media == "movie" ? ["top10movie", "new", "week", "movies", "docs", "top_rated", "kids", "short"] : ["top10tv", "new", "week", "series", "anime", "docs", "top_rated"]
        for id in wanted { if let p = publicRows.first(where: { $0.id == id }), let r = row(p) { rows.append(r) } }
        if let s = soon, let r = row(s) { rows.append(r) }
        for e in extra { if let r = row(e) { rows.append(r) } }
        state = HomeState(carousel: heroes, rows: rows, loading: !ready && rows.isEmpty)
    }
}

struct VodHomeView: View {
    let media: String
    /// Opened as a page on the phone (from the pills of Home): it gets a back arrow.
    var pushed = false
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: VodHomeModel

    init(media: String, pid: Int64, kids: Bool, pushed: Bool = false) {
        self.media = media
        self.pushed = pushed
        _model = StateObject(wrappedValue: VodHomeModel(media: media, pid: pid, kids: kids))
    }

    private var vodOnly: HomeState {
        var s = model.state
        s.rows = s.rows.filter { if case .vod = $0 { return true }; return false }
        return s
    }

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NxTopBar(title: media == "tv" ? "Serie TV" : "Film", back: pushed, large: true) {
                    BarIcon(icon: "magnifyingglass", label: "Cerca") { app.open(.search) }
                }
                BrowsePage(state: vodOnly, emptyTitle: "Niente da mostrare", emptyText: "Controlla la connessione e riprova.",
                           loadingLabel: media == "tv" ? "Carico le serie TV…" : "Carico i film…", onEnd: { model.loadMore() }) { genres }
            }
            #else
            BrowsePage(state: vodOnly, emptyTitle: "Niente da mostrare", emptyText: "Controlla la connessione e riprova.",
                       loadingLabel: media == "tv" ? "Carico le serie TV…" : "Carico i film…", onEnd: { model.loadMore() }) { genres }
            #endif
        }
        .nxPage()
        .onAppear { model.start(); model.refreshPersonal(listKeys: store.listKeys) }
        .onChange(of: store.listKeys) { _, k in model.refreshPersonal(listKeys: k) }
    }

    @ViewBuilder private var genres: some View {
        if !model.genres.isEmpty {
            #if os(iOS)
            HStack(spacing: 8) {
                NxChip(title: "Generi", trailing: "chevron.down", selected: false) {
                    app.menu(media == "tv" ? "Generi delle serie TV" : "Generi dei film", model.genres.map { g in NxAction(g.1) { app.open(.genre(media, g.0, g.1)) } })
                }
                if media == "movie" { NxChip(title: "Serie TV", selected: false) { if pushed { app.pop() }; app.open(.vod("tv")) } }
                else { NxChip(title: "Film", selected: false) { if pushed { app.pop() }; app.open(.vod("movie")) } }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter).padding(.vertical, 4)
            #else
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Sfoglia per genere")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(model.genres, id: \.0) { g in NxChip(title: g.1, selected: false) { app.open(.genre(media, g.0, g.1)) } }
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            #endif
        }
    }
}

/// "Generi": the rows of one genre.
struct GenreView: View {
    let media: String
    let genreId: Int
    let name: String
    @EnvironmentObject var app: AppModel
    @State private var rows: [VodRow]? = nil

    var body: some View {
        Group {
            if let r = rows {
                if r.isEmpty { StateMessage(icon: "film", title: "Niente in questo genere", text: "Riprova più tardi.") }
                else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                            ForEach(r) { VodRowView(row: $0) }
                            Color.clear.frame(height: Metrics.u(24))
                        }.padding(.top, Metrics.u(10))
                    }
                }
            } else { BrandLoader(label: name).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .nxScreen((media == "tv" ? "Serie TV · " : "Film · ") + name)
        .task { if rows == nil { rows = await app.core.catalog.genreRows(media, genreId, name, app.kids) } }
    }
}

// ---------------------------------------------------------------------------------------------------------------- title page

@MainActor
final class TitleDetailModel: ObservableObject {
    @Published var details: TmdbDetails? = nil
    @Published var failed = false
    @Published var season = 1
    @Published var episodes: [TmdbEpisode] = []
    @Published var progress: [ProgressEntity] = []
    @Published var similar: [TmdbTitle] = []
    @Published var airings: [Showing] = []
    @Published var match = 0
    @Published var feedback: String? = nil
    private let core = NexCore.shared
    let media: String
    let id: Int
    private var watch: Watch?

    init(media: String, id: Int) { self.media = media; self.id = id }

    func load(pid: Int64, kids: Bool) async {
        if details != nil { reloadPersonal(pid); return }
        do {
            let d = try await core.catalog.details(media, id)
            details = d
            reloadPersonal(pid)
            if d.isTv {
                let last = progress.first
                season = last?.season ?? (d.seasons.first { $0.seasonNumber > 0 }?.seasonNumber ?? 1)
                if season <= 0 { season = 1 }
                await loadSeason(season)
            }
            similar = await core.catalog.similar(media, id, kids)
            let core = self.core, media = self.media, id = self.id
            airings = await Task.detached { core.matcher.airingsOf(media, id) }.value
            match = core.recommender.matchPercent(pid, d.toTitle())
        } catch { failed = true }
        watch = core.db.changes.observe { [weak self] t in
            if t == "progress" || t == "watch_event" { DispatchQueue.main.async { self?.reloadPersonal(pid) } }
        }
    }

    func reloadPersonal(_ pid: Int64) {
        progress = core.library.progressFor(pid, id, media)
        feedback = core.library.feedback(pid, id, media)
    }
    func loadSeason(_ s: Int) async {
        season = s
        episodes = (try? await core.catalog.season(id, s))?.episodes ?? []
    }
    func progress(for e: TmdbEpisode) -> ProgressEntity? { progress.first { $0.season == e.seasonNumber && $0.episode == e.episodeNumber } }
}

/// The page of a film or a series: the artwork, the one button to play it from where it was left, what it is, the
/// episodes, where it is on TV in the next days, similar titles.
struct TitleDetailView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: TitleDetailModel
    @State private var more = false
    @State private var tab = 0

    init(media: String, tmdbId: Int) { _model = StateObject(wrappedValue: TitleDetailModel(media: media, id: tmdbId)) }

    var body: some View {
        Group {
            if let d = model.details { page(d) }
            else if model.failed { StateMessage(icon: "wifi.exclamationmark", title: "Non riesco a caricare questo titolo", text: "Controlla la connessione e riprova.") }
            else { BrandLoader().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .nxPage()
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            NxIconButton(icon: "chevron.left", label: "Indietro", size: 36) { app.pop() }.padding(.leading, 10).padding(.top, 6)
        }
        #endif
        .task { await model.load(pid: app.pid, kids: app.kids) }
    }

    private func resumeLabel(_ d: TmdbDetails) -> String {
        let last = model.progress.first
        if !d.isTv { return (last != nil && !last!.completed && last!.positionMs > 60_000) ? "Riprendi" : "Riproduci" }
        guard let l = last else { return "Riproduci S1 E1" }
        return l.completed ? "Riproduci S\(l.season) E\(l.episode + 1)" : "Riprendi S\(l.season) E\(l.episode)"
    }

    private func restart(_ d: TmdbDetails) {
        if d.isTv { app.play(PlayRequest(details: d, season: 1, episode: 1)) } else { app.play(PlayRequest(details: d, startMs: 0)) }
    }

    private func metaLine(_ d: TmdbDetails) -> some View {
        HStack(spacing: Metrics.u(8)) {
            if model.match > 0 { Text("\(model.match)% per te").font(NxFont.ui(13, .heavy)).foregroundStyle(NxColor.success) }
            if d.year > 0 { Text(String(d.year)).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
            if let c = d.certification { NxTag(text: c) }
            if d.isTv { Text(d.numberOfSeasons == 1 ? "1 stagione" : "\(d.numberOfSeasons) stagioni").font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
            else if d.runtimeMin > 0 { Text(TimeText.duration(minutes: d.runtimeMin)).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
            if d.voteAverage > 0 { Text(String(format: "★ %.1f", d.voteAverage)).font(NxFont.meta).foregroundStyle(NxColor.gold) }
        }
    }

    @ViewBuilder private func credits(_ d: TmdbDetails) -> some View {
        if !d.cast.isEmpty {
            (Text("Cast: ").foregroundColor(NxColor.textDim) + Text(d.cast.prefix(more ? 8 : 4).map { $0.name }.joined(separator: ", ")).foregroundColor(NxColor.textMuted))
                .font(NxFont.caption).lineLimit(more ? 4 : 1)
        }
        if let dir = d.directors.first ?? d.createdBy?.first {
            (Text(d.isTv ? "Creata da: " : "Regia: ").foregroundColor(NxColor.textDim) + Text(dir.name).foregroundColor(NxColor.textMuted)).font(NxFont.caption).lineLimit(1)
        }
        if !d.genres.isEmpty {
            (Text("Generi: ").foregroundColor(NxColor.textDim) + Text(d.genres.map { $0.name }.joined(separator: ", ")).foregroundColor(NxColor.textMuted)).font(NxFont.caption).lineLimit(1)
        }
    }

    @ViewBuilder private func secondary(_ d: TmdbDetails, _ t: TmdbTitle) -> some View {
        let last = model.progress.first
        let inList = store.listKeys.contains(t.key)
        NxIconAction(icon: inList ? "checkmark" : "plus", label: "La mia lista", active: inList) { app.toggleList(t) }
        NxIconAction(icon: model.feedback == "liked" ? "hand.thumbsup.fill" : "hand.thumbsup", label: "Mi piace", active: model.feedback == "liked") {
            app.core.library.setFeedback(app.pid, d.id, d.media, current: model.feedback, want: "liked")
        }
        NxIconAction(icon: model.feedback == "disliked" ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Non fa per me", active: model.feedback == "disliked") {
            app.core.library.setFeedback(app.pid, d.id, d.media, current: model.feedback, want: "disliked")
        }
        if last != nil { NxIconAction(icon: "arrow.counterclockwise", label: "Ricomincia") { restart(d) } }
        if !d.isTv {
            NxIconAction(icon: last?.completed == true ? "checkmark.circle.fill" : "checkmark.circle", label: last?.completed == true ? "Visto" : "Segna visto", active: last?.completed == true) {
                if last?.completed == true { app.core.library.clearProgress(app.pid, d.id, d.media) }
                else { app.core.library.markWatched(app.pid, d.id, d.media, season: 0, episode: 0, runtimeMin: d.runtimeMin) }
            }
        }
    }

    private func request(_ d: TmdbDetails, _ e: TmdbEpisode) -> PlayRequest {
        let p = model.progress(for: e)
        return PlayRequest(details: d, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name, startMs: (p != nil && !p!.completed) ? p!.positionMs : 0)
    }

    private func episodeMenu(_ d: TmdbDetails, _ e: TmdbEpisode) {
        let done = model.progress(for: e)?.completed == true
        app.menu("\(e.episodeNumber). \(e.name ?? "Episodio")", [
            NxAction("Riproduci", icon: "play.fill") { app.play(request(d, e)) },
            NxAction(done ? "Segna come non visto" : "Segna come visto", icon: done ? "circle" : "checkmark.circle") {
                if done { app.core.library.markUnwatched(app.pid, d.id, d.media, season: e.seasonNumber, episode: e.episodeNumber) }
                else { app.core.library.markWatched(app.pid, d.id, d.media, season: e.seasonNumber, episode: e.episodeNumber, runtimeMin: e.runtime ?? d.runtimeMin) }
            },
        ])
    }

    private func still(_ e: TmdbEpisode, _ w: CGFloat) -> some View {
        let p = model.progress(for: e)
        return ZStack(alignment: .bottom) {
            NxImage(url: Img.tmdb(e.stillPath, "w300"), maxPixel: 500) { NxColor.ink3 }
            Image(systemName: p?.completed == true ? "checkmark" : "play.fill").font(.system(size: 12 * Metrics.unit, weight: .bold)).foregroundStyle(.white)
                .frame(width: Metrics.u(30), height: Metrics.u(30))
                .background(Color.black.opacity(0.55), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let pr = p, !pr.completed, pr.durationMs > 0 { NxProgressBar(value: Double(pr.positionMs) / Double(pr.durationMs)) }
        }
        .frame(width: w, height: w * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }

    private func seasonPill(_ d: TmdbDetails) -> some View {
        let seasons = d.seasons.filter { $0.seasonNumber > 0 }
        return Group {
            if seasons.count > 1 {
                NxChip(title: "Stagione \(model.season)", trailing: "chevron.down", selected: false) {
                    app.choose("Stagioni", seasons.map { ($0.seasonNumber, "Stagione \($0.seasonNumber)" + ($0.episodeCount.map { " · \($0) episodi" } ?? "")) }, current: model.season) { s in
                        Task { await model.loadSeason(s) }
                    }
                }
            } else { Text("Stagione \(model.season)").font(NxFont.ui(14, .bold)).foregroundStyle(NxColor.textMuted) }
        }
    }

    #if os(iOS)
    @ViewBuilder private func page(_ d: TmdbDetails) -> some View {
        let t = d.toTitle()
        let last = model.progress.first
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                Button { app.playTitle(d) } label: {
                    ZStack {
                        NxImage(url: Img.tmdb(d.bestBackdrop ?? d.posterPath, "w1280"), maxPixel: 1400, alignment: .top) { NxColor.ink2 }
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 58, height: 58).background(Color.black.opacity(0.5), in: Circle()).overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    }
                    .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit).clipped()
                }
                .buttonStyle(NxPlainStyle(scale: 1))
                VStack(alignment: .leading, spacing: 10) {
                    Text(d.displayTitle).font(NxFont.display(23, .bold)).foregroundStyle(.white).lineLimit(3)
                    metaLine(d)
                    NxButton(resumeLabel(d), icon: "play.fill", kind: .primary, wide: true) { app.playTitle(d) }
                    if !d.isTv { DownloadButton(request: PlayRequest(details: d), wide: true) }
                    if let l = last, !l.completed, l.durationMs > 0 {
                        HStack(spacing: 8) {
                            NxProgressBar(value: Double(l.positionMs) / Double(l.durationMs))
                            Text("mancano \(max(1, Int((l.durationMs - l.positionMs) / Clock.minute))) min").font(NxFont.caption).foregroundStyle(NxColor.textDim).fixedSize()
                        }
                    }
                    if let o = d.overview?.nilIfBlank {
                        Text(o).font(NxFont.ui(14)).foregroundStyle(.white).lineLimit(more ? nil : 3)
                            .contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { more.toggle() } }
                    }
                    credits(d)
                    HStack(alignment: .top, spacing: 4) { secondary(d, t); Spacer(minLength: 0) }.padding(.top, 2).padding(.leading, -10)
                }
                .padding(.horizontal, Metrics.gutter)
                tabs(d)
                Color.clear.frame(height: 20)
            }
        }
    }

    private func tabNames(_ d: TmdbDetails) -> [(Int, String)] {
        var out = [(Int, String)]()
        if d.isTv { out.append((0, "Episodi")) }
        if model.similar.count >= 3 { out.append((1, "Simili")) }
        if !model.airings.isEmpty { out.append((2, "In TV")) }
        return out
    }

    @ViewBuilder private func tabs(_ d: TmdbDetails) -> some View {
        let names = tabNames(d)
        let current = names.contains { $0.0 == tab } ? tab : (names.first?.0 ?? -1)
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    Rectangle().fill(NxColor.ink4).frame(height: 1)
                    HStack(spacing: 22) {
                        ForEach(names, id: \.0) { n in
                            Button { tab = n.0 } label: {
                                VStack(spacing: 8) {
                                    Rectangle().fill(current == n.0 ? NxColor.accent : Color.clear).frame(height: 4)
                                    Text(n.1).font(NxFont.ui(15, .heavy)).foregroundStyle(current == n.0 ? Color.white : NxColor.textDim)
                                }
                                .fixedSize()
                            }
                            .buttonStyle(NxPlainStyle(scale: 1))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                switch current {
                case 0:
                    seasonPill(d).padding(.horizontal, Metrics.gutter)
                    LazyVStack(spacing: 16) { ForEach(model.episodes) { e in episodeRow(d, e) } }.padding(.horizontal, Metrics.gutter)
                case 1:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(model.similar.prefix(18)) { s in
                            GeometryReader { g in PosterCard(title: s, inList: store.listKeys.contains(s.key), width: g.size.width) { app.openTitle(s) } }
                                .aspectRatio(2 / 3, contentMode: .fit)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                default:
                    VStack(spacing: 0) {
                        ForEach(model.airings) { s in ChannelLine(showing: s, favorite: false) { app.openShowing(s) } }
                    }
                }
            }
        }
    }

    private func episodeRow(_ d: TmdbDetails, _ e: TmdbEpisode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                CardButton(action: { app.play(request(d, e)) }, onLong: { episodeMenu(d, e) }) {
                    HStack(spacing: 12) {
                        still(e, 124)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(e.episodeNumber). \(e.name ?? "Episodio \(e.episodeNumber)")").font(NxFont.ui(14, .bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                            if let r = e.runtime { Text("\(r) min").font(NxFont.caption).foregroundStyle(NxColor.textDim) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                DownloadButton(request: PlayRequest(details: d, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name))
            }
            if let o = e.overview?.nilIfBlank { Text(o).font(NxFont.ui(12, .medium)).foregroundStyle(NxColor.textMuted).lineLimit(3) }
        }
    }
    #else
    @ViewBuilder private func page(_ d: TmdbDetails) -> some View {
        let t = d.toTitle()
        let last = model.progress.first
        ZStack(alignment: .topLeading) {
            NxImage(url: Img.tmdb(d.bestBackdrop ?? d.posterPath, "w1280"), maxPixel: 1920, alignment: .top) { NxColor.bg }
                .frame(width: 1240, height: 698).overlay(NxColor.heroScrim).overlay(NxColor.heroFade)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let logo = Img.tmdb(d.logoPath, "w500") {
                            NxImage(url: logo, fit: true, maxPixel: 800, alignment: .bottomLeading) { Text(d.displayTitle).font(NxFont.display(34, .heavy)).foregroundStyle(.white) }
                                .frame(maxWidth: 520, maxHeight: 170, alignment: .bottomLeading)
                        } else { Text(d.displayTitle).font(NxFont.display(34, .heavy)).foregroundStyle(.white).lineLimit(2) }
                        metaLine(d)
                        if let o = d.overview?.nilIfBlank { Text(o).font(NxFont.ui(14, .medium)).foregroundStyle(.white).lineLimit(4).frame(maxWidth: 820, alignment: .leading) }
                        VStack(alignment: .leading, spacing: 4) { credits(d) }.frame(maxWidth: 820, alignment: .leading)
                        if let l = last, !l.completed, l.durationMs > 0 {
                            HStack(spacing: 14) {
                                NxProgressBar(value: Double(l.positionMs) / Double(l.durationMs)).frame(width: 360)
                                Text("mancano \(max(1, Int((l.durationMs - l.positionMs) / Clock.minute))) min").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                            }
                        }
                        HStack(spacing: 18) {
                            NxButton(resumeLabel(d), icon: "play.fill", kind: .primary) { app.playTitle(d) }
                            secondary(d, t)
                        }
                        .padding(.top, 8)
                        .focusSection()
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.top, 90)
                    if d.isTv {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 20) { Text("Episodi").font(NxFont.rowTitle).foregroundStyle(.white); seasonPill(d) }.padding(.horizontal, Metrics.gutter).focusSection()
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: Metrics.cardGap) { ForEach(model.episodes) { e in episodeCard(d, e) } }
                                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 22)
                            }
                            .scrollClipDisabled().focusSection()
                        }
                    }
                    if !model.airings.isEmpty {
                        CardRow(title: "In TV nei prossimi giorni", items: model.airings) { s in
                            ShowCard(showing: s, style: .compact, reminder: store.reminders.contains(s.channel.streamId)) { app.openShowing(s) }
                        }
                    }
                    if model.similar.count >= 4 { VodRowView(row: VodRow(id: "similar", title: "Titoli simili", items: model.similar)) }
                    Color.clear.frame(height: 60)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func episodeCard(_ d: TmdbDetails, _ e: TmdbEpisode) -> some View {
        let w = Metrics.showCardW * 0.9
        return VStack(alignment: .leading, spacing: 10) {
            CardButton(action: { app.play(request(d, e)) }) { still(e, w) }
            Text("\(e.episodeNumber). \(e.name ?? "Episodio \(e.episodeNumber)")").font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.text).lineLimit(1)
            Text(e.overview ?? " ").font(NxFont.ui(11, .medium)).foregroundStyle(NxColor.textDim).lineLimit(3)
        }
        .frame(width: w, alignment: .leading)
    }
    #endif
}
