import SwiftUI

/// A tappable card with the platform's own feedback: the lift and glow of the Apple TV focus, a soft press on touch.
struct CardButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        #if os(tvOS)
        Button(action: action, label: label).buttonStyle(.card)
        #else
        Button(action: action, label: label).buttonStyle(PressScaleStyle())
        #endif
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

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
    var onPlay: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil
    var onReminder: (() -> Void)? = nil

    private var width: CGFloat { style == .wide ? Metrics.showCardW : Metrics.channelCardW }

    var body: some View {
        CardButton(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    ShowingArt(showing: showing)
                    NxColor.cardFade.opacity(0.75)
                    VStack(alignment: .leading, spacing: Metrics.u(6)) {
                        HStack(alignment: .top) {
                            ChannelLogo(channel: showing.channel, height: 20)
                            Spacer(minLength: 4)
                            if reminder { Image(systemName: "bell.fill").font(.system(size: 12 * Metrics.type)).foregroundStyle(NxColor.gold) }
                            if favorite { Image(systemName: "star.fill").font(.system(size: 12 * Metrics.type)).foregroundStyle(.white) }
                        }
                        Spacer(minLength: 0)
                        ShowingTags(showing: showing, showKind: false)
                        if let p = showing.progress(), showing.isLive() { NxProgressBar(value: p) }
                    }
                    .padding(Metrics.u(10))
                }
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                VStack(alignment: .leading, spacing: Metrics.u(2)) {
                    Text(showing.cardTitle).font(NxFont.bodyStrong).foregroundStyle(NxColor.text).lineLimit(1)
                    Text([showing.whenLabel(), showing.cardLine].compactMap { $0 }.joined(separator: " · "))
                        .font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1)
                }
                .padding(.horizontal, Metrics.u(10)).padding(.vertical, Metrics.u(8))
                .frame(width: width, alignment: .leading)
                .background(NxColor.ink2)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        }
        .contextMenu {
            if let play = onPlay, showing.isLive() || showing.programme == nil { Button(action: play) { Label("Guarda \(showing.channel.name)", systemImage: "play.fill") } }
            if let fav = onFavorite { Button(action: fav) { Label(favorite ? "Togli dai preferiti" : "Aggiungi ai preferiti", systemImage: favorite ? "star.slash" : "star") } }
            if let rem = onReminder, !showing.isLive(), showing.start != nil { Button(action: rem) { Label(reminder ? "Togli il promemoria" : "Avvisami quando inizia", systemImage: reminder ? "bell.slash" : "bell") } }
        }
    }
}

/// Channel tile: the still of what is on air fills the card, the channel's logo on it, title and time left below.
struct ChannelCard: View {
    let showing: Showing
    var favorite: Bool = false
    let onTap: () -> Void
    var onInfo: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil

    var body: some View {
        let w = Metrics.channelCardW
        CardButton(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    ShowingArt(showing: showing)
                    NxColor.cardFade.opacity(0.7)
                    VStack(alignment: .leading, spacing: Metrics.u(5)) {
                        HStack(alignment: .top) {
                            ChannelLogo(channel: showing.channel, height: 20)
                            Spacer(minLength: 4)
                            if favorite { Image(systemName: "star.fill").font(.system(size: 12 * Metrics.type)).foregroundStyle(.white) }
                        }
                        Spacer(minLength: 0)
                        if showing.isLiveBroadcast && showing.isLive() { NxTag(text: "Diretta", color: NxColor.accent) }
                        if let p = showing.progress() { NxProgressBar(value: p) }
                    }
                    .padding(Metrics.u(9))
                }
                .frame(width: w, height: w * 9 / 16)
                .clipped()
                VStack(alignment: .leading, spacing: Metrics.u(2)) {
                    Text(showing.programme == nil && showing.channel.event == nil ? showing.channel.name : showing.cardTitle)
                        .font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.text).lineLimit(1)
                    Text(showing.programme == nil ? (showing.channel.eventSub ?? "Nessuna guida") : (showing.whenLabel() ?? ""))
                        .font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1)
                }
                .padding(.horizontal, Metrics.u(9)).padding(.vertical, Metrics.u(7))
                .frame(width: w, alignment: .leading)
                .background(NxColor.ink2)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        }
        .contextMenu {
            if let info = onInfo { Button(action: info) { Label("Dettagli del programma", systemImage: "info.circle") } }
            if let fav = onFavorite { Button(action: fav) { Label(favorite ? "Togli dai preferiti" : "Aggiungi ai preferiti", systemImage: favorite ? "star.slash" : "star") } }
        }
    }
}

