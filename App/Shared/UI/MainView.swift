import SwiftUI

/// The app past the gates: the sections in a Liquid Glass tab bar on iPhone, in the sidebar on Apple TV.
struct MainView: View {
    let profile: ProfileEntity
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    var body: some View {
        #if os(tvOS)
        TabView(selection: sectionBinding) {
            Tab(AppSection.search.label, systemImage: AppSection.search.icon, value: AppSection.search) { stack(.search) { SearchView() } }
            Tab(AppSection.home.label, systemImage: AppSection.home.icon, value: AppSection.home) { stack(.home) { HomeView(pid: profile.id, kids: profile.kids) } }
            Tab(AppSection.live.label, systemImage: AppSection.live.icon, value: AppSection.live) { stack(.live) { LiveView() } }
            Tab(AppSection.guide.label, systemImage: AppSection.guide.icon, value: AppSection.guide) { stack(.guide) { GuideView() } }
            Tab(AppSection.movies.label, systemImage: AppSection.movies.icon, value: AppSection.movies) { stack(.movies) { VodHomeView(media: "movie", pid: profile.id, kids: profile.kids) } }
            Tab(AppSection.series.label, systemImage: AppSection.series.icon, value: AppSection.series) { stack(.series) { VodHomeView(media: "tv", pid: profile.id, kids: profile.kids) } }
            Tab(AppSection.mine.label, systemImage: AppSection.mine.icon, value: AppSection.mine) { stack(.mine) { MineView(pid: profile.id, kids: profile.kids) } }
            Tab(AppSection.settings.label, systemImage: AppSection.settings.icon, value: AppSection.settings) { stack(.settings) { SettingsView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        #else
        TabView(selection: sectionBinding) {
            Tab(AppSection.home.label, systemImage: AppSection.home.icon, value: AppSection.home) { stack(.home) { HomeView(pid: profile.id, kids: profile.kids) } }
            Tab(AppSection.live.label, systemImage: AppSection.live.icon, value: AppSection.live) { stack(.live) { LiveView() } }
            Tab(AppSection.guide.label, systemImage: AppSection.guide.icon, value: AppSection.guide) { stack(.guide) { GuideView() } }
            Tab("Film e serie", systemImage: AppSection.movies.icon, value: AppSection.movies) { stack(.movies) { VodTabView(pid: profile.id, kids: profile.kids) } }
            Tab(AppSection.mine.label, systemImage: AppSection.mine.icon, value: AppSection.mine) { stack(.mine) { MineView(pid: profile.id, kids: profile.kids) } }
            Tab(value: AppSection.search, role: .search) { stack(.search) { SearchView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }

    /// Tapping the tab already in view goes back to its first page, then to the top.
    private var sectionBinding: Binding<AppSection> {
        Binding(get: { app.section }, set: { s in
            if s == app.section {
                if !(app.paths[s] ?? []).isEmpty { app.paths[s] = [] } else { app.reselect += 1 }
            } else { app.section = s }
        })
    }

    private func stack<Root: View>(_ s: AppSection, @ViewBuilder _ root: () -> Root) -> some View {
        NavigationStack(path: app.path(s)) {
            root()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Image("BrandSymbol").resizable().scaledToFit().frame(width: 26, height: 26).accessibilityLabel("NexStream")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { app.open(.settings) } label: { profile.face(30) }.accessibilityLabel("Impostazioni e profilo")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }
}

/// The page behind a route.
struct RouteView: View {
    let route: Route
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch route {
        case .programme(let channelId, let programmeId): ProgrammeDetailView(channelId: channelId, programmeId: programmeId)
        case .title(let media, let id): TitleDetailView(media: media, tmdbId: id)
        case .genre(let media, let id, let name): GenreView(media: media, genreId: id, name: name)
        case .teams: TeamsView()
        case .manageProfiles: ProfilesView(manage: true) { app.core.profiles.refresh(); app.pop() }
        case .transfer: TransferView()
        case .remote: RemoteView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }
}

#if os(iOS)
/// iPhone: Film and Serie TV share one tab, with a switch on top.
struct VodTabView: View {
    let pid: Int64
    let kids: Bool
    @EnvironmentObject var app: AppModel
    @State private var media = "movie"

    var body: some View {
        ZStack {
            if media == "movie" { VodHomeView(media: "movie", pid: pid, kids: kids) } else { VodHomeView(media: "tv", pid: pid, kids: kids) }
        }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $media) {
                Text("Film").tag("movie")
                Text("Serie TV").tag("tv")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .padding(.vertical, 6)
        }
    }
}
#endif

// ---------------------------------------------------------------------------------------------------------------- Canali

/// "Canali": every channel of the line by genre, each tile showing what is on.
struct LiveView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var genre: String = "all"

    private var shown: [ChannelEntity] {
        switch genre {
        case "all": return store.channels
        case "fav": return store.channels.filter { store.favorites.contains($0.streamId) }
        default: return store.byCategory(genre)
        }
    }

    var body: some View {
        Group {
            if store.channels.isEmpty {
                if app.syncStatus != nil || !store.loaded { BrandLoader(label: app.syncStatus ?? "Carico i canali…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { StateMessage(icon: "tv", title: "Nessun canale", text: "Controlla la connessione (VPN) e aggiorna dalle impostazioni.", actionTitle: "Aggiorna ora") { app.core.syncIfNeeded(force: true) } }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Metrics.u(14)) {
                        GenreChips(selected: $genre, favorites: !store.favorites.isEmpty)
                        let list = shown
                        if list.isEmpty { StateMessage(icon: "star", title: "Nessun canale qui", text: "Tieni premuto su un canale per aggiungerlo ai preferiti.").frame(height: Metrics.u(260)) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.channelCardW * (Metrics.tv ? 1 : 0.84)), spacing: Metrics.cardGap)], alignment: .leading, spacing: Metrics.u(Metrics.tv ? 24 : 14)) {
                            ForEach(list) { c in
                                ChannelCard(showing: store.showing(c), favorite: store.favorites.contains(c.streamId),
                                            onTap: { app.play(c, ids: list.map { $0.streamId }) },
                                            onInfo: { app.openShowing(store.showing(c)) }, onFavorite: { app.toggleFavorite(c) })
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        Color.clear.frame(height: Metrics.u(20))
                    }
                    .padding(.top, Metrics.u(8))
                }
            }
        }
        .nxPage()
        .navigationTitle("Canali")
    }
}

/// Genre filter shared by Canali and Guida TV.
struct GenreChips: View {
    @Binding var selected: String
    var favorites = false
    @EnvironmentObject var store: LiveStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.u(8)) {
                NxChip(title: "Tutti", selected: selected == "all") { selected = "all" }
                if favorites { NxChip(title: "Preferiti", icon: "star.fill", selected: selected == "fav") { selected = "fav" } }
                ForEach(store.categories, id: \.id) { g in NxChip(title: g.label, selected: selected == g.id) { selected = g.id } }
            }
            .padding(.horizontal, Metrics.gutter)
            #if os(tvOS)
            .padding(.vertical, 14)
            #endif
        }
        .scrollClipDisabled()
    }
}

// ---------------------------------------------------------------------------------------------------------------- Guida TV

/// "Guida TV": for every channel what is on from the chosen moment on. The programme on air plays the channel, the
/// others open their page (reminder, replicas, the same title on demand).
struct GuideView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var genre = "all"
    @State private var day = 0
    @State private var slot = "now"
    @State private var byEpg: [String: [ProgrammeEntity]] = [:]
    @State private var loading = true

