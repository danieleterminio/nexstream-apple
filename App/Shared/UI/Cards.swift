import SwiftUI

/// Apple TV: what the remote is on, so the top of the page can describe it (the title, the plot, the artwork).
@MainActor
final class FocusHub: ObservableObject {
    static let shared = FocusHub()
    @Published private(set) var item: HeroItem? = nil
    private var pending: Task<Void, Never>? = nil
    private init() {}
    /// Debounced: flying over a row must not load one backdrop per card.
    func focus(_ i: HeroItem) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            if Task.isCancelled { return }
            self?.item = i
        }
    }
    func clear() { pending?.cancel(); item = nil }
}

/// A tappable card: a white frame and a lift under the Apple TV focus, a soft press on touch, a long press for the
/// menu on the phone.
struct CardButton<Label: View>: View {
    let action: () -> Void
    var radius: CGFloat = Metrics.radius
    var onFocus: (() -> Void)? = nil
    var onLong: (() -> Void)? = nil
    /// Apple TV: the play/pause key on the card plays it straight away (something playable).
    var onPlay: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    var body: some View {
        #if os(tvOS)
        Button(action: action) {
            Focusable(onFocus: onFocus) { focused in
                // docs/tv-experience.md §2: scale 1.06, a 6 pt white frame, a slight shadow
                label()
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white, lineWidth: focused ? 6 : 0))
                    .scaleEffect(focused ? 1.06 : 1)
                    .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: 16, y: 8)
                    .animation(.easeOut(duration: 0.16), value: focused)
            }
        }
        .buttonStyle(NxPlainStyle(scale: 1))
        .modifier(TvLongMenu(onLong: onLong))
        .onPlayPauseCommand(perform: onPlay)
        .nxRestorable()
        #else
        Button(action: action, label: label)
            .buttonStyle(NxPlainStyle(scale: 0.96))
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if let l = onLong { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); l() }
            })
        #endif
    }
}

#if os(tvOS)
/// Apple TV: holding select on a card opens its menu — the same lines the phone shows on a long press, built by the same
/// code, in the system's long-press menu (the one the focus engine knows how to open).
private struct TvLongMenu: ViewModifier {
    let onLong: (() -> Void)?
    @ObservedObject private var debug = TvLongDemo.shared

    func body(content: Content) -> some View {
        if let l = onLong {
            content
                .contextMenu {
                    let m = AppModel.shared.captureMenu(l)
                    if let t = m.title { Text(t) }
                    ForEach(m.actions) { a in
                        Button(role: a.destructive ? .destructive : nil, action: a.action) {
                            if let i = a.icon { Label(a.title, systemImage: i) } else { Text(a.title) }
                        }
                    }
                }
                .onAppear { debug.offer(l) }
        } else { content }
    }
}

/// Launch argument `-nxLongFirst`: a few seconds after start, the first card with a menu opens it as our own panel, so
/// the build pipeline can take a picture of what a long press offers (the simulator cannot hold the remote's select).
@MainActor
final class TvLongDemo: ObservableObject {
    static let shared = TvLongDemo()
    private var done = !Demo.args.contains("-nxLongFirst")
    func offer(_ open: @escaping () -> Void) {
        if done { return }
        done = true
        Task { try? await Task.sleep(nanoseconds: 9_000_000_000); open() }
    }
}
#endif

/// Our own card for a match: the two crests on the competition's colours, instead of a broadcaster graphic full of text.
struct MatchArt: View {
    let match: Match
    var competition: String? = nil
    @ObservedObject private var crests = CrestsWatcher.shared

    var body: some View {
        let pair = Crests.pair(match.home, match.away)
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1B2A4A), Color(hex: 0x0F1424)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [NxColor.accent.opacity(0.28), .clear], center: .bottomTrailing, startRadius: 0, endRadius: g.size.width * 0.8)
                HStack(spacing: g.size.width * 0.07) {
                    crest(pair.0, match.home, g.size.height * 0.46)
                    Text("–").font(NxFont.display(18, .bold)).foregroundStyle(Color.white.opacity(0.5))
                    crest(pair.1, match.away, g.size.height * 0.46)
                }
            }
        }
    }

    @ViewBuilder private func crest(_ url: String?, _ name: String, _ size: CGFloat) -> some View {
        if let u = url {
            NxImage(u, fit: true, maxPixel: 320).frame(width: size, height: size)
        } else {
            Text(String(name.prefix(3)).uppercased()).font(Font.custom("Sora-Regular_Bold", fixedSize: size * 0.34)).foregroundStyle(.white)
                .frame(width: size, height: size).background(Color.white.opacity(0.10), in: Circle())
        }
    }
}

