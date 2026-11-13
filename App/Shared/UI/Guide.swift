import SwiftUI

/// Which channels a page shows: all of them, the favourites, or one genre. A pill that opens our own list.
struct GenrePill: View {
    @Binding var selected: String
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    private var label: String {
        switch selected {
        case "all": return "Tutti i canali"
        case "fav": return "Preferiti"
        default: return store.categories.first { $0.id == selected }?.label ?? "Tutti i canali"
        }
    }

    var body: some View {
        NxChip(title: label, icon: selected == "fav" ? "star.fill" : nil, trailing: "chevron.down", selected: selected != "all") {
            var options: [(String, String)] = [("all", "Tutti i canali")]
            if !store.favorites.isEmpty { options.append(("fav", "Preferiti")) }
            options += store.categories.map { ($0.id, $0.label) }
            app.choose("Canali", options, current: selected) { selected = $0 }
        }
    }
}

extension LiveStore {
    func channels(in genre: String) -> [ChannelEntity] {
        switch genre {
        case "all": return channels
        case "fav": return channels.filter { favorites.contains($0.streamId) }
        default: return byCategory(genre)
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- Diretta

/// "Diretta": every channel of the line with what it is showing. A list on the phone, tiles on the TV.
struct LiveView: View {
    /// Inside the phone's "Diretta" page, which has its own bar.
    var embedded = false
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var genre: String = "all"

    var body: some View {
        let list = store.channels(in: genre)
        Group {
            if store.channels.isEmpty {
                if app.syncStatus != nil || !store.loaded { BrandLoader(label: app.syncStatus ?? "Carico i canali…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { StateMessage(icon: "tv", title: "Nessun canale", text: "Controlla la connessione (VPN) e aggiorna dalle impostazioni.", actionTitle: "Aggiorna ora") { app.core.syncIfNeeded(force: true) } }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: Metrics.u(Metrics.tv ? 14 : 0)) {
                            HStack(spacing: Metrics.u(8)) {
                                GenrePill(selected: $genre)
                                if !store.favorites.isEmpty { NxChip(title: "Preferiti", icon: "star.fill", selected: genre == "fav") { genre = genre == "fav" ? "all" : "fav" } }
                                Spacer(minLength: 0)
                                Text("\(list.count) canali").font(NxFont.caption).foregroundStyle(NxColor.textDim)
                            }
                            .padding(.horizontal, Metrics.gutter).padding(.vertical, Metrics.u(8))
                            .id("top")
                            if list.isEmpty { StateMessage(icon: "star", title: "Nessun canale qui", text: "Tieni premuto su un canale per aggiungerlo ai preferiti.").frame(height: Metrics.u(260)) }
                            #if os(tvOS)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.channelCardW), spacing: Metrics.cardGap)], alignment: .leading, spacing: 30) {
                                ForEach(list) { c in
                                    ChannelCard(showing: store.showing(c), favorite: store.favorites.contains(c.streamId)) { app.play(c, ids: list.map { $0.streamId }) }
                                }
                            }
                            .padding(.horizontal, Metrics.gutter).padding(.top, 10)
                            #else
                            if Metrics.isPad {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
                                    ForEach(list) { c in
                                        ChannelLine(showing: store.showing(c), favorite: store.favorites.contains(c.streamId)) { app.play(c, ids: list.map { $0.streamId }) }
                                    }
                                }
                            } else {
                                ForEach(list) { c in
                                    ChannelLine(showing: store.showing(c), favorite: store.favorites.contains(c.streamId)) { app.play(c, ids: list.map { $0.streamId }) }
                                }
                            }
                            #endif
                            Color.clear.frame(height: Metrics.u(20))
                        }
                    }
                    .onChange(of: app.reselect) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
                }
            }
        }
        .if(!embedded) { $0.nxScreen("Diretta", back: false) }
    }
}