    private static let slots: [(String, String, Int)] = [("now", "Adesso", -1), ("morning", "Mattina", 7), ("noon", "Pomeriggio", 13), ("evening", "Sera", 19), ("prime", "Prima serata", 21), ("night", "Notte", 23)]

    private var from: Millis {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: Date())) ?? Date()
        let hour = GuideView.slots.first { $0.0 == slot }?.2 ?? -1
        if hour < 0 { return day == 0 ? Clock.now : base.ms + 6 * Clock.hour }
        return (cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base).ms
    }
    private var shownChannels: [ChannelEntity] {
        let l: [ChannelEntity]
        switch genre {
        case "all": l = store.channels
        case "fav": l = store.channels.filter { store.favorites.contains($0.streamId) }
        default: l = store.byCategory(genre)
        }
        return l.filter { $0.epgId != nil || $0.event != nil }
    }

    var body: some View {
        let chans = shownChannels
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Metrics.u(Metrics.tv ? 8 : 12)) {
                controls
                if chans.isEmpty && !loading { StateMessage(icon: "calendar", title: "Nessuna guida disponibile", text: app.syncStatus ?? "La guida si aggiorna da sola ogni 6 ore.").frame(height: Metrics.u(280)) }
                ForEach(chans) { c in GuideRow(channel: c, programmes: c.epgId.flatMap { byEpg[$0] } ?? [], from: from) }
                Color.clear.frame(height: Metrics.u(20))
            }
            .padding(.top, Metrics.u(8))
        }
        .nxPage()
        .navigationTitle("Guida TV")
        .task(id: "\(genre)-\(day)-\(slot)-\(store.channels.count)") { await load() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Metrics.u(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.u(8)) {
                    ForEach(0..<5, id: \.self) { d in
                        NxChip(title: dayTitle(d), selected: day == d) { day = d; if d > 0 && slot == "now" { slot = "prime" } }
                    }
                    Rectangle().fill(NxColor.hairline).frame(width: 1, height: Metrics.u(22))
                    ForEach(GuideView.slots, id: \.0) { s in
                        if !(s.0 == "now" && day > 0) { NxChip(title: s.1, selected: slot == s.0) { slot = s.0 } }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                #if os(tvOS)
                .padding(.vertical, 14)
                #endif
            }
            .scrollClipDisabled()
            GenreChips(selected: $genre, favorites: !store.favorites.isEmpty)
        }
    }

    private func dayTitle(_ d: Int) -> String {
        if d == 0 { return "Oggi" }
        if d == 1 { return "Domani" }
        let date = Calendar.current.date(byAdding: .day, value: d, to: Date()) ?? Date()
        return TimeText.dayLabel(date.ms) ?? "+\(d)"
    }

    private func load() async {
        loading = true
        let ids = shownChannels.compactMap { $0.epgId }
        let f = from
        let db = app.core.db
        let list = await Task.detached(priority: .userInitiated) { db.programmesForChannels(ids, f, f + 8 * Clock.hour) }.value
        if Task.isCancelled { return }
        byEpg = list.grouped { $0.epgId }
        loading = false
    }
}

