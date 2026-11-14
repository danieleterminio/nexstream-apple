import SwiftUI

/// One search over everything: channels, what is on TV in the next days, films and series on demand.
struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var query = ""
    @State private var channels: [ChannelEntity] = []
    @State private var programmes: [Showing] = []
    @State private var titles: [TmdbTitle] = []
    @State private var searching = false
    @State private var suggestions: [TmdbTitle] = []
    @FocusState private var typing: Bool

    var body: some View {
        Group {
            #if os(tvOS)
            HStack(alignment: .top, spacing: 0) {
                keyboard.frame(width: 560).padding(.top, 60).padding(.leading, Metrics.gutter)
                results.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea(edges: [.bottom, .trailing])
            #else
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { app.pop() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).frame(width: 40, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(NxPlainStyle(scale: 0.9))
                    .accessibilityLabel("Indietro")
                    NxField(icon: "magnifyingglass") {
                        TextField("", text: $query, prompt: Text("Canali, programmi, film e serie").foregroundColor(NxColor.textDim))
                            .autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search).focused($typing)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(NxColor.textDim) }.buttonStyle(NxPlainStyle(scale: 0.9))
                        }
                    }
                    .padding(.trailing, Metrics.gutter)
                }
                .padding(.vertical, 4)
                results
            }
            .onAppear { if query.isEmpty { typing = true } }
            #endif
        }
        .nxPage()
        .task(id: query) { await run(query.trimmed) }
        .task {
            if suggestions.isEmpty { suggestions = await app.core.catalog.heroCandidates(app.kids) + ((try? await app.core.tmdb.popular("tv")) ?? []).prefix(10) }
        }
        .onAppear { if let q = app.pendingSearch { query = q; app.pendingSearch = nil } }
        .onChange(of: app.pendingSearch) { _, q in if let q = q { query = q; app.pendingSearch = nil } }
    }

    private var results: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                let q = query.trimmed
                if q.count < 2 {
                    if !suggestions.isEmpty {
                        #if os(iOS)
                        VStack(alignment: .leading, spacing: 4) {
                            SectionHeader(title: "Film e serie consigliati").padding(.bottom, 6)
                            ForEach(suggestions.prefix(14)) { t in titleLine(t) }
                        }
                        #else
                        VodRowView(row: VodRow(id: "sugg", title: "Film e serie consigliati", items: suggestions))
                        #endif
                    } else { StateMessage(icon: "magnifyingglass", title: "Cerca un canale, un programma, un film o una serie").frame(height: Metrics.u(300)) }
                } else if channels.isEmpty && programmes.isEmpty && titles.isEmpty {
                    if searching { BrandLoader(label: "Cerco “\(q)”…").frame(maxWidth: .infinity).frame(height: Metrics.u(300)) }
                    else { StateMessage(icon: "magnifyingglass", title: "Nessun risultato per “\(q)”", text: "Prova con un'altra parola o con il titolo originale.").frame(height: Metrics.u(300)) }
                } else {
                    if !channels.isEmpty {
                        CardRow(title: "Canali", items: channels) { c in
                            ChannelCard(showing: store.showing(c), favorite: store.favorites.contains(c.streamId)) { app.play(c) }
                        }
                    }
                    if !programmes.isEmpty {
                        CardRow(title: "In TV", sub: "in onda e nei prossimi giorni", items: programmes) { s in
                            ShowCard(showing: s, style: .compact, reminder: store.reminders.contains(s.channel.streamId)) { app.openShowing(s) }
                        }
                    }
                    if !titles.isEmpty {
                        #if os(iOS)
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Film e serie")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Metrics.posterColumns), spacing: 8) {
                                ForEach(titles) { t in
                                    GeometryReader { g in PosterCard(title: t, inList: store.listKeys.contains(t.key), width: g.size.width) { app.openTitle(t) } }.aspectRatio(2 / 3, contentMode: .fit)
                                }
                            }
                            .padding(.horizontal, Metrics.gutter)
                        }
                        #else
                        VodRowView(row: VodRow(id: "search-vod", title: "Film e serie", items: titles))
                        #endif
                    }
                }
                Color.clear.frame(height: Metrics.u(20))
            }
            .padding(.top, Metrics.u(Metrics.tv ? 30 : 8))
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
    }

    #if os(iOS)
    private func titleLine(_ t: TmdbTitle) -> some View {
        CardButton(action: { app.openTitle(t) }, radius: 0) {
            HStack(spacing: 12) {
                NxImage(url: Img.tmdb(t.backdropPath ?? t.posterPath, "w300"), maxPixel: 500) { NxColor.ink3 }
                    .frame(width: 132, height: 74).clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                Text(t.displayTitle).font(NxFont.ui(15, .bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "play.circle").font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            }
            .padding(.horizontal, Metrics.gutter).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
    }
    #else
    /// Our own keyboard on the TV: a grid of letters beside the results, like the big streaming apps.
    private var keyboard: some View {
        let keys = Array("abcdefghijklmnopqrstuvwxyz1234567890").map { String($0) }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .semibold)).foregroundStyle(NxColor.textDim)
                Text(query.isEmpty ? "Cerca" : query).font(NxFont.display(20, .bold)).foregroundStyle(query.isEmpty ? NxColor.textDim : .white).lineLimit(1)
            }
            .frame(height: 70)
            HStack(spacing: 10) {
                key(wide: true) { Label("Spazio", systemImage: "space") } action: { if !query.isEmpty { query += " " } }
                key(wide: true) { Label("Cancella", systemImage: "delete.left") } action: { if !query.isEmpty { query.removeLast() } }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
                ForEach(keys, id: \.self) { k in key(wide: false) { Text(k) } action: { query += k } }
            }
            key(wide: true) { Label("Svuota", systemImage: "xmark") } action: { query = "" }
        }
        .focusSection()
    }

    private func key<L: View>(wide: Bool, @ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        let l = label()
        return Button(action: action) {
            Focusable { focused in
                l.labelStyle(.titleAndIcon).font(NxFont.ui(wide ? 13 : 17, .bold))
                    .foregroundStyle(focused ? Color.black : Color.white)
                    .frame(width: wide ? 248 : 76, height: 66)
                    .background(focused ? Color.white : NxColor.ink3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .scaleEffect(focused ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: focused)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 1))
    }
    #endif

    private func run(_ q: String) async {
        guard q.count >= 2 else { channels = []; programmes = []; titles = []; searching = false; return }
        searching = true
        // channels and on-demand titles from the device at once; the guide and TMDB after a short pause in typing
        let n = MetaText.norm(q)
        channels = store.channels.filter { MetaText.norm($0.name).contains(n) || String($0.num) == q || ($0.event.map { MetaText.norm($0).contains(n) } ?? false) }.prefix(24).map { $0 }
        titles = app.core.catalog.searchLocal(q, app.kids)
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let core = app.core
        let now = Clock.now
        let visible = store.channels
        let metas = store.metas
        let found: [Showing] = await Task.detached {
            var byEpg = [String: ChannelEntity]()
            for c in visible where c.shiftMin == 0 { if let e = c.epgId, byEpg[e] == nil { byEpg[e] = c } }
            var seen = Set<String>(); var out = [Showing]()
            for p in core.db.searchProgrammes("\(q)%", "% \(q)%", from: now, to: now + 4 * Clock.day) {
                guard let c = byEpg[p.epgId], core.channels.allowedProgramme(c, p) else { continue }
                let key = p.title + "|" + c.streamId
                if !seen.insert(key).inserted { continue }
                out.append(Showing(channel: c, programme: p, meta: metas[core.meta.keyOf(p)]))
                if out.count >= 30 { break }
            }
            return out
        }.value
        if Task.isCancelled { return }
        programmes = found
        let remote = await core.catalog.search(q, app.kids)
        if Task.isCancelled { return }
        titles = remote
        searching = false
    }
}

