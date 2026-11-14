import SwiftUI
import UIKit
import Combine

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Brand tokens 4.0: flat, black, quiet. White means "press here" (the main action, the focus on the TV); red is for
/// state only (live, progress, selection). No translucent materials anywhere.
enum NxColor {
    static let accent = Color(hex: 0xE5173F)
    static let accentDeep = Color(hex: 0xB30F30)
    static let accentBright = Color(hex: 0xFF4B3A)
    static let ember = Color(hex: 0xFF7A1A)
    static let ink0 = Color(hex: 0x000000)
    static let ink1 = Color(hex: 0x0B0B0B)
    static let ink2 = Color(hex: 0x161616)
    static let ink3 = Color(hex: 0x222222)
    static let ink4 = Color(hex: 0x2E2E2E)
    static let ink5 = Color(hex: 0x404040)
    static let bg = Color(hex: 0x000000)
    static let text = Color(hex: 0xFFFFFF)
    static let textMuted = Color(hex: 0xB8B8B8)
    static let textDim = Color(hex: 0x808080)
    static let success = Color(hex: 0x46D369)
    static let warning = Color(hex: 0xFFB020)
    static let gold = Color(hex: 0xFFC94D)
    static let kids = Color(hex: 0x3DA9FC)
    static let hairline = Color.white.opacity(0.12)
    /// Fill of a secondary button / chip at rest.
    static let button = Color(hex: 0x6D6D6E, alpha: 0.42)
    static let track = Color.white.opacity(0.28)
    static let brand = LinearGradient(colors: [accent, accentBright, ember], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Left-to-right scrim that keeps text readable over artwork on the TV.
    static let heroScrim = LinearGradient(stops: [.init(color: bg, location: 0), .init(color: bg.opacity(0.92), location: 0.30), .init(color: bg.opacity(0.55), location: 0.52), .init(color: bg.opacity(0.10), location: 0.74), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
    static let heroFade = LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: bg.opacity(0.80), location: 0.80), .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
    static let cardFade = LinearGradient(stops: [.init(color: .clear, location: 0.30), .init(color: .black.opacity(0.55), location: 0.62), .init(color: .black.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom)
    static let topFade = LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
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
    static var hero: Font { display(30, .heavy) }
    static var titleXL: Font { display(26, .bold) }
    static var titleL: Font { display(21, .bold) }
    static var titleM: Font { display(17, .semibold) }
    static var rowTitle: Font { ui(17, .heavy) }
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
    static let gutter: CGFloat = 60
    static let showCardW: CGFloat = 400
    static let channelCardW: CGFloat = 330
    static let posterW: CGFloat = 224
    static let rowGap: CGFloat = 34
    static let cardGap: CGFloat = 24
    static let radius: CGFloat = 10
    /// Room the collapsed side menu takes on the left of every page (docs/tv-experience.md §1: 84 dp / 168 pt).
    static let rail: CGFloat = 168
    /// The side menu with the focus in it, drawn over the page.
    static let railOpen: CGFloat = 600
    #else
    static let tv = false
    static let type: CGFloat = 1.0
    static let unit: CGFloat = 1.0
    // an iPad shows the same pages with more room: wider margins, bigger cards, more columns
    static let pad = UIDevice.current.userInterfaceIdiom == .pad
    static let gutter: CGFloat = pad ? 28 : 14
    static let showCardW: CGFloat = pad ? 310 : 236
    static let channelCardW: CGFloat = pad ? 226 : 168
    static let posterW: CGFloat = pad ? 156 : 112
    static let rowGap: CGFloat = pad ? 32 : 24
    static let cardGap: CGFloat = pad ? 12 : 8
    static let radius: CGFloat = pad ? 8 : 6
    static let rail: CGFloat = 0
    #endif
    /// Columns of a poster grid (search results, similar titles).
    static var posterColumns: Int { isPad ? 6 : 3 }
    static func u(_ v: CGFloat) -> CGFloat { v * unit }
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// Height of the phone's bottom bar (without the home indicator).
    static let tabBar: CGFloat = 54
}

// ---------------------------------------------------------------------------------------------------------------- basics

extension View {
    /// The page colour behind a screen.
    func nxPage() -> some View { background(NxColor.bg.ignoresSafeArea()) }
    @ViewBuilder func `if`<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
    /// A dark panel with a hairline (dialogs, the remote, forms).
    func nxPanel(radius: CGFloat = Metrics.u(12), fill: Color = NxColor.ink2) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(NxColor.hairline, lineWidth: 1))
    }
}

/// Gives a view the focus state of the button around it (Apple TV). On a phone it is always false.
struct Focusable<Content: View>: View {
    @Environment(\.isFocused) private var focused
    @Environment(\.nxRestoreKey) private var restoreKey
    var onFocus: (() -> Void)? = nil
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        #if os(tvOS)
        content(focused).onChange(of: focused) { _, f in
            if f { FocusMemory.noteFocus(restoreKey); onFocus?() }
        }
        #else
        content(false)
        #endif
    }
}

// ---------------------------------------------------------------------------------------------------------------- focus memory

/// Apple TV: where the focus was, so it can go back there — on the card that opened a page once the page is closed,
/// on the button that opened a panel once the panel is closed, on the page's last card when RIGHT leaves the side menu
/// (docs/tv-experience.md §2). Every button that can take the focus back (`nxRestorable`) has a key; the focus engine
/// itself does not offer this for our own panels, which are views drawn on top and not system presentations.
@MainActor
enum FocusMemory {
    /// Key of the last focused element outside the side menu (nil: one that cannot be focused again from code).
    private(set) static var last: String? = nil
    /// The focus is in the side menu.
    static var inRail = false
    static let restore = PassthroughSubject<String, Never>()

