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
    @FocusState private var rail: AppSection?
    /// The side menu can be reached only a moment after the page settles: so the focus starts in the page, and
    /// choosing a section moves it into that section.
    @State private var railReady = false
    @State private var railPulse = 0
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
            SideRail(profile: profile, focus: $rail).disabled(!railReady)
            #else
            TabBar()
            #endif
        }
        #if os(tvOS)
        .onChange(of: app.playing == nil) { _, _ in pulse() }
        .onChange(of: app.sheets.isEmpty) { _, _ in pulse() }
        .task(id: railPulse) {
            railReady = false
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { railReady = true }
        }
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
        .onExitCommand(perform: (app.paths[s] ?? []).isEmpty ? { rail = s } : nil)
        #endif
    }
}

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
/// The side menu: a column of symbols that opens with their names when the remote is on it.
private struct SideRail: View {
    let profile: ProfileEntity
    var focus: FocusState<AppSection?>.Binding
    @EnvironmentObject var app: AppModel

    var body: some View {
        let open = focus.wrappedValue != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                profile.face(26)
                if open { Text(profile.name).font(NxFont.ui(15, .bold)).foregroundStyle(.white).lineLimit(1) }
            }
            .padding(.leading, 34).padding(.bottom, 26)
            ForEach(MainView.tabs) { s in
                Button {
                    if app.section == s { app.paths[s] = []; app.reselect += 1 } else { app.section = s }
                } label: {
                    Focusable { focused in
                        HStack(spacing: 22) {
                            Image(systemName: s.icon).font(.system(size: 30, weight: .semibold)).frame(width: 52, height: 52)
                            if open { Text(s.label).font(NxFont.ui(15, .bold)).lineLimit(1).fixedSize() }
                        }
                        .foregroundStyle(focused ? Color.black : (app.section == s ? Color.white : NxColor.textDim))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(width: open ? 330 : 76, alignment: .leading)
                        .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .leading) {
                            if app.section == s && !focused { Capsule().fill(NxColor.accent).frame(width: 5, height: 30).offset(x: -10) }
                        }
                    }
                }
                .buttonStyle(NxPlainStyle(scale: 1))
                .focused(focus, equals: s)
                .padding(.leading, 22)
            }
        }
        .frame(width: open ? 520 : Metrics.rail, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(stops: open ? [.init(color: .black, location: 0), .init(color: .black.opacity(0.94), location: 0.62), .init(color: .clear, location: 1)]
                                       : [.init(color: .black, location: 0), .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        )
        .ignoresSafeArea()
        .focusSection()
        .animation(.easeOut(duration: 0.18), value: open)
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
