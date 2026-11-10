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

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Metrics.rowGap) {
                let q = query.trimmed
                if q.count < 2 {
                    if !suggestions.isEmpty { VodRowView(row: VodRow(id: "sugg", title: "I più cercati", items: suggestions)) }
                    else { StateMessage(icon: "magnifyingglass", title: "Cerca un canale, un programma, un film o una serie").frame(height: Metrics.u(300)) }
                } else if channels.isEmpty && programmes.isEmpty && titles.isEmpty {
                    if searching { BrandLoader(label: "Cerco “\(q)”…").frame(maxWidth: .infinity).frame(height: Metrics.u(300)) }
                    else { StateMessage(icon: "magnifyingglass", title: "Nessun risultato per “\(q)”", text: "Prova con un'altra parola o con il titolo originale.").frame(height: Metrics.u(300)) }
                } else {
                    if !channels.isEmpty {
                        CardRow(title: "Canali", items: channels) { c in
                            ChannelCard(showing: store.showing(c), favorite: store.favorites.contains(c.streamId), onTap: { app.play(c) }, onInfo: { app.openShowing(store.showing(c)) }, onFavorite: { app.toggleFavorite(c) })
                        }
                    }
                    if !programmes.isEmpty {
                        CardRow(title: "In TV", sub: "in onda e nei prossimi giorni", items: programmes) { s in
                            ShowCard(showing: s, style: .compact, reminder: store.reminders.contains(s.channel.streamId), onTap: { app.openShowing(s) }, onPlay: { app.play(s.channel) }, onReminder: { app.toggleReminder(s) })
                        }
                    }
                    if !titles.isEmpty { VodRowView(row: VodRow(id: "search-vod", title: "Film e serie", items: titles), tag: "On demand") }
                }
                Color.clear.frame(height: Metrics.u(20))
            }
            .padding(.top, Metrics.u(10))
        }
        .nxPage()
        .navigationTitle("Cerca")
        .searchable(text: $query, prompt: "Canali, programmi, film e serie")
        .autocorrectionDisabled()
        .task(id: query) { await run(query.trimmed) }
        .task {
            if suggestions.isEmpty { suggestions = await app.core.catalog.heroCandidates(app.kids) + ((try? await app.core.tmdb.popular("tv")) ?? []).prefix(10) }
        }
        .onAppear { if let q = app.pendingSearch { query = q; app.pendingSearch = nil } }
        .onChange(of: app.pendingSearch) { _, q in if let q = q { query = q; app.pendingSearch = nil } }
    }

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

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var prefs = Prefs.Values()
    @State private var rev = 0
    @State private var teams: [Teams.Team] = []
    @State private var askLogout = false
    @State private var updater: String? = nil
    @State private var engineVersion = ""
    @State private var watches = [Watch]()

    var body: some View {
        let core = app.core
        let pid = app.pid
        Form {
            if let p = app.profile {
                SwiftUI.Section {
                    HStack(spacing: Metrics.u(14)) {
                        p.face(54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(NxFont.titleM).foregroundStyle(NxColor.text)
                            Text(p.kids ? "Profilo bambini" : "Contenuti: \(Avatars.maturityLabels[min(2, max(0, p.maturity))])").font(NxFont.caption).foregroundStyle(NxColor.textMuted)
                            if p.pin != nil { Text("Protetto da PIN").font(NxFont.caption).foregroundStyle(NxColor.textDim) }
                        }
                    }
                    row("Cambia profilo", nil, "person.2.fill") { app.changeProfile() }
                    row("Gestisci profili", "Nome, avatar, PIN e profili per bambini", "person.crop.circle.badge.plus") { app.open(.manageProfiles) }
                    row("Le tue squadre", teams.isEmpty ? "Partite in Home e un avviso 10 minuti prima" : teams.map { $0.name }.joined(separator: ", "), "soccerball") { app.open(.teams) }
                    row("Copia o invia i profili", "Tra questo dispositivo e un'altra app NexStream di casa", "arrow.left.arrow.right") { app.open(.transfer) }
                } header: { Text("Profilo") }
            }
            SwiftUI.Section {
                Picker(selection: Binding(get: { prefs.quality }, set: { v in core.prefs.update { $0.quality = v } })) {
                    ForEach(Prefs.qualities, id: \.0) { q in Text(q.1).tag(q.0) }
                } label: { label("Qualità video", "La versione di ogni canale che parte per prima; se non risponde passo da solo a un'altra.", "4k.tv") }
                Toggle(isOn: Binding(get: { prefs.hevc }, set: { v in core.prefs.update { $0.hevc = v } })) {
                    label("Usa le versioni HEVC", "Stessa immagine con meno dati. Spegnilo se qualche canale resta nero.", "cpu")
                }
                Picker(selection: Binding(get: { prefs.preferredText }, set: { v in core.prefs.update { $0.preferredText = v } })) {
                    Text("Spenti").tag(""); Text("Italiano").tag("it")
                } label: { label("Sottotitoli", "Quando il canale li trasmette.", "captions.bubble") }
            } header: { Text("Canali in diretta") }
            SwiftUI.Section {
                Toggle(isOn: Binding(get: { core.settings.autoplay(pid) }, set: { core.settings.setAutoplay(pid, $0) })) {
                    label("Episodio successivo automatico", "Alla fine di un episodio parte il seguente.", "forward.end.fill")
                }
                Toggle(isOn: Binding(get: { core.settings.creditsPrompt(pid) }, set: { core.settings.setCreditsPrompt(pid, $0) })) {
                    label("Proponi il prossimo sui titoli di coda", "Nell'ultimo minuto compare “Prossimo episodio”.", "text.line.last.and.arrowtriangle.forward")
                }
                Picker(selection: Binding(get: { core.settings.stillWatchingHours(pid) }, set: { core.settings.setStillWatchingHours(pid, $0) })) {
                    ForEach(Settings.stillHoursOptions, id: \.self) { h in Text(h == 0 ? "Mai" : (h == 1 ? "1 ora" : "\(h) ore")).tag(h) }
                } label: { label("“Stai ancora guardando?”", "Dopo quante ore senza toccare nulla te lo chiedo.", "hourglass") }
                Picker(selection: Binding(get: { core.settings.stillWatchingEpisodes(pid) }, set: { core.settings.setStillWatchingEpisodes(pid, $0) })) {
                    ForEach(Settings.stillEpisodesOptions, id: \.self) { n in Text("\(n) episodi").tag(n) }
                } label: { label("…e dopo quanti episodi", "Episodi partiti da soli, uno dopo l'altro.", "repeat") }
                Picker(selection: Binding(get: { core.settings.audioLang(pid) }, set: { core.settings.setAudioLang(pid, $0) })) {
                    ForEach(Settings.audioOptions, id: \.0) { o in Text(o.1).tag(o.0) }
                } label: { label("Lingua dell'audio", "Quando un film o una serie ha più lingue.", "waveform") }
                #if os(iOS)
                row("Download", "Film ed episodi salvati su questo dispositivo", "arrow.down.circle") { app.open(.downloads) }
                #endif
                row("Azzera “Continua a guardare”", "Toglie i titoli lasciati a metà", "clock.arrow.circlepath") { core.library.clearContinue(pid); app.say("Fatto") }
            } header: { Text("Film e serie") }
            #if os(iOS)
            SwiftUI.Section {
                row("Telecomando della TV", "Usa il telefono per comandare NexStream sulla TV di casa", "appletvremote.gen4.fill") { app.open(.remote) }
            } header: { Text("In casa") }
            #endif
            SwiftUI.Section {
                if let s = app.session {
                    label("Linea \(s.username)", expiry(s), "antenna.radiowaves.left.and.right")
                }
                row(app.syncStatus != nil ? "Aggiornamento in corso…" : "Aggiorna canali e guida TV", app.syncStatus ?? (core.epg.lastReport() ?? "Si aggiornano da soli; usalo se manca un canale o un programma."), "arrow.clockwise") {
                    if app.syncStatus == nil { core.syncIfNeeded(force: true) }
                }
                row("Aggiorna le sorgenti on demand", updater ?? "Stream4Me \(engineVersion)", "shippingbox") {
                    updater = "Controllo…"
                    Task {
                        switch await core.updater.check(force: true) {
                        case .upToDate: updater = "Sorgenti già aggiornate"
                        case .updated(let sha): updater = "Aggiornate (\(sha.take(7)))"
                        case .failed(let m): updater = m
                        case .skipped: updater = "Controllate da poco"
                        }
                    }
                }
                Button(role: .destructive) { askLogout = true } label: { label("Esci dalla linea", "Dovrai inserire di nuovo nome utente e password.", "rectangle.portrait.and.arrow.right") }
            } header: { Text("Linea") } footer: {
                Text("NexStream \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(NxFont.caption).foregroundStyle(NxColor.textDim).frame(maxWidth: .infinity).padding(.top, 10)
            }
        }
        .nxClearList()
        .nxPage()
        .navigationTitle("Impostazioni")
        .id(rev)
        .onAppear {
            teams = core.teams.followed()
            watches = [onMain(core.prefs.values) { prefs = $0 }, onMain(core.settings.rev) { rev = $0 }, onMain(core.teams.changed) { _ in teams = core.teams.followed() }]
            Task { engineVersion = await core.engine.version() }
        }
        .onDisappear { watches = [] }
        .confirmationDialog("Uscire dalla linea?", isPresented: $askLogout, titleVisibility: .visible) {
            Button("Esci", role: .destructive) { core.logout() }
            Button("Annulla", role: .cancel) {}
        } message: { Text("La linea verrà scollegata da questo dispositivo. Profili e preferiti restano.") }
    }

    private func expiry(_ s: LineSession) -> String {
        guard let exp = s.expiringAt, !exp.isBlank else { return "Scadenza non disponibile" }
        var date: Date? = nil
        if let secs = Double(exp), secs > 1_000_000_000 { date = Date(timeIntervalSince1970: secs) }
        else {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
                f.dateFormat = pattern
                if let d = f.date(from: exp) ?? f.date(from: String(exp.prefix(19))) { date = d; break }
            }
        }
        guard let d = date else { return "Scade il \(exp.take(10))" }
        let out = DateFormatter(); out.locale = Locale(identifier: "it_IT"); out.dateFormat = "d MMMM yyyy"
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: d)).day ?? 0
        if days < 0 { return "Scaduta il \(out.string(from: d))" }
        if days == 0 { return "Scade oggi" }
        return "Attiva fino al \(out.string(from: d)) · \(days) giorni"
    }

    private func label(_ title: String, _ sub: String?, _ icon: String) -> some View {
        HStack(spacing: Metrics.u(12)) {
            Image(systemName: icon).font(.system(size: 17 * Metrics.unit, weight: .medium)).foregroundStyle(NxColor.textMuted).frame(width: Metrics.u(28))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NxFont.bodyStrong).foregroundStyle(NxColor.text)
                if let s = sub { Text(s).font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(3) }
            }
        }
    }
    private func row(_ title: String, _ sub: String?, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                label(title, sub, icon)
                Spacer(minLength: 0)
                #if os(iOS)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(NxColor.textDim)
                #endif
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- teams

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
                if !followed.isEmpty {
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
        .nxPage()
        .navigationTitle("Le tue squadre")
        .searchable(text: $query, prompt: "Cerca una squadra")
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
                Button {
                    Task { _ = await app.core.teams.toggle(Teams.Team(name: p.name, crest: p.crest)); await reload() }
                } label: {
                    VStack(spacing: Metrics.u(6)) {
                        ZStack(alignment: .topTrailing) {
                            NxImage(p.crest, fit: true, maxPixel: 200).frame(width: Metrics.u(54), height: Metrics.u(54))
                            if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 18 * Metrics.unit)).foregroundStyle(.white, NxColor.accent).offset(x: 8, y: -6) }
                        }
                        Text(p.name).font(NxFont.caption).foregroundStyle(on ? NxColor.text : NxColor.textMuted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Metrics.u(8))
                }
                #if os(tvOS)
                .buttonStyle(.card)
                #else
                .buttonStyle(PressScaleStyle())
                #endif
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
