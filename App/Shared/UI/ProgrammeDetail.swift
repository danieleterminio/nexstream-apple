import SwiftUI

@MainActor
final class ProgrammeDetailModel: ObservableObject {
    @Published var showing: Showing? = nil
    @Published var missing = false
    @Published var link: LiveVodMatcher.Link? = nil
    @Published var replicas: [Showing] = []
    @Published var later: [Showing] = []
    @Published var busy = false
    private let core = NexCore.shared
    let channelId: String
    let programmeId: Int64

    init(channelId: String, programmeId: Int64) { self.channelId = channelId; self.programmeId = programmeId }

    func load(kids: Bool) async {
        guard let c = core.channels.get(channelId) else { missing = true; return }
        var p = programmeId > 0 ? core.db.programme(programmeId) : nil
        // the guide may have been rebuilt since the card was drawn (new ids): fall back to what is on now
        if p == nil, let e = c.epgId { p = core.db.upcoming(e, limit: 1).first }
        var m = p.flatMap { core.meta.get(core.meta.keyOf($0)) }
        if m?.found != true { m = nil }
        showing = Showing(channel: c, programme: p, meta: m)
        if let pp = p, m == nil, let fresh = await core.meta.enrich(pp, c) { m = fresh; showing = Showing(channel: c, programme: pp, meta: fresh) }
        let now = Clock.now
        if let pp = p {
            let core = self.core
            let same = await Task.detached { core.db.sameTitle(pp.title, show: pp.show, exceptId: pp.id, from: now) }.value
            var byEpg = [String: ChannelEntity]()
            for ch in core.channels.visible() { if let e = ch.epgId, byEpg[e] == nil { byEpg[e] = ch } }
            replicas = same.compactMap { r in byEpg[r.epgId].map { Showing(channel: $0, programme: r, meta: m) } }
            if let e = c.epgId {
                later = core.db.programmesBetween(e, pp.stop, pp.stop + 8 * Clock.hour).prefix(8).map { q in
                    let qm = core.meta.get(core.meta.keyOf(q))
                    return Showing(channel: c, programme: q, meta: qm?.found == true ? qm : nil)
                }
            }
        }
        link = await core.matcher.linkFor(m, p, kids: kids)
    }

    func watchFromStart() async -> PlayRequest? {
        guard let l = link else { return nil }
        busy = true; defer { busy = false }
        return try? await core.matcher.watchFromStart(l, showing?.programme)
    }
}

