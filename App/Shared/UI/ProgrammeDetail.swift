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
        .task { await model.load(kids: app.kids) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
    }

    @ViewBuilder private func page(_ s: Showing) -> some View {
        let live = s.isLive() || s.programme == nil
        let hasReminder = store.reminders.contains(s.channel.streamId)
        let fav = store.favorites.contains(s.channel.streamId)
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Metrics.u(18)) {
                ZStack(alignment: .bottomLeading) {
                    ShowingArt(showing: s, hero: true).frame(maxWidth: .infinity).frame(height: Metrics.tv ? 600 : 290).clipped()
                    #if os(tvOS)
                    NxColor.heroScrim
                    #endif
                    NxColor.heroFade
                    VStack(alignment: .leading, spacing: Metrics.u(8)) {
                        HStack(spacing: Metrics.u(8)) { ChannelLogo(channel: s.channel, height: 24); ShowingTags(showing: s) }
                        if let logo = s.logo {
                            NxImage(url: logo, fit: true, maxPixel: 700, alignment: .bottomLeading) { Text(s.cardTitle).font(NxFont.hero).foregroundStyle(.white) }
                                .frame(maxWidth: Metrics.u(240), maxHeight: Metrics.u(78), alignment: .bottomLeading)
                        } else { Text(s.cardTitle).font(NxFont.hero).foregroundStyle(.white).lineLimit(3).minimumScaleFactor(0.7) }
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.bottom, Metrics.u(6))
                }
                VStack(alignment: .leading, spacing: Metrics.u(10)) {
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
                    buttons(s, live: live, hasReminder: hasReminder, fav: fav)
                    if let o = s.overview { Text(o).font(NxFont.body).foregroundStyle(NxColor.textMuted) }
                    if let cast = s.meta?.cast.nilIfBlank { Text("Con \(cast)").font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(2) }
                    if let d = s.programme?.desc, let mo = s.meta?.overview, d != mo, let clean = Showing.cleanSynopsis(d) {
                        Text("DALLA GUIDA TV").font(NxFont.label).tracking(1).foregroundStyle(NxColor.textDim).padding(.top, Metrics.u(6))
                        Text(clean).font(NxFont.meta).foregroundStyle(NxColor.textMuted)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(maxWidth: Metrics.tv ? 1200 : .infinity, alignment: .leading)

                if !model.replicas.isEmpty {
                    CardRow(title: s.programme?.kind == "series" || s.meta?.media == "tv" ? "Prossimi episodi e repliche" : "Prossime messe in onda", items: model.replicas) { r in
                        ShowCard(showing: r, style: .compact, reminder: store.reminders.contains(r.channel.streamId),
                                 onTap: { app.openShowing(r) }, onPlay: { app.play(r.channel) }, onReminder: { app.toggleReminder(r) })
                    }
                }
                if !model.later.isEmpty {
                    CardRow(title: "Dopo su \(s.channel.name)", items: model.later) { r in
                        ShowCard(showing: r, style: .compact, reminder: store.reminders.contains(r.channel.streamId), onTap: { app.openShowing(r) }, onReminder: { app.toggleReminder(r) })
                    }
                }
                if let l = model.link, l.similar.count >= 4 {
                    VodRowView(row: VodRow(id: "similar", title: "Titoli simili", items: l.similar), tag: "On demand")
                }
                Color.clear.frame(height: Metrics.u(30))
            }
        }
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }

    @ViewBuilder private func buttons(_ s: Showing, live: Bool, hasReminder: Bool, fav: Bool) -> some View {
        let canRemind = !live && (s.start ?? 0) > Clock.now
        let main = HStack(spacing: Metrics.u(10)) {
            NxButton(live ? "Guarda ora" : "Vai al canale", icon: "play.fill", kind: .primary, wide: !Metrics.tv) { app.play(s.channel) }
        }
        let extra = Group {
            if let l = model.link, l.available {
                NxButton(l.media == "movie" ? "Guarda dall'inizio" : "Episodio dall'inizio", icon: "arrow.counterclockwise") {
                    Task { if let r = await model.watchFromStart() { app.play(r) } else { app.say("Non riesco a prepararlo adesso.") } }
                }
            }
            if let l = model.link, l.media == "tv" { NxButton("Tutti gli episodi", icon: "list.bullet") { app.open(.title("tv", l.id)) } }
            if let l = model.link, l.media == "movie" { NxButton("Scheda del film", icon: "film") { app.open(.title("movie", l.id)) } }
            if canRemind || hasReminder { NxButton(hasReminder ? "Avviso attivo" : "Avvisami", icon: hasReminder ? "bell.slash" : "bell") { app.toggleReminder(s) } }
            NxIconButton(icon: fav ? "star.fill" : "star", label: "Preferito", active: fav) { app.toggleFavorite(s.channel) }
        }
        if Metrics.tv { HStack(spacing: Metrics.u(10)) { main; extra } }
        else {
            VStack(alignment: .leading, spacing: Metrics.u(10)) {
                main
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: Metrics.u(10)) { extra } }.scrollClipDisabled()
            }
        }
    }
}