// ---------------------------------------------------------------------------------------------------------------- settings

/// One line of the settings: a symbol, what it is, and on the right its value, a switch or an arrow.
struct SettingRow: View {
    let icon: String
    let title: String
    var sub: String? = nil
    var value: String? = nil
    var on: Bool? = nil
    var destructive = false
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focusable { focused in
                HStack(spacing: Metrics.u(13)) {
                    Image(systemName: icon).font(.system(size: 17 * Metrics.unit, weight: .medium)).frame(width: Metrics.u(26))
                        .foregroundStyle(focused ? Color.black : (destructive ? NxColor.accentBright : NxColor.textMuted))
                    VStack(alignment: .leading, spacing: Metrics.u(2)) {
                        Text(title).font(NxFont.ui(15, .bold)).foregroundStyle(focused ? Color.black : (destructive ? NxColor.accentBright : Color.white)).multilineTextAlignment(.leading)
                        if let s = sub { Text(s).font(NxFont.caption).foregroundStyle(focused ? Color.black.opacity(0.6) : NxColor.textDim).multilineTextAlignment(.leading).lineLimit(3) }
                    }
                    Spacer(minLength: 8)
                    if let v = value { Text(v).font(NxFont.ui(13, .bold)).foregroundStyle(focused ? Color.black.opacity(0.7) : NxColor.textMuted).lineLimit(1) }
                    if let o = on { NxSwitch(on: o) }
                    else if chevron { Image(systemName: "chevron.right").font(.system(size: 12 * Metrics.unit, weight: .bold)).foregroundStyle(focused ? Color.black.opacity(0.6) : NxColor.textDim) }
                }
                .padding(.horizontal, Metrics.u(14)).padding(.vertical, Metrics.u(Metrics.tv ? 14 : 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                // a full-width line, Netflix-like: no card; the TV marks the focus in white, the phone separates lines with a hairline
                .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.u(6), style: .continuous))
                .overlay(alignment: .bottom) {
                    if !Metrics.tv { Rectangle().fill(NxColor.hairline).frame(height: 0.5).padding(.leading, Metrics.u(53)) }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.99))
        // a fixed key: the rows are built again when a choice list closes, and the focus goes back on the same row
        .nxRestorable("settings." + title)
    }
}

