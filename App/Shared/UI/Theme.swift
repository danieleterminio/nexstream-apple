import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Brand tokens 3.1: crimson on neutral ink. Red is for state (live, progress, selection), never decoration.
enum NxColor {
    static let accent = Color(hex: 0xE5173F)
    static let accentDeep = Color(hex: 0xB30F30)
    static let accentBright = Color(hex: 0xFF4B3A)
    static let ember = Color(hex: 0xFF7A1A)
    static let ink0 = Color(hex: 0x07070A)
    static let ink1 = Color(hex: 0x0D0D12)
    static let ink2 = Color(hex: 0x15151C)
    static let ink3 = Color(hex: 0x1E1E27)
    static let ink4 = Color(hex: 0x2A2A35)
    static let ink5 = Color(hex: 0x3A3A47)
    static let bg = Color(hex: 0x0D0D12)
    static let text = Color(hex: 0xF5F5F8)
    static let textMuted = Color(hex: 0xB8B8C4)
    static let textDim = Color(hex: 0x8A8A99)
    static let success = Color(hex: 0x2BD67B)
    static let warning = Color(hex: 0xFFB020)
    static let gold = Color(hex: 0xFFC94D)
    static let kids = Color(hex: 0x3DA9FC)
    static let hairline = Color.white.opacity(0.12)
    static let glass = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.28)
    static let brand = LinearGradient(colors: [accent, accentBright, ember], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Left-to-right scrim that keeps the hero text readable over any artwork.
    static let heroScrim = LinearGradient(stops: [.init(color: ink1, location: 0), .init(color: ink1.opacity(0.94), location: 0.28), .init(color: ink1.opacity(0.62), location: 0.48), .init(color: ink1.opacity(0.12), location: 0.70), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
    static let heroFade = LinearGradient(stops: [.init(color: .clear, location: 0.40), .init(color: ink1.opacity(0.85), location: 0.82), .init(color: ink1, location: 1)], startPoint: .top, endPoint: .bottom)
    static let cardFade = LinearGradient(stops: [.init(color: .clear, location: 0.30), .init(color: .black.opacity(0.55), location: 0.62), .init(color: .black.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom)
}

/// The two brand typefaces (variable fonts shipped with the app): Sora for display, Manrope for everything else.
enum NxFont {
    enum Weight { case regular, medium, semibold, bold, heavy }
    static func ui(_ size: CGFloat, _ w: Weight = .regular) -> Font {
        let name: String
        switch w { case .regular: name = "Manrope-Regular"; case .medium: name = "Manrope-Medium"; case .semibold: name = "Manrope-SemiBold"; case .bold: name = "Manrope-Bold"; case .heavy: name = "Manrope-ExtraBold" }
        return Font.custom(name, fixedSize: size * Metrics.type)
    }
    static func display(_ size: CGFloat, _ w: Weight = .bold) -> Font {
        let name: String
        switch w { case .regular, .medium: name = "Sora-Regular"; case .semibold: name = "Sora-Regular_SemiBold"; case .bold: name = "Sora-Regular_Bold"; case .heavy: name = "Sora-Regular_ExtraBold" }
        return Font.custom(name, fixedSize: size * Metrics.type)
    }
    static var hero: Font { display(34, .heavy) }
    static var titleXL: Font { display(28, .bold) }
    static var titleL: Font { display(22, .bold) }
    static var titleM: Font { display(17, .semibold) }
    static var rowTitle: Font { display(16, .semibold) }
    static var body: Font { ui(15) }
    static var bodyStrong: Font { ui(15, .semibold) }
    static var button: Font { ui(15, .bold) }
    static var meta: Font { ui(13, .medium) }
    static var caption: Font { ui(12, .medium) }
    static var label: Font { ui(11, .bold) }
}

/// One set of sizes for both screens: the Apple TV canvas is 1920×1080 points watched from the sofa, so everything is
/// about twice the size it has on a phone.
enum Metrics {
    #if os(tvOS)
    static let tv = true
    static let type: CGFloat = 1.9
    static let unit: CGFloat = 2.0
    static let gutter: CGFloat = 80
    static let showCardW: CGFloat = 420
    static let channelCardW: CGFloat = 340
    static let posterW: CGFloat = 250
    static let rowGap: CGFloat = 40
    static let cardGap: CGFloat = 36
    static let radius: CGFloat = 20
    #else
    static let tv = false
    static let type: CGFloat = 1.0
    static let unit: CGFloat = 1.0
    static let gutter: CGFloat = 16
    static let showCardW: CGFloat = 250
    static let channelCardW: CGFloat = 190
    static let posterW: CGFloat = 122
    static let rowGap: CGFloat = 26
    static let cardGap: CGFloat = 12
    static let radius: CGFloat = 14
    #endif
    static func u(_ v: CGFloat) -> CGFloat { v * unit }
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

// ---------------------------------------------------------------------------------------------------------------- glass

extension View {
    /// A Liquid Glass surface in the given shape (panels, chips, bars).
    func nxGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }
    func nxGlassPanel(radius: CGFloat = Metrics.radius + 6) -> some View {
        glassEffect(Glass.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    /// The page colour behind a screen.
    func nxPage() -> some View { background(NxColor.bg.ignoresSafeArea()) }
    /// Hides the system list / form background so the page colour shows (lists are already clear on Apple TV).
    @ViewBuilder func nxClearList() -> some View {
        #if os(iOS)
        scrollContentBackground(.hidden)
        #else
        self
        #endif
    }
    @ViewBuilder func `if`<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// What a button is for. White means "press here": the one main action of a page. Everything else is glass.
enum NxButtonKind { case primary, secondary, quiet, danger }

struct NxButton: View {
    let title: String
    var icon: String? = nil
    var kind: NxButtonKind = .secondary
    var wide: Bool = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, kind: NxButtonKind = .secondary, wide: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.kind = kind; self.wide = wide; self.action = action
    }

    private var label: some View {
        HStack(spacing: Metrics.u(8)) {
            if let i = icon { Image(systemName: i).font(.system(size: 15 * Metrics.type, weight: .bold)) }
            Text(title).font(NxFont.button).lineLimit(1)
        }
        .frame(maxWidth: wide ? .infinity : nil)
        #if os(iOS)
        .padding(.horizontal, 6).padding(.vertical, 5)
        #endif
    }

    var body: some View {
        #if os(tvOS)
        // on the TV the focus is what turns a button white: at rest every button is glass
        Button(action: action) { label }.buttonStyle(.glass)
        #else
        switch kind {
        case .primary: Button(action: action) { label.foregroundStyle(NxColor.ink0) }.buttonStyle(.glassProminent).tint(.white)
        case .danger: Button(role: .destructive, action: action) { label }.buttonStyle(.glass)
        case .secondary, .quiet: Button(action: action) { label.foregroundStyle(NxColor.text) }.buttonStyle(.glass)
        }
        #endif
    }
}

/// Round glass button with a symbol (back, favourite, list, options).
struct NxIconButton: View {
    let icon: String
    var label: String = ""
    var active: Bool = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42 * Metrics.unit, weight: .semibold))
                .foregroundStyle(active ? NxColor.accent : NxColor.text)
                .frame(width: Metrics.u(size), height: Metrics.u(size))
        }
        #if os(tvOS)
        .buttonStyle(.glass)
        #else
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.interactive(), in: Circle())
        #endif
        .accessibilityLabel(label)
    }
}

/// Small state label: DIRETTA (red), PRIMA TV (gold), neutral kinds.
struct NxTag: View {
    let text: String
    var color: Color = Color.white.opacity(0.16)
    var fg: Color = .white
    var body: some View {
        Text(text.uppercased())
            .font(NxFont.label).tracking(0.6).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, Metrics.u(7)).padding(.vertical, Metrics.u(3))
            .background(color, in: RoundedRectangle(cornerRadius: Metrics.u(5), style: .continuous))
    }
}