    static func noteFocus(_ key: String?) { last = key; inRail = false }
    /// Puts the focus back on the element with that key, if it is still on screen, after `delay` seconds (the time for
    /// a panel to go or a page to slide back).
    static func restore(_ key: String?, after delay: Double = 0.1) {
        guard let k = key else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            restore.send(k)
        }
    }
}

private struct NxRestoreKeyKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct NxFocusKeyKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The key of the restorable button around a label (read by `Focusable`).
    var nxRestoreKey: String? { get { self[NxRestoreKeyKey.self] } set { self[NxRestoreKeyKey.self] = newValue } }
    /// A fixed key asked from outside for the one restorable button inside (`nxFocusKey`).
    var nxFocusKey: String? { get { self[NxFocusKeyKey.self] } set { self[NxFocusKeyKey.self] = newValue } }
}

/// A button that `FocusMemory` can give the focus back to.
private struct NxRestorable: ViewModifier {
    var key: String? = nil
    @Environment(\.nxFocusKey) private var asked
    @State private var token = UUID().uuidString
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        let k: String = asked ?? key ?? token
        content
            .environment(\.nxRestoreKey, k)
            .focused($focused)
            .onReceive(FocusMemory.restore) { t in if t == k { focused = true } }
        #else
        content
        #endif
    }
}

extension View {
    /// Lets the focus come back to this button (Apple TV); `key`: a fixed name, for views that are built again.
    func nxRestorable(_ key: String? = nil) -> some View { modifier(NxRestorable(key: key)) }
    /// Gives the restorable button inside a fixed name.
    func nxFocusKey(_ key: String) -> some View { environment(\.nxFocusKey, key) }
}

/// Every button of the app goes through this: no system chrome, a soft press on touch.
struct NxPlainStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// What a button is for. White means "press here": the one main action of a page. On the TV white is the focus, so
/// every button rests grey and turns white when the remote is on it.
enum NxButtonKind { case primary, secondary, quiet, danger }

struct NxButton: View {
    let title: String
    var icon: String? = nil
    var kind: NxButtonKind = .secondary
    var wide: Bool = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, icon: String? = nil, kind: NxButtonKind = .secondary, wide: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.kind = kind; self.wide = wide; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Focusable { focused in
                let white = Metrics.tv ? focused : kind == .primary
                HStack(spacing: Metrics.u(7)) {
                    if let i = icon { Image(systemName: i).font(.system(size: 15 * Metrics.type, weight: .bold)) }
                    Text(title).font(NxFont.button).lineLimit(1)
                }
                .foregroundStyle(white ? Color.black : (kind == .danger ? NxColor.accentBright : Color.white))
                .fixedSize()
                .padding(.horizontal, Metrics.u(18))
                .frame(maxWidth: wide ? .infinity : nil)
                .frame(height: Metrics.u(Metrics.tv ? 36 : 42))
                .background(white ? Color.white : (kind == .quiet ? Color.clear : NxColor.button), in: RoundedRectangle(cornerRadius: Metrics.u(4), style: .continuous))
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
            }
        }
        .buttonStyle(NxPlainStyle())
        .nxRestorable()
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Round button with a symbol, over video or artwork (close, AirPlay, options).
struct NxIconButton: View {
    let icon: String
    var label: String = ""
    var active: Bool = false
    var size: CGFloat = 40
    var plain: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focusable { focused in
                Image(systemName: icon)
                    .font(.system(size: size * (plain ? 0.56 : 0.44) * Metrics.unit, weight: .semibold))
                    .foregroundStyle(focused ? Color.black : (active ? NxColor.accent : Color.white))
                    .frame(width: Metrics.u(size), height: Metrics.u(size))
                    .background(focused ? Color.white : (plain ? Color.clear : Color.black.opacity(0.45)), in: Circle())
                    .scaleEffect(focused ? 1.1 : 1)
                    .animation(.easeOut(duration: 0.15), value: focused)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// Symbol with its name under it: the secondary actions of a title (La mia lista, Mi piace, Scarica).
struct NxIconAction: View {
    let icon: String
    let label: String
    var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Focusable { focused in
                VStack(spacing: Metrics.u(5)) {
                    Image(systemName: icon).font(.system(size: 21 * Metrics.unit, weight: .regular)).frame(height: Metrics.u(26))
                    Text(label).font(NxFont.ui(11, .medium)).lineLimit(1)
                }
                .foregroundStyle(focused ? Color.black : (active ? Color.white : NxColor.textMuted))
                .frame(minWidth: Metrics.u(64))
                .padding(.vertical, Metrics.u(6)).padding(.horizontal, Metrics.u(6))
                .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.u(6), style: .continuous))
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.92))
        .nxRestorable()
    }
}

