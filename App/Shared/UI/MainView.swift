import SwiftUI
import UIKit

/// The app past the gates. iPhone: four sections in our own bottom bar. Apple TV: a side menu that opens when the
/// remote goes left. Every section keeps its own stack of pages.
struct MainView: View {
    let profile: ProfileEntity
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LiveStore
    @State private var visited: Set<AppSection> = []
    #if os(tvOS)
    @FocusState private var rail: RailFocus?
    /// The side menu can be reached only a moment after the page settles: so the focus starts in the page, and
    /// choosing a section moves it into that section.
    @State private var railReady = false
    @State private var railPulse = 0
    /// The last entry of the side menu with the focus (a panel opened from the menu gives it back).
    @State private var lastRail: RailFocus? = nil
    /// The focus is coming back to `lastRail` on purpose: not moved to the section in view.
    @State private var keepRail = false
    /// Where the focus was in the page when it went to the side menu: RIGHT from the menu goes back there.
    @State private var pageReturn: PageReturn? = nil
    /// For every section, where the focus was when each of its pages was opened: BACK puts it back there.
    @State private var pushOrigins: [AppSection: [String?]] = [:]
    /// What had the focus when the player opened.
    @State private var playOrigin: String? = nil
    static let tabs: [AppSection] = [.search, .home, .live, .guide, .movies, .series, .mine, .settings]
    #else
    static let tabs: [AppSection] = [.home, .movies, .series, .live, .mine]
    #endif

    var body: some View {
        ZStack(alignment: Metrics.tv ? .leading : .bottom) {
            ForEach(MainView.tabs.filter { visited.contains($0) || $0 == app.section }) { s in
                stack(s)
                    .opacity(s == app.section ? 1 : 0)
                    .disabled(s != app.section)
                    .allowsHitTesting(s == app.section)
                    .accessibilityHidden(s != app.section)
            }
            #if os(tvOS)
            SideRail(profile: profile, focus: $rail, onSelect: select, onRight: backToPage).disabled(!railReady)
            #else
            TabBar()
            #endif
        }
        #if os(tvOS)
        .onChange(of: app.playing == nil) { _, idle in
            pulse()
            // the player closed: back on the card / button that started it (docs/tv-experience.md §3, BACK)
            if idle { FocusMemory.restore(playOrigin, after: 0.4) } else { playOrigin = FocusMemory.inRail ? nil : FocusMemory.last }
        }
        .onChange(of: app.sheets.isEmpty) { _, _ in pulse() }
        .onChange(of: rail) { old, new in railMoved(old, new) }
        .onChange(of: app.paths) { old, new in pathsChanged(old, new) }
        .onReceive(app.railRestore) { _ in backToRail() }
        .task(id: railPulse) {
            railReady = false
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { railReady = true }
        }
        .task { await demoRail() }
        .task { await demoFocusTest() }
        #endif
        #if os(iOS)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
        .nxPage()
        .onAppear { normalize() }
        .onChange(of: app.section) { _, _ in normalize() }
    }

    /// The phone has fewer sections than the TV: the others are pages.
    private func normalize() {
        #if os(iOS)
        switch app.section {
        case .search: app.section = .home; app.open(.search)
        case .guide: app.liveTab = 1; app.section = .live
        case .settings: app.section = .mine; app.open(.settings)
        default: break
        }
        #endif
        visited.insert(app.section)
        pulse()
    }

    private func pulse() {
        #if os(tvOS)
        railPulse += 1
        #endif
    }