struct QualityBadge: View {
    let quality: String
    var body: some View {
        let q = quality == "UHD" ? "4K" : quality
        if !q.isEmpty && q != "?" {
            Text(q).font(NxFont.label).foregroundStyle(NxColor.textMuted)
                .padding(.horizontal, Metrics.u(6)).padding(.vertical, Metrics.u(2))
                .overlay(RoundedRectangle(cornerRadius: Metrics.u(4)).stroke(NxColor.textDim, lineWidth: 1))
        }
    }
}

struct NxProgressBar: View {
    let value: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(NxColor.track)
                Capsule().fill(NxColor.accent).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: Metrics.u(height))
    }
}

/// Selectable chip (genres, days, seasons).
struct NxChip: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.u(6)) {
                if let i = icon { Image(systemName: i).font(.system(size: 12 * Metrics.type, weight: .semibold)) }
                Text(title).font(NxFont.ui(13, selected ? .bold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : NxColor.textMuted)
            .padding(.horizontal, Metrics.u(14)).padding(.vertical, Metrics.u(8))
        }
        #if os(tvOS)
        .buttonStyle(.glass)
        .tint(selected ? NxColor.accent : nil)
        #else
        .buttonStyle(.plain)
        .glassEffect(selected ? Glass.regular.tint(NxColor.accent).interactive() : Glass.regular.interactive(), in: Capsule())
        #endif
    }
}