/// Lets SwiftUI views refresh when the crest list is loaded.
final class CrestsWatcher: ObservableObject {
    static let shared = CrestsWatcher()
    @Published var version = 0
    private var watch: Watch?
    private init() { watch = onMain(Crests.version) { [weak self] v in self?.version = v } }
}

/// The picture of a "thing on TV": the still, or our match card, or an ident with the channel logo when there is no art.
struct ShowingArt: View {
    let showing: Showing
    var hero: Bool = false
    var body: some View {
        if let m = showing.match, showing.meta == nil {
            MatchArt(match: m, competition: showing.competition)
        } else if let img = hero ? Img.hero(showing.image) : Img.card(showing.image) {
            NxImage(url: img, maxPixel: hero ? 1600 : 800) { ident }
        } else { ident }
    }
    private var ident: some View {
        ZStack {
            LinearGradient(colors: [NxColor.ink4, NxColor.ink2], startPoint: .topLeading, endPoint: .bottomTrailing)
            ChannelLogo(channel: showing.channel, height: 34).padding(Metrics.u(18))
        }
    }
}

/// Tags of a showing: DIRETTA (red), PRIMA TV (gold), the kind.
struct ShowingTags: View {
    let showing: Showing
    var showKind = true
    var body: some View {
        HStack(spacing: Metrics.u(6)) {
            if showing.isLiveBroadcast && showing.isLive() { NxTag(text: "Diretta", color: NxColor.accent) }
            else if showing.isLive() { NxTag(text: "In onda") }
            if showing.firstRun { NxTag(text: "Prima TV", color: NxColor.gold, fg: .black) }
            if showKind, let k = showing.kindLabel { NxTag(text: k) }
        }
    }
}

enum ShowCardStyle { case wide, compact }

/// Card of a programme / event: picture with the channel on it, then the title and when it is on.
struct ShowCard: View {
    let showing: Showing
    var style: ShowCardStyle = .wide
    var favorite: Bool = false
    var reminder: Bool = false
    let onTap: () -> Void
    @EnvironmentObject var app: AppModel