/// Small state label: DIRETTA (red), PRIMA TV (gold), neutral kinds.
struct NxTag: View {
    let text: String
    var color: Color = Color.white.opacity(0.18)
    var fg: Color = .white
    var body: some View {
        Text(text.uppercased())
            .font(NxFont.label).tracking(0.5).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, Metrics.u(6)).padding(.vertical, Metrics.u(2.5))
            .background(color, in: RoundedRectangle(cornerRadius: Metrics.u(3), style: .continuous))
    }
}

struct QualityBadge: View {
    let quality: String
    var body: some View {
        let q = quality == "UHD" ? "4K" : quality
        if !q.isEmpty && q != "?" {
            Text(q).font(NxFont.label).foregroundStyle(NxColor.textMuted)
                .padding(.horizontal, Metrics.u(5)).padding(.vertical, Metrics.u(1.5))
                .overlay(RoundedRectangle(cornerRadius: Metrics.u(3)).stroke(NxColor.textDim, lineWidth: 1))
        }
    }
}

struct NxProgressBar: View {
    let value: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(NxColor.track)
                Rectangle().fill(NxColor.accent).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: Metrics.u(height))
        .clipShape(Capsule())
    }
}

/// Selectable pill (genres, days, seasons): an outline at rest, white when chosen (or under the TV focus).
struct NxChip: View {
    let title: String
    var icon: String? = nil
    var trailing: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Focusable { focused in
                let white = focused || (selected && !Metrics.tv)
                HStack(spacing: Metrics.u(5)) {
                    if let i = icon { Image(systemName: i).font(.system(size: 11 * Metrics.type, weight: .bold)) }
                    Text(title).font(NxFont.ui(13, selected ? .bold : .semibold)).lineLimit(1)
                    if let t = trailing { Image(systemName: t).font(.system(size: 9 * Metrics.type, weight: .heavy)) }
                }
                .foregroundStyle(white ? Color.black : Color.white)
                .padding(.horizontal, Metrics.u(13))
                .frame(height: Metrics.u(32))
                .background(white ? Color.white : (selected ? Color.white.opacity(0.24) : Color.clear), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(white || selected ? 0 : 0.42), lineWidth: 1))
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
            }
        }
        .buttonStyle(NxPlainStyle())
        .nxRestorable()
    }
}

/// Title of a row or of a page section, with an optional quieter note beside it.
struct SectionHeader: View {
    let title: String
    var sub: String? = nil
    var tag: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.u(8)) {
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

/// The brand mark as the loading indicator: it breathes.
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

/// A thin ring that turns: waiting for the network inside a row or a button.
struct NxSpinner: View {
    var size: CGFloat = 18
    @State private var turn = false
    var body: some View {
        Circle().trim(from: 0.1, to: 0.85).stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: Metrics.u(2.2), lineCap: .round))
            .frame(width: Metrics.u(size), height: Metrics.u(size))
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true } }
    }
}

/// Our own on / off switch.
struct NxSwitch: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? NxColor.accent : NxColor.ink5).frame(width: Metrics.u(46), height: Metrics.u(27))
            Circle().fill(Color.white).frame(width: Metrics.u(22), height: Metrics.u(22)).padding(.horizontal, Metrics.u(2.5))
        }
        .animation(.easeOut(duration: 0.18), value: on)
    }
}

/// A text field in our own frame (the keyboard is the system's).
struct NxField<Content: View>: View {
    var icon: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: Metrics.u(10)) {
            if let i = icon { Image(systemName: i).font(.system(size: 15 * Metrics.unit, weight: .semibold)).foregroundStyle(NxColor.textDim) }
            content().font(NxFont.ui(16, .medium)).foregroundStyle(NxColor.text).tint(.white)
        }
        #if os(iOS)
        .padding(.horizontal, 14).frame(height: 50)
        .background(NxColor.ink3, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        #endif
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