/// Poster of an on-demand title (2:3), with what the viewer needs on it: progress, "Nuovo", the Top 10 place.
struct PosterCard: View {
    let title: TmdbTitle
    var overlay: CardOverlay? = nil
    var rank: Int? = nil
    var inList: Bool = false
    var width: CGFloat = Metrics.posterW
    let onTap: () -> Void
    var onPlay: (() -> Void)? = nil
    var onList: (() -> Void)? = nil

    var body: some View {
        CardButton(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                NxImage(url: Img.tmdb(title.posterPath, "w342"), maxPixel: 500) {
                    ZStack {
                        NxColor.ink3
                        Text(title.displayTitle).font(NxFont.caption).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center).padding(8)
                    }
                }
                if rank != nil || overlay?.progress != nil || overlay?.label != nil { NxColor.cardFade.opacity(0.8) }
                VStack(alignment: .leading, spacing: Metrics.u(4)) {
                    HStack(alignment: .top) {
                        if let b = overlay?.badge { NxTag(text: b, color: NxColor.accent) }
                        Spacer(minLength: 0)
                        if inList { Image(systemName: "bookmark.fill").font(.system(size: 12 * Metrics.type)).foregroundStyle(.white) }
                    }
                    Spacer(minLength: 0)
                    if let r = rank {
                        Text("\(r)").font(Font.custom("Sora-Regular_ExtraBold", fixedSize: width * 0.42)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 6)
                    }
                    if let l = overlay?.label { Text(l).font(NxFont.label).foregroundStyle(.white) }
                    if let p = overlay?.progress { NxProgressBar(value: p) }
                }
                .padding(Metrics.u(8))
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        }
        .contextMenu {
            if let play = onPlay { Button(action: play) { Label("Riproduci", systemImage: "play.fill") } }
            if let list = onList { Button(action: list) { Label(inList ? "Togli da Da guardare" : "Aggiungi a Da guardare", systemImage: inList ? "bookmark.slash" : "bookmark") } }
        }
        .accessibilityLabel(title.displayTitle)
    }
}

/// Landscape card of an on-demand title (continue watching, coming soon).
struct LandscapeTitleCard: View {
    let title: TmdbTitle
    var overlay: CardOverlay? = nil
    var caption: String? = nil
    let onTap: () -> Void
    var body: some View {
        let w = Metrics.showCardW * 0.86
        CardButton(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    NxImage(url: Img.tmdb(title.backdropPath ?? title.posterPath, "w780"), maxPixel: 800) { NxColor.ink3 }
                    NxColor.cardFade.opacity(0.7)
                    VStack(alignment: .leading, spacing: Metrics.u(4)) {
                        Spacer(minLength: 0)
                        if let l = overlay?.label { Text(l).font(NxFont.label).foregroundStyle(.white) }
                        if let p = overlay?.progress { NxProgressBar(value: p) }
                    }.padding(Metrics.u(9))
                }
                .frame(width: w, height: w * 9 / 16).clipped()
                VStack(alignment: .leading, spacing: Metrics.u(2)) {
                    Text(title.displayTitle).font(NxFont.ui(14, .semibold)).foregroundStyle(NxColor.text).lineLimit(1)
                    if let c = caption { Text(c).font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1) }
                }
                .padding(.horizontal, Metrics.u(9)).padding(.vertical, Metrics.u(7))
                .frame(width: w, alignment: .leading).background(NxColor.ink2)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
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
        VStack(alignment: .leading, spacing: Metrics.u(10)) {
            SectionHeader(title: title, sub: sub, tag: tag)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.cardGap) {
                    ForEach(items) { item in card(item) }
                    if let end = onEnd { Color.clear.frame(width: 1, height: 1).onAppear(perform: end) }
                }
                .padding(.horizontal, Metrics.gutter)
                #if os(tvOS)
                .padding(.vertical, 28)
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
                LandscapeTitleCard(title: t, overlay: overlays[t.key], caption: row.kind == .landscape ? t.date : nil) {
                    if row.kind == .continue { app.playTitle(t) } else { app.openTitle(t) }
                }
                .contextMenu { Button { app.openTitle(t) } label: { Label("Dettagli", systemImage: "info.circle") } }
            } else {
                PosterCard(title: t, overlay: overlays[t.key], rank: row.kind == .top10 ? (row.items.firstIndex(of: t).map { $0 + 1 }) : nil, inList: store.listKeys.contains(t.key),
                           onTap: { app.openTitle(t) }, onPlay: { app.playTitle(t) }, onList: { app.toggleList(t) })
            }
        }
    }
}
