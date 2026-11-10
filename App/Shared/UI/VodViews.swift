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
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: VodHomeModel

    init(media: String, pid: Int64, kids: Bool) {
        self.media = media
        _model = StateObject(wrappedValue: VodHomeModel(media: media, pid: pid, kids: kids))
    }

    var body: some View {
        Group {
            if model.state.rows.isEmpty && model.state.carousel.isEmpty {
                BrandLoader(label: media == "tv" ? "Carico le serie TV…" : "Carico i film…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                        if !model.state.carousel.isEmpty { HeroCarousel(items: model.state.carousel) }
                        if !model.genres.isEmpty { genreStrip }
                        ForEach(model.state.rows) { row in
                            if case .vod(_, let title, let r, let overlays, let sub, let tag) = row { VodRowView(row: r, overlays: overlays, tag: tag, sub: sub, title: title) }
                        }
                        Color.clear.frame(height: 1).onAppear { model.loadMore() }
                        Color.clear.frame(height: Metrics.u(24))
                    }
                }
                #if os(iOS)
                .ignoresSafeArea(edges: .top)
                #endif
            }
        }
        .nxPage()
        .onAppear { model.start(); model.refreshPersonal(listKeys: store.listKeys) }
        .onChange(of: store.listKeys) { _, k in model.refreshPersonal(listKeys: k) }
    }

    private var genreStrip: some View {
        VStack(alignment: .leading, spacing: Metrics.u(8)) {
            SectionHeader(title: "Sfoglia per genere")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.u(8)) {
                    ForEach(model.genres, id: \.0) { g in NxChip(title: g.1, selected: false) { app.open(.genre(media, g.0, g.1)) } }
                }
                .padding(.horizontal, Metrics.gutter)
                #if os(tvOS)
                .padding(.vertical, 14)
                #endif
            }
            .scrollClipDisabled()
        }
    }
}

/// "Sfoglia per genere": the rows of one genre.
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
        .nxPage()
        .nxTitle((media == "tv" ? "Serie TV · " : "Film · ") + name)
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