#if os(iOS)
/// The phone's "Diretta": the channels and the TV guide, one tap apart.
struct LiveHub: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NxTopBar(title: "Diretta", back: false, large: true) {
                BarIcon(icon: "magnifyingglass", label: "Cerca") { app.open(.search) }
            }
            HStack(spacing: 24) {
                tab("Canali", 0)
                tab("Guida TV", 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter)
            .overlay(alignment: .bottom) { Rectangle().fill(NxColor.ink4).frame(height: 1) }
            if app.liveTab == 1 { GuideView(embedded: true) } else { LiveView(embedded: true) }
        }
        .nxPage()
    }

    private func tab(_ title: String, _ i: Int) -> some View {
        let on = app.liveTab == i
        return Button { app.liveTab = i } label: {
            VStack(spacing: 7) {
                Text(title).font(NxFont.ui(16, .heavy)).foregroundStyle(on ? Color.white : NxColor.textDim)
                Rectangle().fill(on ? NxColor.accent : Color.clear).frame(height: 3)
            }
            .fixedSize()
            .padding(.top, 4)
        }
        .buttonStyle(NxPlainStyle(scale: 1))
    }
}
#endif

/// One channel in a list: the picture of what is on, the programme, how far it is, what comes after.
struct ChannelLine: View {
    let showing: Showing
    var favorite: Bool = false
    var current: Bool = false
    let onTap: () -> Void
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    var body: some View {
        let c = showing.channel
        CardButton(action: onTap, radius: 0, onLong: {
            app.menu(c.name, [
                NxAction("Guarda \(c.name)", icon: "play.fill") { app.play(c) },
                NxAction("Dettagli del programma", icon: "info.circle") { app.openShowing(showing) },
                NxAction(favorite ? "Togli dai preferiti" : "Aggiungi ai preferiti", icon: favorite ? "star.slash" : "star") { app.toggleFavorite(c) },
            ])
        }) {
            HStack(spacing: Metrics.u(12)) {
                ZStack(alignment: .bottom) {
                    ShowingArt(showing: showing)
                    if let p = showing.progress() { NxProgressBar(value: p, height: 3) }
                }
                .frame(width: Metrics.u(128), height: Metrics.u(72))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).stroke(Color.white, lineWidth: current ? 2 : 0))
                VStack(alignment: .leading, spacing: Metrics.u(3)) {
                    HStack(spacing: Metrics.u(6)) {
                        if c.num > 0 { Text("\(c.num)").font(NxFont.ui(11, .heavy)).foregroundStyle(NxColor.textDim) }
                        Text(c.name).font(NxFont.ui(11, .bold)).foregroundStyle(NxColor.textMuted).lineLimit(1)
                        if favorite { Image(systemName: "star.fill").font(.system(size: 9 * Metrics.type)).foregroundStyle(NxColor.textMuted) }
                        if showing.isLiveBroadcast && showing.isLive() { NxTag(text: "Diretta", color: NxColor.accent) }
                    }
                    Text(showing.programme == nil && c.event == nil ? c.name : showing.cardTitle).font(NxFont.ui(15, .bold)).foregroundStyle(current ? NxColor.accentBright : NxColor.text).lineLimit(1)
                    Text([showing.timeLabel(), showing.cardLine].compactMap { $0 }.joined(separator: " · ").nilIfBlank ?? (showing.programme == nil ? "Nessuna guida" : ""))
                        .font(NxFont.ui(12, .medium)).foregroundStyle(NxColor.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if current { Image(systemName: "waveform").font(.system(size: 15 * Metrics.unit, weight: .bold)).foregroundStyle(NxColor.accentBright) }
            }
            .padding(.horizontal, Metrics.gutter).padding(.vertical, Metrics.u(7))
            .contentShape(Rectangle())
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- Guida TV

/// "Guida TV": a time grid. Channels down the side, the hours across the top, every programme as wide as it is long.
/// The window (two hours on the phone, three on the TV) moves with the arrows, a swipe, or the day and time pills.
struct GuideView: View {
    var embedded = false
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var genre = "all"
    @State private var start: Millis = GuideView.floor30(Clock.now)
    @State private var byEpg: [String: [ProgrammeEntity]] = [:]
    @State private var loadedFor = ""
    @State private var now = Clock.now

    #if os(tvOS)
    private let span: Millis = 3 * Clock.hour
    private let headW: CGFloat = 250, rowH: CGFloat = 104, gap: CGFloat = 6
    #else
    private let span: Millis = (Metrics.isPad ? 4 : 2) * Clock.hour
    private let headW: CGFloat = Metrics.isPad ? 96 : 62, rowH: CGFloat = Metrics.isPad ? 68 : 60, gap: CGFloat = 3
    #endif

    static func floor30(_ t: Millis) -> Millis { t - t % (30 * Clock.minute) }

    private var channels: [ChannelEntity] { store.channels(in: genre).filter { $0.epgId != nil || $0.event != nil } }
    private var day: Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: Date(ms: start))).day ?? 0
    }
    private var isNow: Bool { start <= now && now < start + span }