    private var width: CGFloat { style == .wide ? Metrics.showCardW : Metrics.channelCardW }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.u(6)) {
            CardButton(action: onTap, onFocus: { FocusHub.shared.focus(.live(showing)) }, onLong: { menu() },
                       onPlay: showing.isLive() || showing.programme == nil ? { app.play(showing.channel) } : nil) {
                ZStack(alignment: .bottomLeading) {
                    ShowingArt(showing: showing)
                    NxColor.cardFade.opacity(0.7)
                    VStack(alignment: .leading, spacing: Metrics.u(5)) {
                        HStack(alignment: .top) {
                            ChannelLogo(channel: showing.channel, height: 18)
                            Spacer(minLength: 4)
                            if reminder { Image(systemName: "bell.fill").font(.system(size: 11 * Metrics.type)).foregroundStyle(NxColor.gold) }
                            if favorite { Image(systemName: "star.fill").font(.system(size: 11 * Metrics.type)).foregroundStyle(.white) }
                        }
                        Spacer(minLength: 0)
                        ShowingTags(showing: showing, showKind: false)
                        if let p = showing.progress(), showing.isLive() { NxProgressBar(value: p) }
                    }
                    .padding(Metrics.u(8))
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Metrics.u(1)) {
                Text(showing.cardTitle).font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.text).lineLimit(1)
                Text([showing.whenLabel(), showing.cardLine].compactMap { $0 }.joined(separator: " · "))
                    .font(NxFont.ui(11, .medium)).foregroundStyle(NxColor.textDim).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private func menu() {
        var a = [NxAction]()
        let c = showing.channel
        if showing.isLive() || showing.programme == nil { a.append(NxAction("Guarda \(c.name)", icon: "play.fill") { app.play(c) }) }
        a.append(NxAction("Dettagli", icon: "info.circle") { app.openShowing(showing) })
        a.append(NxAction(favorite ? "Togli \(c.name) dai preferiti" : "Aggiungi \(c.name) ai preferiti", icon: favorite ? "star.slash" : "star") { app.toggleFavorite(c) })
        if !showing.isLive(), showing.start != nil { a.append(NxAction(reminder ? "Togli il promemoria" : "Avvisami quando inizia", icon: reminder ? "bell.slash" : "bell") { app.toggleReminder(showing) }) }
        app.menu(showing.cardTitle, a)
    }
}

/// Channel tile: the still of what is on air fills the card, the channel's logo on it, title and time left below.
struct ChannelCard: View {
    let showing: Showing
    var favorite: Bool = false
    var width: CGFloat = Metrics.channelCardW
    let onTap: () -> Void
    @EnvironmentObject var app: AppModel

    var body: some View {
        let w = width
        VStack(alignment: .leading, spacing: Metrics.u(6)) {
            CardButton(action: onTap, onFocus: { FocusHub.shared.focus(.live(showing)) }, onLong: { menu() }, onPlay: onTap) {
                ZStack(alignment: .bottomLeading) {
                    ShowingArt(showing: showing)
                    NxColor.cardFade.opacity(0.7)
                    VStack(alignment: .leading, spacing: Metrics.u(5)) {
                        HStack(alignment: .top) {
                            ChannelLogo(channel: showing.channel, height: 18)
                            Spacer(minLength: 4)
                            if favorite { Image(systemName: "star.fill").font(.system(size: 11 * Metrics.type)).foregroundStyle(.white) }
                        }
                        Spacer(minLength: 0)
                        if showing.isLiveBroadcast && showing.isLive() { NxTag(text: "Diretta", color: NxColor.accent) }
                        if let p = showing.progress() { NxProgressBar(value: p) }
                    }
                    .padding(Metrics.u(8))
                }
                .frame(width: w, height: w * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Metrics.u(1)) {
                Text(showing.programme == nil && showing.channel.event == nil ? showing.channel.name : showing.cardTitle)
                    .font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.text).lineLimit(1)
                Text(showing.programme == nil ? (showing.channel.eventSub ?? showing.channel.name) : (showing.whenLabel() ?? ""))
                    .font(NxFont.ui(11, .medium)).foregroundStyle(NxColor.textDim).lineLimit(1)
            }
            .frame(width: w, alignment: .leading)
        }
    }

    private func menu() {
        let c = showing.channel
        app.menu(c.name, [
            NxAction("Guarda \(c.name)", icon: "play.fill") { app.play(c) },
            NxAction("Dettagli del programma", icon: "info.circle") { app.openShowing(showing) },
            NxAction(favorite ? "Togli dai preferiti" : "Aggiungi ai preferiti", icon: favorite ? "star.slash" : "star") { app.toggleFavorite(c) },
        ])
    }
}

/// Poster of an on-demand title (2:3), with what the viewer needs on it: progress, "Nuovo", the Top 10 place.
struct PosterCard: View {
    let title: TmdbTitle
    var overlay: CardOverlay? = nil
    var rank: Int? = nil
    var inList: Bool = false
    var width: CGFloat = Metrics.posterW
    var menu: Bool = true
    let onTap: () -> Void
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if let r = rank {
                Text("\(r)").font(Font.custom("Sora-Regular_ExtraBold", fixedSize: width * (r >= 10 ? 0.78 : 0.98)))
                    .tracking(r >= 10 ? -width * 0.09 : 0)
                    .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.92), Color.white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, -width * 0.13)
                    .padding(.bottom, -width * 0.14)
                    .allowsHitTesting(false)
            }
            CardButton(action: onTap, onFocus: { FocusHub.shared.focus(.vod(title, nil)) }, onLong: menu ? { openMenu() } : nil,
                       onPlay: menu ? { app.playTitle(title) } : nil) {
                ZStack(alignment: .bottomLeading) {
                    NxImage(url: Img.tmdb(title.posterPath, "w342"), maxPixel: 500) {
                        ZStack {
                            NxColor.ink3
                            Text(title.displayTitle).font(NxFont.caption).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).padding(8)
                        }
                    }
                    if overlay?.progress != nil || overlay?.label != nil { NxColor.cardFade.opacity(0.8) }
                    VStack(alignment: .leading, spacing: Metrics.u(4)) {
                        HStack(alignment: .top) {
                            if let b = overlay?.badge { NxTag(text: b, color: NxColor.accent) }
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                        if let l = overlay?.label { Text(l).font(NxFont.label).foregroundStyle(.white) }
                        if let p = overlay?.progress { NxProgressBar(value: p) }
                    }
                    .padding(Metrics.u(6))
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            }
        }
        .accessibilityLabel(title.displayTitle)
    }

    private func openMenu() { app.menu(title.displayTitle, app.titleActions(title, inList: inList)) }
}