    @ViewBuilder private func root(_ s: AppSection) -> some View {
        switch s {
        case .home: HomeView(pid: profile.id, kids: profile.kids)
        case .live:
            #if os(iOS)
            LiveHub()
            #else
            LiveView()
            #endif
        case .guide: GuideView()
        case .movies: VodHomeView(media: "movie", pid: profile.id, kids: profile.kids)
        case .series: VodHomeView(media: "tv", pid: profile.id, kids: profile.kids)
        case .mine: MineView(pid: profile.id, kids: profile.kids)
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }

    private func stack(_ s: AppSection) -> some View {
        NavigationStack(path: app.path(s)) {
            root(s)
                #if os(iOS)
                .safeAreaPadding(.bottom, Metrics.tabBar)
                #endif
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        #if os(tvOS)
        .padding(.leading, Metrics.rail)
        // one block for the focus engine: RIGHT from any entry of the side menu lands in the page, also where the top
        // of the page is the billboard (nothing to focus at the height of the menu entry)
        .focusSection()
        // BACK (Android: the same chain): a page → the one before (the stack does it), a section → the side menu
        .onExitCommand(perform: (app.paths[s] ?? []).isEmpty ? { enterRail(s) } : nil)
        #endif
    }

    #if os(tvOS)
    struct PageReturn { let section: AppSection; let key: String? }

    /// Select on a menu entry: another section opens (the focus goes into it); the section in view goes back to its
    /// first page and the focus into it.
    private func select(_ s: AppSection) {
        if app.section != s { app.section = s; return }
        let wasRoot = (app.paths[s] ?? []).isEmpty
        app.paths[s] = []
        app.reselect += 1
        pulse()
        if wasRoot { backToPage() }
    }

    /// BACK on a section's first page: the focus goes to the side menu, on that section.
    private func enterRail(_ s: AppSection) {
        if railReady { rail = .section(s); return }
        railReady = true
        DispatchQueue.main.async { rail = .section(s) }
    }

    /// RIGHT from the side menu (or select on the section in view): back on the element the page had before.
    private func backToPage() {
        guard let r = pageReturn, r.section == app.section, let k = r.key else { return }
        FocusMemory.restore(k, after: 0.06)
    }

    private func railMoved(_ old: RailFocus?, _ new: RailFocus?) {
        guard let n = new else { return }
        FocusMemory.inRail = true
        lastRail = n
        if old == nil {
            // entering the menu: remember the page's element, start on the section in view (never on the first entry)
            pageReturn = PageReturn(section: app.section, key: FocusMemory.last)
            if keepRail { keepRail = false }
            else if n != .section(app.section) { rail = .section(app.section) }
        }
    }

    /// A panel opened from the side menu closed (the "Vuoi uscire?" question): the focus goes back to the menu.
    private func backToRail() {
        railReady = true
        keepRail = true
        let target: RailFocus = lastRail ?? .section(app.section)
        DispatchQueue.main.async { rail = target }
    }

    private func pathsChanged(_ old: [AppSection: [Route]], _ new: [AppSection: [Route]]) {
        for s in AppSection.allCases {
            let o: Int = old[s]?.count ?? 0
            let n: Int = new[s]?.count ?? 0
            if n > o {
                let from: String? = FocusMemory.inRail ? nil : FocusMemory.last
                for _ in o..<n { pushOrigins[s, default: []].append(from) }
            } else if n < o {
                var st: [String?] = pushOrigins[s] ?? []
                var key: String? = nil
                for _ in n..<o { key = st.popLast() ?? nil }
                pushOrigins[s] = st
                // the stack slides back by itself; then the focus goes on the card that had opened the page
                if s == app.section { FocusMemory.restore(key, after: 0.45) }
            }
        }
        if (old[app.section]?.count ?? 0) != (new[app.section]?.count ?? 0) { pulse() }
    }

    /// Build pipeline: `-nxRailOpen [profile|<section>]` opens the side menu a few seconds after start.
    private func demoRail() async {
        guard Demo.args.contains("-nxRailOpen") else { return }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let v: String = Demo.value("-nxRailOpen") ?? ""
        let target: RailFocus = v == "profile" ? .profile : .section(AppSection(rawValue: v) ?? app.section)
        railReady = true
        keepRail = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        rail = target
        // `-nxAskExit`: what BACK on the menu shows
        if Demo.args.contains("-nxAskExit") {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            app.askExit()
        }
    }

    /// Build pipeline, `-nxFocusTest`: a dialog whose second button is focused from outside (as the exit question and
    /// the player do), then the focus memory moves it to the first and back (screenshots at about 12, 17 and 24 s).
    private func demoFocusTest() async {
        guard Demo.args.contains("-nxFocusTest") else { return }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        app.present(nil, style: .dialog) { FocusTestDialog() }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        FocusMemory.restore.send("ft.first")
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        FocusMemory.restore.send("ft.second")
    }
    #endif
}

#if os(tvOS)
private struct FocusTestDialog: View {
    @FocusState private var second: Bool
    var body: some View {
        VStack(spacing: 16) {
            NxButton("Primo", wide: true) {}.nxFocusKey("ft.first")
            NxButton("Secondo", wide: true) {}.nxFocusKey("ft.second").focused($second)
        }
        .onAppear { second = true }
    }
}
#endif


#if os(iOS)
/// The bottom bar: flat black, the section in view in white.
private struct TabBar: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainView.tabs) { s in
                let on = app.section == s
                Button {
                    if on {
                        if !(app.paths[s] ?? []).isEmpty { app.paths[s] = [] } else { app.reselect += 1 }
                    } else { app.section = s }
                } label: {
                    VStack(spacing: 3) {
                        if s == .mine, let p = app.profile {
                            p.face(24).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white, lineWidth: on ? 1.5 : 0))
                        } else {
                            Image(systemName: on ? s.icon : s.iconOff).font(.system(size: 20, weight: .medium)).frame(height: 24)
                        }
                        Text(s.label).font(NxFont.ui(10, on ? .bold : .medium))
                    }
                    .foregroundStyle(on ? Color.white : NxColor.textDim)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.tabBar)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NxPlainStyle(scale: 0.94))
            }
        }
        .background(Color(hex: 0x0A0A0A).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(NxColor.hairline).frame(height: 0.5) }
    }
}