    var body: some View {
        let chans = channels
        VStack(spacing: 0) {
            controls
            GeometryReader { g in
                let gridW = max(100, g.size.width - headW - Metrics.gutter * (Metrics.tv ? 2 : 0) - (Metrics.tv ? 0 : 4))
                VStack(spacing: 0) {
                    ruler(gridW)
                    if chans.isEmpty { StateMessage(icon: "calendar", title: "Nessuna guida disponibile", text: app.syncStatus ?? "La guida si aggiorna da sola ogni 6 ore.") }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: gap) {
                                    Color.clear.frame(height: 0).id("top")
                                    ForEach(chans) { c in row(c, gridW) }
                                    Color.clear.frame(height: Metrics.u(20))
                                }
                            }
                            .onChange(of: app.reselect) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
                        }
                        #if os(iOS)
                        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                            if abs(v.translation.width) > abs(v.translation.height) * 1.6 && abs(v.translation.width) > 60 { shift(v.translation.width < 0 ? 1 : -1) }
                        })
                        #endif
                    }
                }
                .padding(.horizontal, Metrics.tv ? Metrics.gutter : 0)
            }
        }
        .if(!embedded) { $0.nxScreen("Guida TV", back: false) }
        .padding(.top, embedded ? 6 : 0)
        .task(id: "\(genre)-\(start)-\(store.channels.count)-\(store.version / 20)") { await load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                now = Clock.now
            }
        }
        .onAppear { now = Clock.now }
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: Metrics.u(6)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.u(8)) {
                    NxChip(title: dayTitle(day), trailing: "chevron.down", selected: day != 0) {
                        app.choose("Giorno", (0..<6).map { ($0, dayTitle($0)) }, current: day) { d in goDay(d) }
                    }
                    NxChip(title: "Adesso", selected: isNow) { start = GuideView.floor30(Clock.now) }
                    ForEach(GuideView.slots, id: \.0) { s in
                        NxChip(title: s.0, selected: !isNow && hour(start) == s.1) { goHour(s.1) }
                    }
                    GenrePill(selected: $genre)
                }
                .padding(.horizontal, Metrics.gutter)
                #if os(tvOS)
                .padding(.vertical, 12)
                #else
                .padding(.vertical, 4)
                #endif
            }
            .scrollClipDisabled()
        }
        .padding(.bottom, Metrics.u(4))
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private static let slots: [(String, Int)] = [("Mattina", 7), ("Pomeriggio", 14), ("Sera", 19), ("Prima serata", 21), ("Notte", 23)]

    private func hour(_ t: Millis) -> Int { Calendar.current.component(.hour, from: Date(ms: t)) }
    private func dayTitle(_ d: Int) -> String {
        if d == 0 { return "Oggi" }
        if d == 1 { return "Domani" }
        if d == -1 { return "Ieri" }
        let date = Calendar.current.date(byAdding: .day, value: d, to: Date()) ?? Date()
        return TimeText.longDayLabel(date.ms)
    }
    private func goDay(_ d: Int) {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: Date())) ?? Date()
        if d == 0 { start = GuideView.floor30(Clock.now); return }
        start = (cal.date(bySettingHour: 21, minute: 0, second: 0, of: base) ?? base).ms
    }
    private func goHour(_ h: Int) {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(ms: start))
        start = (cal.date(bySettingHour: h, minute: 0, second: 0, of: base) ?? base).ms
    }
    private func shift(_ dir: Int) {
        let step = span / 2
        withAnimation(.easeInOut(duration: 0.2)) { start = max(GuideView.floor30(Clock.now) - 2 * Clock.hour, start + Millis(dir) * step) }
    }

    /// The hours across the top, with the arrows that move the window.
    private func ruler(_ gridW: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                arrow("chevron.left") { shift(-1) }
                Spacer(minLength: 0)
            }
            .frame(width: headW)
            ZStack(alignment: .leading) {
                let ticks = Int(span / (30 * Clock.minute))
                ForEach(0..<ticks, id: \.self) { i in
                    let t = start + Millis(i) * 30 * Clock.minute
                    Text(TimeText.time(t)).font(NxFont.ui(11, i % 2 == 0 ? .heavy : .medium)).foregroundStyle(i % 2 == 0 ? NxColor.textMuted : NxColor.textDim)
                        .offset(x: gridW * CGFloat(i) / CGFloat(ticks) + Metrics.u(4))
                }
                if isNow {
                    Text("ORA").font(NxFont.ui(9, .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, Metrics.u(4)).padding(.vertical, Metrics.u(1.5))
                        .background(NxColor.accent, in: RoundedRectangle(cornerRadius: Metrics.u(3)))
                        .offset(x: max(0, min(gridW - Metrics.u(30), x(now, gridW) - Metrics.u(14))), y: Metrics.u(13))
                }
            }
            .frame(width: gridW - Metrics.u(34), height: Metrics.u(34), alignment: .topLeading)
            arrow("chevron.right") { shift(1) }.frame(width: Metrics.u(34))
        }
        .frame(height: Metrics.u(36))
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func arrow(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Focusable { focused in
                Image(systemName: icon).font(.system(size: 13 * Metrics.unit, weight: .heavy))
                    .foregroundStyle(focused ? Color.black : Color.white)
                    .frame(width: Metrics.u(30), height: Metrics.u(28))
                    .background(focused ? Color.white : NxColor.ink3, in: RoundedRectangle(cornerRadius: Metrics.u(5), style: .continuous))
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.9))
        .padding(.leading, Metrics.tv ? 0 : 8)
        .accessibilityLabel(icon == "chevron.left" ? "Prima" : "Dopo")
    }

    // MARK: grid

    private func x(_ t: Millis, _ gridW: CGFloat) -> CGFloat { gridW * CGFloat(max(0, min(span, t - start))) / CGFloat(span) }

    private func row(_ c: ChannelEntity, _ gridW: CGFloat) -> some View {
        let list = (c.epgId.flatMap { byEpg[$0] } ?? []).filter { $0.stop > start && $0.start < start + span }
        return HStack(spacing: 0) {
            CardButton(action: { app.play(c) }, radius: Metrics.u(4), onLong: {
                let fav = store.favorites.contains(c.streamId)
                app.menu(c.name, [
                    NxAction("Guarda \(c.name)", icon: "play.fill") { app.play(c) },
                    NxAction(fav ? "Togli dai preferiti" : "Aggiungi ai preferiti", icon: fav ? "star.slash" : "star") { app.toggleFavorite(c) },
                ])
            }) {
                VStack(spacing: Metrics.u(3)) {
                    ChannelLogo(channel: c, height: Metrics.tv ? 22 : 20).frame(maxWidth: headW - Metrics.u(14), maxHeight: Metrics.u(26), alignment: .center)
                    if c.num > 0 { Text("\(c.num)").font(NxFont.ui(10, .bold)).foregroundStyle(NxColor.textDim) }
                }
                .frame(width: headW - gap, height: rowH)
                .background(NxColor.ink1, in: RoundedRectangle(cornerRadius: Metrics.u(4), style: .continuous))
            }
            .padding(.trailing, gap)
            ZStack(alignment: .topLeading) {
                if list.isEmpty {
                    cell(title: c.event ?? "Nessuna informazione", sub: c.eventStart.map { TimeText.time($0) } ?? c.eventSub, width: gridW, onAir: c.event != nil, past: false, progress: nil, action: { app.play(c) }, long: nil)
                }
                ForEach(list) { p in
                    let x0 = x(p.start, gridW), x1 = x(p.stop, gridW)
                    let s = store.showing(c, p)
                    let onAir = p.start <= now && p.stop > now
                    cell(title: s.cardTitle, sub: TimeText.time(p.start) + (s.cardLine.map { " · " + $0 } ?? ""), width: max(2, x1 - x0 - gap), onAir: onAir, past: p.stop <= now,
                         progress: onAir ? s.progress(now) : nil,
                         action: { if onAir { app.play(c) } else { app.openShowing(s) } },
                         long: {
                             var a = [NxAction("Dettagli", icon: "info.circle") { app.openShowing(s) }]
                             if onAir { a.insert(NxAction("Guarda \(c.name)", icon: "play.fill") { app.play(c) }, at: 0) }
                             if p.start > now { a.append(NxAction(store.reminders.contains(c.streamId) ? "Togli il promemoria" : "Avvisami quando inizia", icon: "bell") { app.toggleReminder(s) }) }
                             app.menu(s.cardTitle, a)
                         })
                        .offset(x: x0)
                }
                if isNow { Rectangle().fill(NxColor.accent).frame(width: Metrics.u(1.5), height: rowH).offset(x: x(now, gridW)).allowsHitTesting(false) }
            }
            .frame(width: gridW, height: rowH, alignment: .topLeading)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func cell(title: String, sub: String?, width: CGFloat, onAir: Bool, past: Bool, progress: Double?, action: @escaping () -> Void, long: (() -> Void)?) -> some View {
        CardButton(action: action, radius: Metrics.u(4), onLong: long) {
            ZStack(alignment: .bottomLeading) {
                (onAir ? NxColor.ink4 : NxColor.ink2)
                if width > Metrics.u(40) {
                    VStack(alignment: .leading, spacing: Metrics.u(2)) {
                        Text(title).font(NxFont.ui(13, .bold)).foregroundStyle(past ? NxColor.textDim : NxColor.text).lineLimit(width < Metrics.u(110) ? 2 : 1)
                        if let s = sub, width >= Metrics.u(110) || Metrics.tv { Text(s).font(NxFont.ui(11, .medium)).foregroundStyle(NxColor.textDim).lineLimit(1) }
                    }
                    .padding(.horizontal, Metrics.u(7)).padding(.vertical, Metrics.u(6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let p = progress { Rectangle().fill(NxColor.accent).frame(width: max(2, width * p), height: Metrics.u(2.5)) }
            }
            .frame(width: width, height: rowH)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.u(4), style: .continuous))
        }
    }

    private func load() async {
        let ids = channels.compactMap { $0.epgId }
        let from = start, to = start + span
        let db = app.core.db
        let list = await Task.detached(priority: .userInitiated) { db.programmesForChannels(ids, from, to) }.value
        if Task.isCancelled { return }
        byEpg = list.grouped { $0.epgId }
    }
}