/// Title of a row or of a page section, with an optional quieter note beside it.
struct SectionHeader: View {
    let title: String
    var sub: String? = nil
    var tag: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.u(10)) {
            Text(title).font(NxFont.rowTitle).foregroundStyle(NxColor.text).lineLimit(1)
            if let t = tag { NxTag(text: t) }
            if let s = sub { Text(s).font(NxFont.caption).foregroundStyle(NxColor.textDim).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

/// What a page says when it has nothing to show, or something went wrong.
struct StateMessage: View {
    let icon: String
    let title: String
    var text: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: Metrics.u(12)) {
            Image(systemName: icon).font(.system(size: 40 * Metrics.unit, weight: .light)).foregroundStyle(NxColor.textDim)
            Text(title).font(NxFont.titleM).foregroundStyle(NxColor.text).multilineTextAlignment(.center)
            if let t = text { Text(t).font(NxFont.body).foregroundStyle(NxColor.textDim).multilineTextAlignment(.center) }
            if let a = actionTitle, let act = action { NxButton(a, kind: .primary, action: act).padding(.top, Metrics.u(6)) }
        }
        .padding(Metrics.u(32))
        .frame(maxWidth: Metrics.u(520))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The brand mark as the loading indicator: the two waves light up in turn ("Segnale").
struct BrandLoader: View {
    var size: CGFloat = 56
    var label: String? = nil
    @State private var phase = 0.0
    var body: some View {
        VStack(spacing: Metrics.u(14)) {
            Image("BrandSymbol").resizable().scaledToFit().frame(width: Metrics.u(size), height: Metrics.u(size))
                .opacity(0.55 + 0.45 * phase)
                .scaleEffect(0.96 + 0.04 * phase)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 } }
            if let l = label { Text(l).font(NxFont.meta).foregroundStyle(NxColor.textMuted).multilineTextAlignment(.center) }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- avatars

enum Avatars {
    /// Avatar palette (gradients). Indices are stored in the profile: only append. Same list as the Android app.
    static let colors: [[UInt32]] = [
        [0x1F7AFF, 0x36D1FF], [0xE5173F, 0xFF7A1A], [0x2BD67B, 0x0E8F7A], [0x7A5CFF, 0x3DA9FC], [0xFFB020, 0xE5173F], [0xFF5F6D, 0xFFC371],
        [0x2193B0, 0x6DD5ED], [0x8E2DE2, 0x4A00E0], [0x00B09B, 0x96C93D], [0xEE0979, 0xFF6A00], [0x485563, 0x29323C], [0xF7971E, 0xFFD200],
        [0x00C6FF, 0x0072FF, 0x7F00FF], [0xB91D73, 0xF953C6], [0x134E5E, 0x71B280], [0xE5173F, 0xFF7A1A, 0xFFC94D],
    ]
    /// Avatar icons (index 0 = the name's initial), in the order of the Android app.
    static let icons: [String?] = [
        nil, "face.smiling.fill", "pawprint.fill", "airplane", "gamecontroller.fill", "soccerball",
        "music.note", "star.fill", "heart.fill", "film.fill", "tv.fill", "fork.knife",
        "bolt.fill", "headphones", "paintpalette.fill", "camera.fill", "bicycle",
        "leaf.fill", "snowflake", "basketball.fill", "tennisball.fill", "sparkles",
        "diamond.fill", "birthday.cake.fill",
    ]
    static let maturityLabels = ["Bambini", "Ragazzi 13+", "Tutti"]
    static func gradient(_ i: Int) -> LinearGradient {
        let c = colors[max(0, i) % colors.count].map { Color(hex: $0) }
        return LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The face of a profile, the same everywhere: its gradient, the icon or the initial in white.
struct AvatarFace: View {
    let name: String
    let color: Int
    let kids: Bool
    let icon: Int
    var size: CGFloat = 40

    var body: some View {
        let s = Metrics.u(size)
        let symbol: String? = (icon > 0 && icon < Avatars.icons.count) ? Avatars.icons[icon] : (kids ? "figure.and.child.holdinghands" : nil)
        ZStack {
            Avatars.gradient(color)
            LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .topLeading, endPoint: .center)
            if let sym = symbol {
                Image(systemName: sym).font(.system(size: s * 0.46, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(String(name.prefix(1)).uppercased()).font(Font.custom("Sora-Regular_Bold", fixedSize: s * 0.46)).foregroundStyle(.white)
            }
        }
        .frame(width: s, height: s)
        .clipShape(RoundedRectangle(cornerRadius: s * 0.26, style: .continuous))
    }
}

extension ProfileEntity {
    func face(_ size: CGFloat = 40) -> AvatarFace { AvatarFace(name: name, color: avatarColor, kids: kids, icon: avatarIcon, size: size) }
}