/// With the system bar hidden the swipe from the left edge stops working: this gives it back.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
#endif

#if os(tvOS)
/// What the focus is on in the side menu.
enum RailFocus: Hashable { case profile, section(AppSection) }

/// The side menu (docs/tv-experience.md §1, the 0.9 Android rail made bigger). Collapsed: the brand, the avatar, the
/// section symbols, a red bar on the section in view, the clock. With the focus in it, it opens over the page (the page
/// does not move): brand, "NexStream" and the clock on top, the profile with "Cambia profilo", the sections as pills.
private struct SideRail: View {
    let profile: ProfileEntity
    var focus: FocusState<RailFocus?>.Binding
    let onSelect: (AppSection) -> Void
    let onRight: () -> Void
    @EnvironmentObject var app: AppModel

    /// Left edge of every entry; the symbols stay centred on the collapsed width when the menu opens.
    static let inset: CGFloat = 28
    static let pillH: CGFloat = 80
    /// The open menu fades to nothing over its last 96 pt.
    static let fade: CGFloat = 96
    static var pillOpenW: CGFloat { Metrics.railOpen - fade - inset }
    static var pillW: CGFloat { Metrics.rail - 2 * inset }

    var body: some View {
        let open: Bool = focus.wrappedValue != nil
        VStack(alignment: .leading, spacing: 0) {
            brand(open).frame(height: 64).padding(.bottom, 22)
            RailProfile(profile: profile, open: open) { app.changeProfile() }
                .focused(focus, equals: .profile)
                .padding(.leading, SideRail.inset)
            Rectangle().fill(open ? NxColor.hairline : Color.clear).frame(width: SideRail.pillOpenW, height: 1)
                .padding(.leading, SideRail.inset).padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MainView.tabs) { s in
                    RailItem(section: s, open: open, selected: app.section == s) { onSelect(s) }
                        .focused(focus, equals: .section(s))
                        .padding(.leading, SideRail.inset)
                }
            }
            Spacer(minLength: 0)
            if !open { RailClock().frame(width: Metrics.rail) }
        }
        .padding(.top, 48).padding(.bottom, 44)
        .frame(width: open ? Metrics.railOpen : Metrics.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(background(open))
        .ignoresSafeArea()
        .focusSection()
        // entering the menu (LEFT from the page) lands on the section in view, not on the entry next to the focus
        .defaultFocus(focus, RailFocus.section(app.section), priority: .userInitiated)
        .onMoveCommand { d in if d == .right { onRight() } }
        // BACK on the side menu: ask before leaving the app (Android TV does the same)
        .onExitCommand { app.askExit() }
        .animation(.easeOut(duration: 0.18), value: open)
    }

    private func background(_ open: Bool) -> some View {
        let solid: CGFloat = 1 - SideRail.fade / Metrics.railOpen
        let stops: [Gradient.Stop] = open
            ? [.init(color: .black, location: 0), .init(color: .black, location: solid), .init(color: .clear, location: 1)]
            : [.init(color: .black, location: 0), .init(color: .black, location: 1)]
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing).ignoresSafeArea()
    }

    private func brand(_ open: Bool) -> some View {
        HStack(spacing: 20) {
            Image("BrandSymbol").resizable().scaledToFit().frame(width: 64, height: 64)
            if open {
                Text("NexStream").font(NxFont.titleM).foregroundStyle(NxColor.text).lineLimit(1).fixedSize()
                Spacer(minLength: 12)
                RailClock()
            }
        }
        .padding(.leading, (Metrics.rail - 64) / 2)
        .frame(width: open ? SideRail.inset + SideRail.pillOpenW : Metrics.rail, alignment: .leading)
    }
}

/// HH:mm in the side menu.
private struct RailClock: View {
    var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(TimeText.time(Clock.now)).font(NxFont.ui(14, .bold)).foregroundStyle(NxColor.textMuted).monospacedDigit().lineLimit(1).fixedSize()
        }
    }
}

/// Who is watching: the avatar; open, with the name and "Cambia profilo". Select opens "Chi guarda?".
private struct RailProfile: View {
    let profile: ProfileEntity
    let open: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { RailProfileLabel(profile: profile, open: open) }
            .buttonStyle(NxPlainStyle(scale: 1))
            .accessibilityLabel("Cambia profilo")
    }
}