/// The page of a programme / event: what it is, when it is on, the buttons to watch it — live on its channel, or from the
/// start on demand when the guide recognised a film or a series.
struct ProgrammeDetailView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @StateObject private var model: ProgrammeDetailModel

    init(channelId: String, programmeId: Int64) { _model = StateObject(wrappedValue: ProgrammeDetailModel(channelId: channelId, programmeId: programmeId)) }

    var body: some View {
        Group {
            if let s = model.showing { page(s) }
            else if model.missing { StateMessage(icon: "tv.slash", title: "Canale non disponibile", text: "Questo canale non è più nella tua linea.") }
            else { BrandLoader().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .nxPage()
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            NxIconButton(icon: "chevron.left", label: "Indietro", size: 36) { app.pop() }.padding(.leading, 10).padding(.top, 6)
        }
        #endif
        .task { await model.load(kids: app.kids) }
    }

    private func info(_ s: Showing) -> some View {
        VStack(alignment: .leading, spacing: Metrics.u(8)) {
            HStack(spacing: Metrics.u(8)) { ChannelLogo(channel: s.channel, height: 22); ShowingTags(showing: s) }
            Text([s.timeLabel(), s.match != nil ? s.competition : s.episodeLine].compactMap { $0 }.joined(separator: "  ·  ")).font(NxFont.bodyStrong).foregroundStyle(NxColor.text)
            HStack(spacing: Metrics.u(8)) {
                if let w = s.whenLabel(), s.isLive() || (s.start ?? 0) > Clock.now { Text(w).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                if let m = s.meta {
                    if m.year > 0 { Text(String(m.year)).font(NxFont.meta).foregroundStyle(NxColor.textMuted) }
                    if m.vote > 0 { Text(String(format: "★ %.1f", m.vote)).font(NxFont.meta).foregroundStyle(NxColor.gold) }
                }
                if let sub = s.sub { Text(sub).font(NxFont.meta).foregroundStyle(NxColor.textDim).lineLimit(1) }
            }
            if let p = s.progress(), s.isLive() { NxProgressBar(value: p).frame(maxWidth: Metrics.u(260)) }
        }
    }

    @ViewBuilder private func texts(_ s: Showing) -> some View {
        if let o = s.overview { Text(o).font(NxFont.ui(14)).foregroundStyle(.white) }
        if let cast = s.meta?.cast.nilIfBlank {
            (Text("Cast: ").foregroundColor(NxColor.textDim) + Text(cast).foregroundColor(NxColor.textMuted)).font(NxFont.caption).lineLimit(2)
        }
        if let d = s.programme?.desc, let mo = s.meta?.overview, d != mo, let clean = Showing.cleanSynopsis(d) {
            Text("DALLA GUIDA TV").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim).padding(.top, Metrics.u(6))
            Text(clean).font(NxFont.meta).foregroundStyle(NxColor.textMuted)
        }
    }

    @ViewBuilder private func secondary(_ s: Showing, live: Bool) -> some View {
        let hasReminder = store.reminders.contains(s.channel.streamId)
        let fav = store.favorites.contains(s.channel.streamId)
        NxIconAction(icon: fav ? "star.fill" : "star", label: "Preferito", active: fav) { app.toggleFavorite(s.channel) }
        if (!live && (s.start ?? 0) > Clock.now) || hasReminder {
            NxIconAction(icon: hasReminder ? "bell.fill" : "bell", label: hasReminder ? "Avviso attivo" : "Avvisami", active: hasReminder) { app.toggleReminder(s) }
        }
        if let l = model.link, l.media == "tv" { NxIconAction(icon: "list.bullet", label: "Episodi") { app.open(.title("tv", l.id)) } }
        if let l = model.link, l.media == "movie" { NxIconAction(icon: "film", label: "Scheda film") { app.open(.title("movie", l.id)) } }
    }

    private func fromStart() {
        Task { if let r = await model.watchFromStart() { app.play(r) } else { app.say("Non riesco a prepararlo adesso.") } }
    }

    @ViewBuilder private func rows(_ s: Showing) -> some View {
        if !model.replicas.isEmpty {
            CardRow(title: s.programme?.kind == "series" || s.meta?.media == "tv" ? "Prossimi episodi e repliche" : "Prossime messe in onda", items: model.replicas) { r in
                ShowCard(showing: r, style: .compact, reminder: store.reminders.contains(r.channel.streamId)) { app.openShowing(r) }
            }
        }
        if !model.later.isEmpty {
            CardRow(title: "Dopo su \(s.channel.name)", items: model.later) { r in
                ShowCard(showing: r, style: .compact, reminder: store.reminders.contains(r.channel.streamId)) { app.openShowing(r) }
            }
        }
        if let l = model.link, l.similar.count >= 4 {
            VodRowView(row: VodRow(id: "similar", title: "Titoli simili", items: l.similar), tag: "On demand")
        }
    }

    @ViewBuilder private func page(_ s: Showing) -> some View {
        let live = s.isLive() || s.programme == nil
        #if os(iOS)
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                Button { app.play(s.channel) } label: {
                    ZStack {
                        ShowingArt(showing: s, hero: true)
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                        if live {
                            Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 58, height: 58).background(Color.black.opacity(0.5), in: Circle()).overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        }
                    }
                    .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit).clipped()
                }
                .buttonStyle(NxPlainStyle(scale: 1))
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.cardTitle).font(NxFont.display(23, .bold)).foregroundStyle(.white).lineLimit(3)
                    info(s)
                    NxButton(live ? "Guarda ora" : "Vai al canale", icon: "play.fill", kind: .primary, wide: true) { app.play(s.channel) }
                    if let l = model.link, l.available {
                        NxButton(model.busy ? "Preparo…" : (l.media == "movie" ? "Guarda dall'inizio" : "Episodio dall'inizio"), icon: "arrow.counterclockwise", wide: true) { fromStart() }.disabled(model.busy)
                    }
                    texts(s)
                    HStack(alignment: .top, spacing: 4) { secondary(s, live: live); Spacer(minLength: 0) }.padding(.leading, -10)
                }
                .padding(.horizontal, Metrics.gutter)
                rows(s)
                Color.clear.frame(height: 20)
            }
        }
        #else
        ZStack(alignment: .topLeading) {
            ShowingArt(showing: s, hero: true)
                .frame(width: 1240, height: 698).clipped().overlay(NxColor.heroScrim).overlay(NxColor.heroFade)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let logo = s.logo {
                            NxImage(url: logo, fit: true, maxPixel: 800, alignment: .bottomLeading) { Text(s.cardTitle).font(NxFont.display(34, .heavy)).foregroundStyle(.white) }
                                .frame(maxWidth: 520, maxHeight: 160, alignment: .bottomLeading)
                        } else { Text(s.cardTitle).font(NxFont.display(34, .heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7) }
                        info(s)
                        VStack(alignment: .leading, spacing: 8) { texts(s) }.frame(maxWidth: 820, alignment: .leading).lineLimit(4)
                        HStack(spacing: 18) {
                            NxButton(live ? "Guarda ora" : "Vai al canale", icon: "play.fill", kind: .primary) { app.play(s.channel) }
                            if let l = model.link, l.available {
                                NxButton(l.media == "movie" ? "Guarda dall'inizio" : "Episodio dall'inizio", icon: "arrow.counterclockwise") { fromStart() }
                            }
                            secondary(s, live: live)
                        }
                        .padding(.top, 8)
                        .focusSection()
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.top, 90)
                    rows(s)
                    Color.clear.frame(height: 60)
                }
            }
        }
        .ignoresSafeArea()
        #endif
    }
}