/// Landscape card of an on-demand title: what was left half way (play on it, the progress under it), coming soon.
struct LandscapeTitleCard: View {
    let title: TmdbTitle
    var overlay: CardOverlay? = nil
    var caption: String? = nil
    var play: Bool = false
    let onTap: () -> Void
    @EnvironmentObject var app: AppModel

    var body: some View {
        let w = Metrics.showCardW * 0.82
        VStack(alignment: .leading, spacing: Metrics.u(6)) {
            CardButton(action: onTap, onFocus: { FocusHub.shared.focus(.vod(title, nil)) }, onLong: {
                app.menu(title.displayTitle, app.titleActions(title, inList: app.store.listKeys.contains(title.key), play: play ? onTap : nil))
            }, onPlay: play ? onTap : { app.playTitle(title) }) {
                ZStack(alignment: .bottom) {
                    NxImage(url: Img.tmdb(title.backdropPath ?? title.posterPath, "w780"), maxPixel: 800) { NxColor.ink3 }
                    if play {
                        Image(systemName: "play.fill").font(.system(size: 17 * Metrics.unit, weight: .bold)).foregroundStyle(.white)
                            .frame(width: Metrics.u(42), height: Metrics.u(42))
                            .background(Color.black.opacity(0.5), in: Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: Metrics.u(1.5)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let p = overlay?.progress { NxProgressBar(value: p, height: 3) }
                }
                .frame(width: w, height: w * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Metrics.u(1)) {
                Text(title.displayTitle).font(NxFont.ui(13, .bold)).foregroundStyle(NxColor.text).lineLimit(1)
                if let c = overlay?.label ?? caption { Text(c).font(NxFont.ui(11, .medium)).foregroundStyle(NxColor.textDim).lineLimit(1) }
            }
            .frame(width: w, alignment: .leading)
        }
    }
}

/// A titled horizontal row of cards.
struct CardRow<Data: RandomAccessCollection, Card: View>: View where Data.Element: Identifiable {
    let title: String
    var sub: String? = nil
    var tag: String? = nil
    let items: Data
    /// Called when the last cards come into view (endless rows).
    var onEnd: (() -> Void)? = nil
    @ViewBuilder var card: (Data.Element) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.u(8)) {
            SectionHeader(title: title, sub: sub, tag: tag)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.cardGap) {
                    ForEach(items) { item in card(item) }
                    if let end = onEnd { Color.clear.frame(width: 1, height: 1).onAppear(perform: end) }
                }
                .padding(.horizontal, Metrics.gutter)
                #if os(tvOS)
                .padding(.vertical, 22)
                #else
                .padding(.vertical, 2)
                #endif
            }
            .scrollClipDisabled()
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }
}

/// A row of on-demand titles in the shape its kind asks for.
struct VodRowView: View {
    let row: VodRow
    var overlays: [String: CardOverlay] = [:]
    var tag: String? = nil
    var sub: String? = nil
    var title: String? = nil
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore

    var body: some View {
        CardRow(title: title ?? row.title, sub: sub, tag: tag, items: row.items) { t in
            if row.kind == .continue || row.kind == .landscape {
                LandscapeTitleCard(title: t, overlay: overlays[t.key], caption: row.kind == .landscape ? t.date : nil, play: row.kind == .continue) {
                    // "Stavi guardando su…": from the episode and the point the other device reached
                    if row.id == "other-devices" { app.playOther(t) }
                    else if row.kind == .continue { app.playTitle(t) } else { app.openTitle(t) }
                }
            } else {
                PosterCard(title: t, overlay: overlays[t.key], rank: row.kind == .top10 ? (row.items.firstIndex(of: t).map { $0 + 1 }) : nil, inList: store.listKeys.contains(t.key)) { app.openTitle(t) }
            }
        }
    }
}