/// One channel of the guide: its logo, then the programmes from the chosen moment, the one on air first.
struct GuideRow: View {
    let channel: ChannelEntity
    let programmes: [ProgrammeEntity]
    let from: Millis
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    #if os(tvOS)
    private let cellW: CGFloat = 400, cellH: CGFloat = 132, headW: CGFloat = 230
    #else
    private let cellW: CGFloat = 196, cellH: CGFloat = 74, headW: CGFloat = 78
    #endif

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.u(8)) {
            Button { app.play(channel) } label: {
                VStack(spacing: Metrics.u(4)) {
                    ChannelLogo(channel: channel, height: Metrics.tv ? 26 : 24).frame(maxWidth: headW - 12, alignment: .center)
                    Text(channel.num > 0 ? "\(channel.num)" : "").font(NxFont.label).foregroundStyle(NxColor.textDim)
                }
                .frame(width: headW, height: cellH)
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(PressScaleStyle())
            #endif
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.u(8)) {
                    if programmes.isEmpty {
                        cell(title: channel.event ?? "Nessuna informazione", time: channel.eventStart.map { TimeText.time($0) } ?? "", sub: channel.eventSub, onAir: channel.event != nil, progress: nil) { app.play(channel) }
                    }
                    ForEach(programmes) { p in
                        let s = store.showing(channel, p)
                        cell(title: s.cardTitle, time: TimeText.time(p.start), sub: s.cardLine, onAir: s.isLive(), progress: s.isLive() ? s.progress() : nil) {
                            if s.isLive() { app.play(channel) } else { app.openShowing(s) }
                        }
                        .contextMenu {
                            Button { app.openShowing(s) } label: { Label("Dettagli", systemImage: "info.circle") }
                            if !s.isLive() && p.start > Clock.now { Button { app.toggleReminder(s) } label: { Label("Avvisami quando inizia", systemImage: "bell") } }
                        }
                    }
                }
                .padding(.trailing, Metrics.gutter)
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
            .scrollClipDisabled()
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(.leading, Metrics.gutter)
    }

    private func cell(title: String, time: String, sub: String?, onAir: Bool, progress: Double?, action: @escaping () -> Void) -> some View {
        CardButton(action: action) {
            VStack(alignment: .leading, spacing: Metrics.u(3)) {
                HStack(spacing: Metrics.u(6)) {
                    Text(time).font(NxFont.ui(12, .bold)).foregroundStyle(onAir ? NxColor.accentBright : NxColor.textDim)
                    if onAir { NxTag(text: "In onda", color: NxColor.accent) }
                    Spacer(minLength: 0)
                }
                Text(title).font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.text).lineLimit(1)
                Text(sub ?? " ").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1)
                Spacer(minLength: 0)
                if let p = progress { NxProgressBar(value: p) }
            }
            .padding(Metrics.u(9))
            .frame(width: cellW, height: cellH, alignment: .topLeading)
            .background(onAir ? NxColor.ink3 : NxColor.ink2)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius * 0.8, style: .continuous))
        }
    }
}