private struct RailProfileLabel: View {
    let profile: ProfileEntity
    let open: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        HStack(spacing: 22) {
            // avatar sizes are in phone points (× 2 on the TV): 40 → 80 pt collapsed, 44 → 88 pt open
            profile.face(open ? 44 : 40)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(NxFont.ui(18, .bold)).foregroundStyle(focused ? Color.black : Color.white).lineLimit(1)
                    Text("Cambia profilo").font(NxFont.caption).foregroundStyle(focused ? Color.black.opacity(0.6) : NxColor.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? Color.black.opacity(0.6) : NxColor.textDim)
            }
        }
        .padding(.leading, open ? 12 : 16).padding(.trailing, open ? 24 : 0)
        .frame(width: open ? SideRail.pillOpenW : SideRail.pillW, height: 104, alignment: .leading)
        .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// One section of the side menu. Focus = white pill, black content, no zoom; the section in view = white, with a red
/// bar on the screen edge (collapsed) or a red dot at the end of the pill (open); the others grey.
private struct RailItem: View {
    let section: AppSection
    let open: Bool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { RailItemLabel(section: section, open: open, selected: selected) }
            .buttonStyle(NxPlainStyle(scale: 1))
            .accessibilityLabel(section.label)
    }
}

private struct RailItemLabel: View {
    let section: AppSection
    let open: Bool
    let selected: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        let fg: Color = focused ? .black : (selected ? .white : NxColor.textMuted)
        HStack(spacing: 24) {
            Image(systemName: section.icon).font(.system(size: 40, weight: .semibold)).frame(width: 56, height: 56)
            if open {
                Text(section.label).font(NxFont.ui(19, selected ? .bold : .semibold)).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                if selected && !focused { Circle().fill(NxColor.accent).frame(width: 12, height: 12) }
            }
        }
        .foregroundStyle(fg)
        .padding(.leading, 28).padding(.trailing, open ? 28 : 0)
        .frame(width: open ? SideRail.pillOpenW : SideRail.pillW, height: SideRail.pillH, alignment: .leading)
        .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .leading) {
            if selected && !open {
                UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous)
                    .fill(NxColor.accent).frame(width: 8, height: 52).offset(x: -SideRail.inset)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif

/// The page behind a route.
struct RouteView: View {
    let route: Route
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
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
            case .mine: if let p = app.profile { MineView(pid: p.id, kids: p.kids) }
            case .search: SearchView()
            case .vod(let media): if let p = app.profile { VodHomeView(media: media, pid: p.id, kids: p.kids, pushed: true) }
            }
        }
        #if os(iOS)
        .safeAreaPadding(.bottom, Metrics.tabBar)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

/// Our own bar on top of a page: back, the title, and whatever the page adds on the right.
struct NxTopBar<Trailing: View>: View {
    let title: String
    var back: Bool = true
    var large: Bool = false
    @ViewBuilder var trailing: () -> Trailing
    @EnvironmentObject var app: AppModel

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: 20) {
            Text(title).font(NxFont.titleXL).foregroundStyle(NxColor.text).lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, Metrics.gutter).padding(.top, 50).padding(.bottom, 14)
        #else
        HStack(spacing: 6) {
            if back {
                Button { app.pop() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(NxPlainStyle(scale: 0.9))
                .accessibilityLabel("Indietro")
            }
            Text(title).font(large ? NxFont.display(22, .bold) : NxFont.ui(18, .heavy)).foregroundStyle(NxColor.text).lineLimit(1)
                .padding(.leading, back ? 0 : Metrics.gutter)
            Spacer(minLength: 0)
            trailing().padding(.trailing, 6)
        }
        .frame(height: 48)
        .background(NxColor.bg)
        #endif
    }
}

extension NxTopBar where Trailing == EmptyView {
    init(title: String, back: Bool = true, large: Bool = false) { self.init(title: title, back: back, large: large, trailing: { EmptyView() }) }
}

extension View {
    /// A page with our bar pinned on top.
    func nxScreen(_ title: String, back: Bool = true, large: Bool = false) -> some View {
        nxScreen(title, back: back, large: large) { EmptyView() }
    }
    func nxScreen<T: View>(_ title: String, back: Bool = true, large: Bool = false, @ViewBuilder trailing: @escaping () -> T) -> some View {
        VStack(spacing: 0) {
            NxTopBar(title: title, back: back, large: large, trailing: trailing)
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .nxPage()
    }
}

/// A bare symbol in a top bar (search, settings).
struct BarIcon: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Focusable { focused in
                Image(systemName: icon).font(.system(size: 20 * Metrics.unit, weight: .medium))
                    .foregroundStyle(focused ? Color.black : Color.white)
                    .frame(width: Metrics.u(42), height: Metrics.u(44))
                    .background(focused ? Color.white : Color.clear, in: Circle())
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(NxPlainStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}