/// "Le tue squadre": follow football clubs and national teams. Their matches lead the Home and ring 10 minutes before.
struct TeamsView: View {
    @EnvironmentObject var app: AppModel
    @State private var catalog: [Crests.Pick] = []
    @State private var followed: [Teams.Team] = []
    @State private var query = ""
    @State private var matches: [Teams.TeamMatch] = []

    private var groups: [(String, [Crests.Pick])] {
        let n = MetaText.norm(query)
        let list = n.isEmpty ? catalog : catalog.filter { MetaText.norm($0.name).contains(n) || $0.search.contains(n) }
        var order = [String](); var by = [String: [Crests.Pick]]()
        for p in list { if by[p.group] == nil { order.append(p.group) }; by[p.group, default: []].append(p) }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Metrics.u(18)) {
                Text("Le partite delle squadre che segui arrivano in cima alla Home, e ti avviso 10 minuti prima del fischio d'inizio.")
                    .font(NxFont.meta).foregroundStyle(NxColor.textDim).padding(.horizontal, Metrics.gutter)
                NxField(icon: "magnifyingglass") {
                    TextField("", text: $query, prompt: Text("Cerca una squadra").foregroundColor(NxColor.textDim)).autocorrectionDisabled()
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(maxWidth: Metrics.tv ? 800 : .infinity, alignment: .leading)
                if !followed.isEmpty && query.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.u(8)) {
                        SectionHeader(title: "Segui", sub: matches.isEmpty ? "nessuna partita in guida nei prossimi giorni" : "prossima: \(matches[0].title) · \(TimeText.dayLabel(matches[0].kickoff) ?? "oggi") \(TimeText.time(matches[0].kickoff))")
                        grid(followed.map { Crests.Pick(name: $0.name, crest: $0.crest, group: "", search: "") })
                    }
                }
                if catalog.isEmpty { BrandLoader(label: "Carico le squadre…").frame(maxWidth: .infinity).padding(.top, 40) }
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: Metrics.u(8)) {
                        SectionHeader(title: g.0)
                        grid(g.1)
                    }
                }
                Color.clear.frame(height: Metrics.u(20))
            }
            .padding(.top, Metrics.u(8))
        }
        .nxScreen("Le tue squadre")
        .task { await reload() }
    }

    private func reload() async {
        followed = app.core.teams.followed()
        if catalog.isEmpty { catalog = Crests.catalog() }
        let core = app.core
        matches = await Task.detached { core.teams.upcomingForCurrent() }.value
    }

    private func grid(_ picks: [Crests.Pick]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.u(92)), spacing: Metrics.u(10))], spacing: Metrics.u(12)) {
            ForEach(picks) { p in
                let on = followed.contains { $0.crest == p.crest }
                CardButton(action: {
                    Task { _ = await app.core.teams.toggle(Teams.Team(name: p.name, crest: p.crest)); await reload() }
                }) {
                    VStack(spacing: Metrics.u(6)) {
                        ZStack(alignment: .topTrailing) {
                            NxImage(p.crest, fit: true, maxPixel: 200).frame(width: Metrics.u(54), height: Metrics.u(54))
                            if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 18 * Metrics.unit)).foregroundStyle(.white, NxColor.accent).offset(x: 8, y: -6) }
                        }
                        Text(p.name).font(NxFont.caption).foregroundStyle(on ? NxColor.text : NxColor.textMuted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Metrics.u(10))
                    .background(on ? NxColor.ink3 : NxColor.ink1, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