/// The page of a film or a series: what it is, the one button to play it from where it was left, episodes, where it is on
/// TV in the next days, similar titles.
struct TitleDetailView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: TitleDetailModel
    @State private var more = false

    init(media: String, tmdbId: Int) { _model = StateObject(wrappedValue: TitleDetailModel(media: media, id: tmdbId)) }

    var body: some View {
        Group {
            if let d = model.details { page(d) }
            else if model.failed { StateMessage(icon: "wifi.exclamationmark", title: "Non riesco a caricare questo titolo", text: "Controlla la connessione e riprova.") }
            else { BrandLoader().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .nxPage()
        .task { await model.load(pid: app.pid, kids: app.kids) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
    }

    private func resumeLabel(_ d: TmdbDetails) -> String {
        let last = model.progress.first
        if !d.isTv { return (last != nil && !last!.completed && last!.positionMs > 60_000) ? "Riprendi" : "Riproduci" }
        guard let l = last else { return "Riproduci S1 E1" }
        return l.completed ? "Riproduci S\(l.season) E\(l.episode + 1)" : "Riprendi S\(l.season) E\(l.episode)"
    }

    @ViewBuilder private func page(_ d: TmdbDetails) -> some View {
        let t = d.toTitle()
        let inList = store.listKeys.contains(t.key)
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Metrics.u(18)) {
                ZStack(alignment: .bottomLeading) {
                    NxImage(url: Img.tmdb(d.bestBackdrop ?? d.posterPath, "w1280"), maxPixel: Metrics.tv ? 1920 : 1400, alignment: .top) { NxColor.ink2 }
                        .frame(maxWidth: .infinity).frame(height: Metrics.tv ? 600 : 300).clipped()
                    #if os(tvOS)
                    NxColor.heroScrim
                    #endif
                    NxColor.heroFade
                    VStack(alignment: .leading, spacing: Metrics.u(8)) {
                        if let logo = Img.tmdb(d.logoPath, "w500") {
                            NxImage(url: logo, fit: true, maxPixel: 700, alignment: .bottomLeading) { Text(d.displayTitle).font(NxFont.hero).foregroundStyle(.white) }
                                .frame(maxWidth: Metrics.u(240), maxHeight: Metrics.u(80), alignment: .bottomLeading)
                        } else { Text(d.displayTitle).font(NxFont.hero).foregroundStyle(.white).lineLimit(3) }
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.bottom, Metrics.u(6))
                }
                VStack(alignment: .leading, spacing: Metrics.u(10)) {
                    HStack(spacing: Metrics.u(8)) {
                        if model.match > 0 { Text("\(model.match)% per te").font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.success) }
                        if d.year > 0 { Text(String(d.year)).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                        if let c = d.certification { NxTag(text: c) }
                        if d.isTv { Text("\(d.numberOfSeasons) stagion\(d.numberOfSeasons == 1 ? "e" : "i") · \(d.numberOfEpisodes) episodi").font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                        else if d.runtimeMin > 0 { Text(TimeText.duration(minutes: d.runtimeMin)).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                        if d.voteAverage > 0 { Text(String(format: "★ %.1f", d.voteAverage)).font(NxFont.meta).foregroundStyle(NxColor.gold) }
                    }
                    actions(d, t, inList)
                    if let l = model.progress.first, !l.completed, l.durationMs > 0 {
                        HStack(spacing: Metrics.u(8)) {
                            NxProgressBar(value: Double(l.positionMs) / Double(l.durationMs)).frame(maxWidth: Metrics.u(200))
                            Text("mancano \(max(1, Int((l.durationMs - l.positionMs) / Clock.minute))) min").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                        }
                    }
                    if let tag = d.tagline?.nilIfBlank { Text(tag).font(NxFont.bodyStrong).foregroundStyle(NxColor.text) }
                    if let o = d.overview?.nilIfBlank {
                        Text(o).font(NxFont.body).foregroundStyle(NxColor.textMuted).lineLimit(more ? nil : 4)
                        #if os(iOS)
                        if !more && o.count > 180 { Button("Altro") { more = true }.font(NxFont.label).foregroundStyle(NxColor.text).buttonStyle(.plain) }
                        #endif
                    }
                    Text(d.genres.map { $0.name }.joined(separator: " · ")).font(NxFont.caption).foregroundStyle(NxColor.textDim)
                    if !d.cast.isEmpty { Text("Con " + d.cast.prefix(more ? 12 : 5).map { $0.name }.joined(separator: ", ")).font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(2) }
                    if let dir = d.directors.first ?? d.createdBy?.first { Text((d.isTv ? "Creata da " : "Regia di ") + dir.name).font(NxFont.caption).foregroundStyle(NxColor.textDim) }
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(maxWidth: Metrics.tv ? 1200 : .infinity, alignment: .leading)

                if d.isTv { episodesSection(d) }
                if !model.airings.isEmpty {
                    CardRow(title: "In TV nei prossimi giorni", items: model.airings) { s in
                        ShowCard(showing: s, style: .compact, reminder: store.reminders.contains(s.channel.streamId),
                                 onTap: { app.openShowing(s) }, onPlay: { app.play(s.channel) }, onReminder: { app.toggleReminder(s) })
                    }
                }
                if model.similar.count >= 4 { VodRowView(row: VodRow(id: "similar", title: "Titoli simili", items: model.similar)) }
                Color.clear.frame(height: Metrics.u(30))
            }
        }
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }

    @ViewBuilder private func actions(_ d: TmdbDetails, _ t: TmdbTitle, _ inList: Bool) -> some View {
        let last = model.progress.first
        let row1 = HStack(spacing: Metrics.u(10)) {
            NxButton(resumeLabel(d), icon: "play.fill", kind: .primary, wide: !Metrics.tv) { app.playTitle(d) }
            #if os(tvOS)
            if last != nil { NxButton("Ricomincia", icon: "arrow.counterclockwise") { restart(d) } }
            #endif
        }
        let row2 = HStack(spacing: Metrics.u(10)) {
            #if os(iOS)
            if last != nil { NxIconButton(icon: "arrow.counterclockwise", label: "Ricomincia") { restart(d) } }
            #endif
            NxIconButton(icon: inList ? "bookmark.fill" : "bookmark", label: "Da guardare", active: inList) { app.toggleList(t) }
            NxIconButton(icon: model.feedback == "liked" ? "hand.thumbsup.fill" : "hand.thumbsup", label: "Mi piace", active: model.feedback == "liked") {
                app.core.library.setFeedback(app.pid, d.id, d.media, current: model.feedback, want: "liked")
            }
            NxIconButton(icon: model.feedback == "disliked" ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Non mi piace", active: model.feedback == "disliked") {
                app.core.library.setFeedback(app.pid, d.id, d.media, current: model.feedback, want: "disliked")
            }
            if !d.isTv {
                NxIconButton(icon: last?.completed == true ? "checkmark.circle.fill" : "checkmark.circle", label: "Segna come visto", active: last?.completed == true) {
                    if last?.completed == true { app.core.library.clearProgress(app.pid, d.id, d.media) }
                    else { app.core.library.markWatched(app.pid, d.id, d.media, season: 0, episode: 0, runtimeMin: d.runtimeMin) }
                }
            }
            #if os(iOS)
            if !d.isTv { DownloadButton(request: PlayRequest(details: d)) }
            #endif
            Spacer(minLength: 0)
        }
        if Metrics.tv { HStack(spacing: Metrics.u(10)) { row1; row2 } } else { VStack(alignment: .leading, spacing: Metrics.u(10)) { row1; row2 } }
    }

    private func restart(_ d: TmdbDetails) {
        if d.isTv { app.play(PlayRequest(details: d, season: 1, episode: 1)) } else { app.play(PlayRequest(details: d, startMs: 0)) }
    }

    @ViewBuilder private func episodesSection(_ d: TmdbDetails) -> some View {
        let seasons = d.seasons.filter { $0.seasonNumber > 0 }
        VStack(alignment: .leading, spacing: Metrics.u(10)) {
            SectionHeader(title: "Episodi")
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.u(8)) {
                        ForEach(seasons, id: \.seasonNumber) { s in
                            NxChip(title: "Stagione \(s.seasonNumber)", selected: model.season == s.seasonNumber) { Task { await model.loadSeason(s.seasonNumber) } }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    #if os(tvOS)
                    .padding(.vertical, 14)
                    #endif
                }
                .scrollClipDisabled()
            }
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.cardGap) { ForEach(model.episodes) { e in episodeCard(d, e) } }
                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 28)
            }
            .scrollClipDisabled().focusSection()
            #else
            LazyVStack(spacing: 10) { ForEach(model.episodes) { e in episodeRow(d, e) } }.padding(.horizontal, Metrics.gutter)
            #endif
        }
    }

    private func request(_ d: TmdbDetails, _ e: TmdbEpisode) -> PlayRequest {
        let p = model.progress(for: e)
        return PlayRequest(details: d, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name, startMs: (p != nil && !p!.completed) ? p!.positionMs : 0)
    }

    @ViewBuilder private func episodeMenu(_ d: TmdbDetails, _ e: TmdbEpisode) -> some View {
        let done = model.progress(for: e)?.completed == true
        Button {
            if done { app.core.library.markUnwatched(app.pid, d.id, d.media, season: e.seasonNumber, episode: e.episodeNumber) }
            else { app.core.library.markWatched(app.pid, d.id, d.media, season: e.seasonNumber, episode: e.episodeNumber, runtimeMin: e.runtime ?? d.runtimeMin) }
        } label: { Label(done ? "Segna come non visto" : "Segna come visto", systemImage: done ? "circle" : "checkmark.circle") }
    }

    private func still(_ e: TmdbEpisode, _ w: CGFloat) -> some View {
        let p = model.progress(for: e)
        return ZStack(alignment: .bottomLeading) {
            NxImage(url: Img.tmdb(e.stillPath, "w300"), maxPixel: 500) { NxColor.ink3 }
            NxColor.cardFade.opacity(0.7)
            VStack(alignment: .leading, spacing: Metrics.u(4)) {
                HStack {
                    Spacer()
                    if p?.completed == true { Image(systemName: "checkmark.circle.fill").font(.system(size: 14 * Metrics.type)).foregroundStyle(.white) }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Text("\(e.episodeNumber)").font(NxFont.display(18, .bold)).foregroundStyle(.white)
                    Spacer()
                    if let r = e.runtime { Text("\(r) min").font(NxFont.caption).foregroundStyle(NxColor.textMuted) }
                }
                if let pr = p, !pr.completed, pr.durationMs > 0 { NxProgressBar(value: Double(pr.positionMs) / Double(pr.durationMs)) }
            }
            .padding(Metrics.u(7))
        }
        .frame(width: w, height: w * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius * 0.8, style: .continuous))
    }

    private func episodeCard(_ d: TmdbDetails, _ e: TmdbEpisode) -> some View {
        let w = Metrics.showCardW * 0.9
        return CardButton(action: { app.play(request(d, e)) }) {
            VStack(alignment: .leading, spacing: 8) {
                still(e, w)
                Text(e.name ?? "Episodio \(e.episodeNumber)").font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.text).lineLimit(1)
                Text(e.overview ?? " ").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(3)
            }
            .frame(width: w, alignment: .leading).padding(12)
        }
        .contextMenu { episodeMenu(d, e) }
    }

    private func episodeRow(_ d: TmdbDetails, _ e: TmdbEpisode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { app.play(request(d, e)) } label: {
                HStack(alignment: .top, spacing: 12) {
                    still(e, 132)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.name ?? "Episodio \(e.episodeNumber)").font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.text).lineLimit(2).multilineTextAlignment(.leading)
                        Text(e.overview ?? "").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(PressScaleStyle())
            #if os(iOS)
            DownloadButton(request: PlayRequest(details: d, season: e.seasonNumber, episode: e.episodeNumber, episodeTitle: e.name), compact: true)
            #endif
        }
        .contextMenu { episodeMenu(d, e) }
    }
}
